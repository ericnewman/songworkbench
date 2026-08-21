"""Is the octave-aware estimator real, or fitted to one fixture?

    python3 tools/harmony_parts_spike/run_octave_seeds.py

Follow-up 4 stopped with a specific open question: the octave-aware estimator is gated
behind `octave_above_present`, a spectral test already measured as unreliable, so its
positional evidence is rarely consulted. Dropping that gate is the identified fix — and
also exactly the kind of change that can look good on one 8 s clip and mean nothing.

So this runs every configuration across several seeds and both spreads, and adds the two
non-octave casts as a regression guard. A change that helps the octave cast while damaging
the casts that already worked is not a fix.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
import stereo as stereo_lib  # noqa: E402
from run_octave import NEAR_MONO, WIDE, lines_with_a_track  # noqa: E402
from run_spike import correlation, match_parts, scale_invariant_sdr  # noqa: E402

SEEDS = (3, 7, 11, 19)

CONFIGS = {
    "off": dict(use_pan=True, octave_aware=False),
    "gated": dict(use_pan=True, octave_aware=True, octave_spectral_gate=True),
    "ungated": dict(use_pan=True, octave_aware=False, octave_spectral_gate=False),
}
CONFIGS["ungated"] = dict(use_pan=True, octave_aware=True, octave_spectral_gate=False)
CONFIGS["per-track"] = dict(use_pan=True, octave_partners=True)


def measure(sources, lines, pans, config, **kwargs):
    left, right = stereo_lib.render_stereo(sources, pans, fixture.SAMPLE_RATE)
    result = stereo_lib.separate_stereo(left, right, len(sources), config=config, **kwargs)
    estimates = result["parts"]
    worst = max(
        correlation(estimates[i], estimates[j])
        for i in range(len(estimates))
        for j in range(i + 1, len(estimates))
    )
    matched = match_parts(sources, estimates)
    sdrs = [scale_invariant_sdr(sources[n], estimates[matched[n]]) for n in sources if n in matched]
    return {
        "det": lines_with_a_track(result["tracks"], lines, config),
        "parts": len(sources),
        "tracks": len(result["tracks"]),
        "corr": worst,
        "sdr": float(np.mean(sdrs)),
    }


def summarise(rows):
    return (
        f"det {np.mean([r['det'] for r in rows]):.2f}/{rows[0]['parts']}  "
        f"trks {np.mean([r['tracks'] for r in rows]):>5.1f}  "
        f"corr {np.mean([r['corr'] for r in rows]):.3f}  "
        f"SI-SDR {np.mean([r['sdr' ]for r in rows]):>7.2f}"
    )


def main() -> int:
    print(f"averaged over seeds {SEEDS}\n")
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)

    print("OCTAVE-VOICED QUARTET (the case under test)")
    for spread_name, pans in (("wide", WIDE), ("near-mono (control)", NEAR_MONO)):
        for name, kwargs in CONFIGS.items():
            rows = []
            for seed in SEEDS:
                sources = fixture.quartet_cast(duration=8.0, seed=seed, octave_bottom=True)
                lines = fixture.quartet_lines(octave_bottom=True)
                rows.append(measure(sources, lines, pans, config, **kwargs))
            print(f"  {spread_name:<20} {name:<9} {summarise(rows)}")
        print()

    print("REGRESSION GUARD (casts that already worked; wide spread)")
    guards = {
        "quartet_no_octave": (
            lambda seed: fixture.quartet_cast(duration=8.0, seed=seed, octave_bottom=False),
            lambda: fixture.quartet_lines(octave_bottom=False),
            WIDE,
        ),
        "distinct(3)": (
            lambda seed: fixture.distinct_cast(duration=8.0, seed=seed),
            fixture.cast_lines,
            {"lead": -0.6, "harmony_high": 0.6, "harmony_low": 0.0},
        ),
    }
    for cast_name, (maker, line_maker, pans) in guards.items():
        for name, kwargs in CONFIGS.items():
            rows = []
            for seed in SEEDS:
                sources = maker(seed)
                lines = {n: v for n, v in line_maker().items() if n in sources}
                rows.append(measure(sources, lines, pans, config, **kwargs))
            print(f"  {cast_name:<20} {name:<9} {summarise(rows)}")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
