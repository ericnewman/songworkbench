"""Does the octave rescue help NOTES, even though it hurt stems?

    python3 tools/harmony_parts_spike/run_notes_octave.py

Follow-up 5 rejected the octave-partner estimator because enabling it damaged the casts that
already worked. Every number in that judgement was a Track B metric — SI-SDR and cross-part
leakage, i.e. how good the separated AUDIO is.

Track A does not need separated audio. It needs the note event. And for notation an octave
partner is not a nuisance, it is a real note currently being missed: the octave-voiced quartet
sings four distinct pitches and the mono chain writes down three.

So the same switch has to be scored on Track A's own terms before it is called a failure.
The regression guard is the point: if it invents notes on casts with no octave pair, it is no
better here than it was there.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import notes as notes_lib  # noqa: E402
import parts as part_lib  # noqa: E402
import stereo as stereo_lib  # noqa: E402
from run_notes import reference_notes  # noqa: E402
from run_octave import WIDE  # noqa: E402

SEEDS = (3, 7, 11, 19)
DISTINCT_PANS = {"lead": -0.6, "harmony_high": 0.6, "harmony_low": 0.0}


def score(sources, lines, pans, part_count, gate, **kwargs):
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
    left, right = stereo_lib.render_stereo(sources, pans, fixture.SAMPLE_RATE)
    result = stereo_lib.separate_stereo(left, right, part_count, config=config, **kwargs)
    events = notes_lib.notes_from_tracks(result["tracks"], result["labels"], config)
    kept = [event for event in events if event.confidence >= gate]

    reference = reference_notes(lines, sorted(sources), True)
    matched, pitch_errors, _, _ = notes_lib.match_notes(reference, kept)
    precision = matched / max(len(kept), 1)
    recall = matched / max(len(reference), 1)
    return {
        "P": precision,
        "R": recall,
        "F1": 2 * precision * recall / max(precision + recall, 1e-9),
        "cents": float(np.mean(pitch_errors)) if pitch_errors else float("nan"),
        "reference": len(reference),
    }


def summarise(rows):
    return (
        f"P {np.mean([r['P'] for r in rows]):.3f}  R {np.mean([r['R'] for r in rows]):.3f}  "
        f"F1 {np.mean([r['F1'] for r in rows]):.3f}  cents {np.nanmean([r['cents'] for r in rows]):>5.1f}"
    )


def main() -> int:
    print(f"averaged over seeds {SEEDS}; stereo, wide spread\n")
    for gate in (0.0, 0.10, 0.20):
        print(f"confidence gate {gate:.2f}")
        for label, kwargs in (("octave off", {}), ("octave partners", {"octave_partners": True})):
            rows = [
                score(
                    fixture.quartet_cast(duration=8.0, seed=seed, octave_bottom=True),
                    fixture.quartet_lines(octave_bottom=True),
                    WIDE,
                    4,
                    gate,
                    **kwargs,
                )
                for seed in SEEDS
            ]
            print(f"  octave quartet     {label:<16} {summarise(rows)}")

        # Regression guard: a cast with no octave pair must not gain invented notes.
        for label, kwargs in (("octave off", {}), ("octave partners", {"octave_partners": True})):
            rows = []
            for seed in SEEDS:
                sources = fixture.distinct_cast(duration=8.0, seed=seed)
                lines = {n: v for n, v in fixture.cast_lines().items() if n in sources}
                rows.append(score(sources, lines, DISTINCT_PANS, 3, gate, **kwargs))
            print(f"  distinct (guard)   {label:<16} {summarise(rows)}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
