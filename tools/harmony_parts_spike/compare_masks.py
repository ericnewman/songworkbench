"""A/B the mask-synthesis variants across every cast.

    python3 tools/harmony_parts_spike/compare_masks.py

`comb` is the original fixed 1/h harmonic comb. `comb_gain` adds only the per-frame loudness
estimate. `measured` adds each track's own partial profile on top of that. Part assignment is
identical across all three — only the synthesis differs — so the differences are attributable
to the mask, and the middle row separates the gain's effect from the profile's.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
from run_spike import correlation, match_parts, scale_invariant_sdr, signal_to_distortion  # noqa: E402

CASTS = {
    "distinct": (fixture.distinct_cast, 3),
    "quartet_no_octave": (lambda **kw: fixture.quartet_cast(octave_bottom=False, **kw), 4),
    "quartet": (fixture.quartet_cast, 4),
    "hard": (fixture.default_cast, 4),
}
GAINS = {"lead": 1.0, "double": 0.55, "harmony_high": 0.6, "harmony_low": 0.5}

print(f"{'cast':<20} {'mask':<10} {'recon dB':>9} {'max corr':>9} {'mean SI-SDR':>12} {'worst':>8}")
for name, (maker, part_count) in CASTS.items():
    sources = maker(duration=8.0, seed=7)
    signal = fixture.mix(sources, gains=GAINS)
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
    baseline = float(np.mean([scale_invariant_sdr(s, signal) for s in sources.values()]))

    for mode in ("comb", "measured_gain", "nnls"):
        result = part_lib.separate(signal, part_count, config=config, mask_mode=mode)
        estimates = result["parts"]
        recon = signal_to_distortion(signal, np.sum(estimates, axis=0))
        worst_corr = max(
            correlation(estimates[i], estimates[j])
            for i in range(len(estimates))
            for j in range(i + 1, len(estimates))
        )
        matched = match_parts(sources, estimates)
        sdrs = [scale_invariant_sdr(sources[n], estimates[matched[n]]) for n in sources if n in matched]
        print(
            f"{name:<20} {mode:<10} {recon:>9.1f} {worst_corr:>9.3f} "
            f"{np.mean(sdrs):>12.2f} {min(sdrs):>8.2f}"
        )
    print(f"{'':<20} {'(baseline)':<10} {'':>9} {'':>9} {baseline:>12.2f}")
