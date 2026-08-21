"""Run the harmony-part spike and score it against the PRD gates.

    python3 tools/harmony_parts_spike/run_spike.py                    # synthetic fixture
    python3 tools/harmony_parts_spike/run_spike.py --input vocals.wav --parts 4

Results are written incrementally to `--report` as each metric is computed, per
`tasks/lessons.md` (2026-07-30): a long harness that only prints at the end loses
everything if it dies at song 24.

Gates come from `.scratch/multipart-stem-separation/PRD.md` §4:

    reconstruction  Σ parts vs input          ≥ 120 dB SDR
    leakage         pairwise part correlation < 0.2
    consistency     one cluster per part      ≥ 80% of voiced frames

Two more are only computable with ground truth, and are the ones that actually decide
whether the timbral layer works:

    assignment      notes routed to the right singer
    per-part SI-SDR each part vs the singer it is supposed to contain
"""

from __future__ import annotations

import argparse
import json
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402


def signal_to_distortion(reference: np.ndarray, estimate: np.ndarray) -> float:
    """Plain SDR in dB. Used for reconstruction, where scale must not be forgiven."""
    length = min(len(reference), len(estimate))
    reference, estimate = reference[:length], estimate[:length]
    noise = reference - estimate
    denominator = float(np.sum(noise**2))
    if denominator <= 0:
        return float("inf")
    return float(10.0 * np.log10(np.sum(reference**2) / denominator))


def scale_invariant_sdr(reference: np.ndarray, estimate: np.ndarray) -> float:
    """SI-SDR: separation quality independent of how loud the part came out."""
    length = min(len(reference), len(estimate))
    reference, estimate = reference[:length], estimate[:length]
    reference = reference - reference.mean()
    estimate = estimate - estimate.mean()
    energy = float(np.sum(reference**2))
    if energy <= 0:
        return float("-inf")
    projection = float(np.sum(reference * estimate)) / energy * reference
    noise = estimate - projection
    denominator = float(np.sum(noise**2))
    if denominator <= 0:
        return float("inf")
    return float(10.0 * np.log10(float(np.sum(projection**2)) / denominator))


def correlation(a: np.ndarray, b: np.ndarray) -> float:
    length = min(len(a), len(b))
    a, b = a[:length], b[:length]
    denominator = np.linalg.norm(a) * np.linalg.norm(b)
    if denominator <= 0:
        return 0.0
    return float(abs(np.dot(a, b) / denominator))


def match_parts(sources: dict[str, np.ndarray], estimates: list[np.ndarray]) -> dict[str, int]:
    """Greedy best-correlation matching of estimated parts to ground-truth singers."""
    pairs = []
    for name, source in sources.items():
        for index, estimate in enumerate(estimates):
            pairs.append((correlation(source, estimate), name, index))
    pairs.sort(reverse=True)
    matched: dict[str, int] = {}
    used: set[int] = set()
    for _, name, index in pairs:
        if name in matched or index in used:
            continue
        matched[name] = index
        used.add(index)
    return matched


def track_truth(
    track: part_lib.Track,
    lines: dict[str, list[tuple[float, float, float]]],
    config: part_lib.STFTConfig,
    names: list[str] | None = None,
) -> str:
    """Which singer owns this note: the one whose scored pitch it matches at that time.

    Not "the loudest source over this span" — everyone sings at once and the lead is
    mixed loudest, so that test labels every track `lead` regardless of pitch. Owner is
    a question about the score, so it is answered from the score.
    """
    frame_rate = config.sample_rate / config.hop
    midpoint = 0.5 * (track.start + track.end) / frame_rate
    midi = 69.0 + 12.0 * np.log2(track.median_hz / 440.0)

    best_name, best_distance = "?", float("inf")
    for name in names or sorted(lines):
        for start, end, note in lines[name]:
            if not (start - 0.05) <= midpoint <= (end + 0.05):
                continue
            distance = abs(note - midi)
            if distance < best_distance:
                best_name, best_distance = name, distance
    # A semitone of slack: vibrato and the parabolic f0 estimate both move the median.
    return best_name if best_distance <= 1.0 else "?"


def write_wav(path: Path, signal: np.ndarray, sample_rate: int) -> None:
    peak = float(np.max(np.abs(signal))) or 1.0
    data = np.clip(signal / peak * 0.98, -1.0, 1.0)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes((data * 32_767).astype("<i2").tobytes())


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as handle:
        sample_rate = handle.getframerate()
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        if width != 2:
            raise SystemExit(f"{path}: only 16-bit PCM WAV is supported by this spike")
        raw = np.frombuffer(handle.readframes(handle.getnframes()), dtype="<i2")
    signal = raw.astype(np.float64) / 32_768.0
    if channels > 1:
        signal = signal.reshape(-1, channels).mean(axis=1)
    return signal, sample_rate


class Report:
    """Appends each result to disk as it is computed."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.entries: list[dict] = []
        path.parent.mkdir(parents=True, exist_ok=True)

    def add(self, name: str, value, gate: str | None = None, passed: bool | None = None) -> None:
        entry = {"metric": name, "value": value}
        if gate is not None:
            entry["gate"] = gate
            entry["passed"] = passed
        self.entries.append(entry)
        self.path.write_text(json.dumps(self.entries, indent=2))
        mark = "" if passed is None else ("  PASS" if passed else "  FAIL")
        printable = f"{value:.3f}" if isinstance(value, float) else value
        print(f"{name:38} {printable}{mark}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="16-bit WAV of a vocal stack (default: synthetic fixture)")
    parser.add_argument(
        "--cast",
        choices=("distinct", "hard", "quartet", "quartet_no_octave"),
        default="distinct",
        help="synthetic cast: 'distinct' = 3 singers on 3 pitch lines; "
        "'hard' = adds a unison double of the lead; 'quartet' = 4 singers on 4 lines "
        "(bottom an octave below the top); 'quartet_no_octave' = same, bottom moved up a semitone",
    )
    parser.add_argument("--parts", type=int, default=3)
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--report", type=Path, default=Path("harmony-spike-report.json"))
    parser.add_argument("--write-audio", type=Path, help="directory to write the separated parts into")
    arguments = parser.parse_args()

    report = Report(arguments.report)

    sources: dict[str, np.ndarray] | None = None
    if arguments.input:
        signal, sample_rate = read_wav(arguments.input)
        print(f"input: {arguments.input} ({len(signal) / sample_rate:.1f}s @ {sample_rate} Hz)")
    else:
        sample_rate = fixture.SAMPLE_RATE
        maker = {
            "hard": fixture.default_cast,
            "distinct": fixture.distinct_cast,
            "quartet": fixture.quartet_cast,
            "quartet_no_octave": lambda **kwargs: fixture.quartet_cast(octave_bottom=False, **kwargs),
        }[arguments.cast]
        sources = maker(duration=arguments.duration, seed=arguments.seed)
        signal = fixture.mix(
            sources, gains={"lead": 1.0, "double": 0.55, "harmony_high": 0.6, "harmony_low": 0.5}
        )
        print(
            f"fixture[{arguments.cast}]: {', '.join(sorted(sources))} "
            f"({arguments.duration:.1f}s @ {sample_rate} Hz), requesting {arguments.parts} parts"
        )

    config = part_lib.STFTConfig(sample_rate=sample_rate)

    round_trip = part_lib.istft(part_lib.stft(signal, config), config, len(signal))
    report.add(
        "stft_round_trip_sdr_db",
        signal_to_distortion(signal, round_trip),
        gate=">= 120",
        passed=signal_to_distortion(signal, round_trip) >= 120.0,
    )

    result = part_lib.separate(signal, arguments.parts, config=config)
    estimates: list[np.ndarray] = result["parts"]
    tracks: list[part_lib.Track] = result["tracks"]
    labels = result["labels"]

    report.add("tracks_found", len(tracks))
    report.add("notes_per_part", json.dumps({int(k): int(v) for k, v in zip(*np.unique(labels, return_counts=True))}))

    reconstruction = signal_to_distortion(signal, np.sum(estimates, axis=0))
    report.add("reconstruction_sdr_db", reconstruction, gate=">= 120", passed=reconstruction >= 120.0)

    correlations = [
        correlation(estimates[i], estimates[j])
        for i in range(len(estimates))
        for j in range(i + 1, len(estimates))
    ]
    worst = max(correlations) if correlations else 0.0
    report.add("max_pairwise_part_correlation", worst, gate="< 0.2", passed=worst < 0.2)

    if sources is not None:
        table = (
            fixture.quartet_lines(octave_bottom=arguments.cast == "quartet")
            if arguments.cast.startswith("quartet")
            else fixture.cast_lines()
        )
        lines = {name: notes for name, notes in table.items() if name in sources}
        names = sorted(sources)
        truth = [track_truth(track, lines, config, names) for track in tracks]
        # Assignment accuracy: for each cluster take its majority true singer, then count
        # how many of its notes agree. This is the "part consistency" gate with ground
        # truth substituted for the cluster's own self-agreement.
        correct = 0
        for label in np.unique(labels):
            members = [truth[i] for i in range(len(tracks)) if labels[i] == label]
            if not members:
                continue
            majority = max(set(members), key=members.count)
            correct += members.count(majority)
        accuracy = correct / max(len(tracks), 1)
        report.add("note_assignment_accuracy", accuracy, gate=">= 0.80", passed=accuracy >= 0.80)

        distinct = len({max(set(m := [truth[i] for i in range(len(tracks)) if labels[i] == label]), key=m.count) for label in np.unique(labels)})
        report.add("distinct_singers_recovered", f"{distinct}/{len(names)}", gate=f"= {len(names)}", passed=distinct == len(names))

        matched = match_parts(sources, estimates)
        for name in names:
            index = matched.get(name)
            if index is None:
                report.add(f"si_sdr_{name}_db", "unmatched")
                continue
            report.add(f"si_sdr_{name}_db", scale_invariant_sdr(sources[name], estimates[index]))

        baseline = np.mean([scale_invariant_sdr(sources[name], signal) for name in names])
        report.add("si_sdr_baseline_unseparated_db", float(baseline))

    if arguments.write_audio:
        arguments.write_audio.mkdir(parents=True, exist_ok=True)
        write_wav(arguments.write_audio / "mix.wav", signal, sample_rate)
        for index, estimate in enumerate(estimates):
            write_wav(arguments.write_audio / f"part{index}.wav", estimate, sample_rate)
        if sources:
            for name, source in sources.items():
                write_wav(arguments.write_audio / f"truth_{name}.wav", source, sample_rate)
        print(f"audio written to {arguments.write_audio}")

    print(f"\nreport: {arguments.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
