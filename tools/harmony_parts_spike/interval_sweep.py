"""Does the musical interval predict how separable two voices are?

    python3 tools/harmony_parts_spike/interval_sweep.py

Eric's question (2026-08-21): vocal harmony sits at unison, the octave, or a common interval
— is it useful to look for those intervals specifically?

There is a physical reason to think so. Two voices at frequency ratio p:q (in lowest terms)
collide on every partial of the upper voice whose index is a multiple of q, so q predicts how
much of the upper voice is hidden and how much is exclusively its own:

    unison 1:1   every partial collides    no exclusive evidence
    octave 2:1   every partial collides    no exclusive evidence
    fifth  3:2   half collide              exclusive at 1.5, 4.5, 7.5 x f0
    fourth 4:3   a third collide           exclusive at 1.33, 2.67 x f0 ...
    M3     5:4   a quarter collide         exclusive at 1.25, 2.5 x f0 ...

If that is the mechanism, difficulty should track q — NOT consonance, and not interval size.
Unison and the octave should be the only catastrophic cases, and the fifth should be the
worst of the rest. Two voices, one interval at a time, so nothing else is in the way.
"""

from __future__ import annotations

import sys
from fractions import Fraction
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
from run_spike import correlation, match_parts, scale_invariant_sdr  # noqa: E402

NAMES = {
    0: "unison", 1: "minor 2nd", 2: "major 2nd", 3: "minor 3rd", 4: "major 3rd",
    5: "perfect 4th", 6: "tritone", 7: "perfect 5th", 8: "minor 6th", 9: "major 6th",
    10: "minor 7th", 11: "major 7th", 12: "octave",
}

LOWER = [(0.30, 1.60, 60.0), (1.80, 3.10, 62.0), (3.30, 4.60, 64.0), (4.80, 6.20, 62.0)]


def just_ratio(semitones: int) -> Fraction:
    """The small-integer ratio a 12-TET interval approximates."""
    return Fraction(2.0 ** (semitones / 12.0)).limit_denominator(16)


def collision_fraction(semitones: int, partials: int = 10) -> float:
    """Share of the upper voice's partials that land on one of the lower voice's."""
    ratio = just_ratio(semitones)
    hits = sum(1 for k in range(1, partials + 1) if (k * ratio).denominator == 1)
    return hits / partials


def main() -> int:
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
    print(f"{'interval':<13} {'ratio':>7} {'q':>3} {'collide':>8} {'det':>5} "
          f"{'corr':>7} {'lower dB':>9} {'upper dB':>9} {'base dB':>8}")

    for semitones in range(13):
        ratio = just_ratio(semitones)
        upper_notes = [(s, e, m + semitones) for s, e, m in LOWER]
        sources = {
            "lower": fixture.render_line(fixture.SINGER_A, LOWER, 7.0, seed=5),
            "upper": fixture.render_line(fixture.SINGER_B, upper_notes, 7.0, seed=9),
        }
        signal = fixture.mix(sources, gains={"lower": 1.0, "upper": 0.8})
        result = part_lib.separate(signal, 2, config=config)
        estimates = result["parts"]

        # How many of the two voices have an f0 track on their pitch.
        frame_rate = config.sample_rate / config.hop
        detected = 0
        for name, notes in (("lower", LOWER), ("upper", upper_notes)):
            for start, end, midi in notes:
                if any(
                    (start - 0.1) <= 0.5 * (t.start + t.end) / frame_rate <= (end + 0.1)
                    and abs(69 + 12 * np.log2(t.median_hz / 440) - midi) < 0.6
                    for t in result["tracks"]
                ):
                    detected += 1
                    break

        matched = match_parts(sources, estimates)
        sdr = {n: scale_invariant_sdr(sources[n], estimates[matched[n]]) for n in sources if n in matched}
        base = float(np.mean([scale_invariant_sdr(s, signal) for s in sources.values()]))
        print(
            f"{NAMES[semitones]:<13} {str(ratio):>7} {ratio.denominator:>3} "
            f"{collision_fraction(semitones):>8.0%} {detected}/2 "
            f"{correlation(estimates[0], estimates[1]):>7.3f} "
            f"{sdr.get('lower', float('nan')):>9.2f} {sdr.get('upper', float('nan')):>9.2f} {base:>8.2f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
