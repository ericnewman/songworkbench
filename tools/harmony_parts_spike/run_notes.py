"""Score Path A — note detection — on its own terms.

    python3 tools/harmony_parts_spike/run_notes.py

Path A and Path B fail differently, so they need different metrics. Separation metrics
(SI-SDR, cross-part leakage) say nothing about whether the right notes were written down,
and note metrics say nothing about whether a stem is listenable.

Reported per cast, twice:

* **distinct notes** — the reference is the set of distinct sounding (time, pitch) events.
  This is the notation view: two singers in unison are ONE note on the page, and getting
  both is not credit for two.
* **per-singer notes** — the reference counts every singer's note separately. This is the
  view Path B would need, and the gap between the two columns is exactly what Path A gets
  for free.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import notes as notes_lib  # noqa: E402
import parts as part_lib  # noqa: E402

CASTS = {
    "distinct": (fixture.distinct_cast, fixture.cast_lines, 3),
    "quartet_no_octave": (
        lambda **kw: fixture.quartet_cast(octave_bottom=False, **kw),
        lambda: fixture.quartet_lines(octave_bottom=False),
        4,
    ),
    "quartet": (fixture.quartet_cast, fixture.quartet_lines, 4),
    "hard": (fixture.default_cast, fixture.cast_lines, 4),
}
GAINS = {"lead": 1.0, "double": 0.55, "harmony_high": 0.6, "harmony_low": 0.5}


def reference_notes(lines: dict, names: list[str], deduplicate: bool) -> list[tuple[float, float, float]]:
    events: list[tuple[float, float, float]] = []
    for name in names:
        for start, end, midi in lines[name]:
            events.append((start, end, midi))
    if not deduplicate:
        return sorted(events)

    # Two singers on the same pitch at the same time are one note on the page.
    unique: list[tuple[float, float, float]] = []
    for event in sorted(events):
        if any(
            abs(event[0] - other[0]) < 0.15 and abs(event[2] - other[2]) < 0.5 for other in unique
        ):
            continue
        unique.append(event)
    return unique


def sweep(cast_name, maker, line_maker, part_count) -> None:
    """Precision/recall against the confidence gate.

    The app's stated posture is that generated analysis is a draft until reviewed, so the
    question is not "what is the F1" but "is there a threshold where everything written down
    is right". A note the user has to delete costs more trust than a note that was never
    offered.
    """
    sources = maker(duration=8.0, seed=7)
    signal = fixture.mix(sources, gains=GAINS)
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
    estimated = notes_lib.detect_notes(signal, part_count, config=config)
    lines = {name: notes for name, notes in line_maker().items() if name in sources}
    reference = reference_notes(lines, sorted(sources), True)

    for threshold in (0.0, 0.05, 0.10, 0.20, 0.30, 0.45):
        kept = [event for event in estimated if event.confidence >= threshold]
        matched, _, _, _ = notes_lib.match_notes(reference, kept)
        precision = matched / max(len(kept), 1)
        recall = matched / max(len(reference), 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-9)
        print(
            f"{cast_name:<19} {threshold:>5.2f} {len(kept):>5} "
            f"{precision:>6.3f} {recall:>6.3f} {f1:>6.3f}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sweep", action="store_true", help="sweep the confidence gate instead")
    arguments = parser.parse_args()

    if arguments.sweep:
        print(f"{'cast':<19} {'thr':>5} {'kept':>5} {'P':>6} {'R':>6} {'F1':>6}")
        for cast_name, (maker, line_maker, part_count) in CASTS.items():
            sweep(cast_name, maker, line_maker, part_count)
            print()
        return 0

    print(
        f"{'cast':<19} {'reference':<12} {'notes':>6} {'found':>6} {'P':>6} {'R':>6} {'F1':>6} "
        f"{'cents':>6} {'onset ms':>9}"
    )
    for cast_name, (maker, line_maker, part_count) in CASTS.items():
        sources = maker(duration=8.0, seed=7)
        signal = fixture.mix(sources, gains=GAINS)
        config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
        estimated = notes_lib.detect_notes(signal, part_count, config=config)
        lines = {name: notes for name, notes in line_maker().items() if name in sources}

        for label, deduplicate in (("distinct", True), ("per-singer", False)):
            reference = reference_notes(lines, sorted(sources), deduplicate)
            matched, pitch_errors, onset_errors, _ = notes_lib.match_notes(reference, estimated)
            precision = matched / max(len(estimated), 1)
            recall = matched / max(len(reference), 1)
            f1 = 2 * precision * recall / max(precision + recall, 1e-9)
            print(
                f"{cast_name:<19} {label:<12} {len(reference):>6} {len(estimated):>6} "
                f"{precision:>6.3f} {recall:>6.3f} {f1:>6.3f} "
                f"{np.mean(pitch_errors) if pitch_errors else float('nan'):>6.1f} "
                f"{1_000 * np.mean(onset_errors) if onset_errors else float('nan'):>9.1f}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
