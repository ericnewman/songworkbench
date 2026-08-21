"""Regression guard for the spike: the working configuration must stay working.

    python3 tools/harmony_parts_spike/selftest.py

Asserts the measured numbers for the three-part distinct cast, so a later change to the
estimator cannot quietly undo it. The thresholds sit a little below the measured values
(0.947 accuracy, +12.9/+13.1 dB) to leave room for numpy version drift without leaving
room for a real regression.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
from run_spike import correlation, match_parts, scale_invariant_sdr, signal_to_distortion, track_truth  # noqa: E402

failures: list[str] = []


def check(name: str, value: float, expected: str, ok: bool) -> None:
    print(f"{name:34} {value:9.3f}  expected {expected:12} {'ok' if ok else 'FAILED'}")
    if not ok:
        failures.append(name)


sources = fixture.distinct_cast(duration=8.0, seed=7)
signal = fixture.mix(sources, gains={"lead": 1.0, "harmony_high": 0.6, "harmony_low": 0.5})
config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)

round_trip = signal_to_distortion(signal, part_lib.istft(part_lib.stft(signal, config), config, len(signal)))
check("stft_round_trip_sdr_db", round_trip, ">= 120", round_trip >= 120.0)

result = part_lib.separate(signal, 3, config=config)
estimates = result["parts"]
tracks = result["tracks"]
labels = result["labels"]

reconstruction = signal_to_distortion(signal, np.sum(estimates, axis=0))
check("reconstruction_sdr_db", reconstruction, ">= 120", reconstruction >= 120.0)

worst = max(
    correlation(estimates[i], estimates[j])
    for i in range(len(estimates))
    for j in range(i + 1, len(estimates))
)
check("max_pairwise_correlation", worst, "< 0.20", worst < 0.20)

lines = {name: notes for name, notes in fixture.cast_lines().items() if name in sources}
truths = [track_truth(track, lines, config, sorted(sources)) for track in tracks]
correct = 0
for label in np.unique(labels):
    members = [truths[i] for i in range(len(tracks)) if labels[i] == label]
    if members:
        correct += members.count(max(set(members), key=members.count))
accuracy = correct / max(len(tracks), 1)
check("note_assignment_accuracy", accuracy, ">= 0.85", accuracy >= 0.85)

matched = match_parts(sources, estimates)
for name in ("lead", "harmony_high"):
    value = scale_invariant_sdr(sources[name], estimates[matched[name]])
    check(f"si_sdr_{name}_db", value, ">= 9.0", value >= 9.0)

# The quietest, most partial-crowded part is the weak one; it must still beat the
# unseparated baseline, which is what "separation happened at all" means for it.
low = scale_invariant_sdr(sources["harmony_low"], estimates[matched["harmony_low"]])
baseline = scale_invariant_sdr(sources["harmony_low"], signal)
check("si_sdr_harmony_low_gain_db", low - baseline, ">= 4.0", low - baseline >= 4.0)

# Track A (notes) is a separate deliverable with separate gates, so it gets its own
# assertion: at the 0.20 confidence gate every note reported must be correct.
import notes as notes_lib  # noqa: E402
from run_notes import reference_notes  # noqa: E402

events = notes_lib.detect_notes(signal, 3, config=config)
gated = [event for event in events if event.confidence >= 0.20]
reference = reference_notes(lines, sorted(sources), True)
note_matches, pitch_errors, _, _ = notes_lib.match_notes(reference, gated)
precision = note_matches / max(len(gated), 1)
check("note_precision_at_gate_0.20", precision, "== 1.00", precision >= 0.999)
check("note_pitch_error_cents", float(np.mean(pitch_errors)), "<= 25", np.mean(pitch_errors) <= 25.0)

print("\nFAILED: " + ", ".join(failures) if failures else "\nall checks passed")
raise SystemExit(1 if failures else 0)
