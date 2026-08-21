"""Does stereo evidence unblock four vocal parts?

    python3 tools/harmony_parts_spike/run_stereo.py

Runs the four-voice cast panned across the stereo field, with and without the spatial term,
so the pan's contribution is isolated. Also runs a near-mono spread (everything within ±0.1)
as a control: if the spatial term "helps" there, it is fitting noise rather than position.

Ground truth is the mono source, compared against the mono sum of the estimated part, so the
numbers are directly comparable to the mono spike's table.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
import stereo as stereo_lib  # noqa: E402
from run_spike import correlation, match_parts, scale_invariant_sdr, signal_to_distortion  # noqa: E402

GAINS = {"lead": 1.0, "double": 0.55, "harmony_high": 0.6, "harmony_low": 0.5}

SPREADS = {
    "wide": {"part1_top": -0.8, "part2_upper_mid": 0.8, "part3_lower_mid": -0.35, "part4_bottom": 0.35},
    "narrow": {"part1_top": -0.3, "part2_upper_mid": 0.3, "part3_lower_mid": -0.12, "part4_bottom": 0.12},
    "near_mono": {"part1_top": -0.1, "part2_upper_mid": 0.1, "part3_lower_mid": -0.03, "part4_bottom": 0.03},
}


def evaluate(sources, left, right, part_count, use_pan):
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
    result = stereo_lib.separate_stereo(left, right, part_count, config=config, use_pan=use_pan)
    estimates = result["parts"]
    mono = 0.5 * (left + right)

    reconstruction = signal_to_distortion(mono, np.sum(estimates, axis=0))
    worst = max(
        correlation(estimates[i], estimates[j])
        for i in range(len(estimates))
        for j in range(i + 1, len(estimates))
    )
    matched = match_parts(sources, estimates)
    sdrs = [scale_invariant_sdr(sources[n], estimates[matched[n]]) for n in sources if n in matched]
    return reconstruction, worst, float(np.mean(sdrs)), float(min(sdrs)), result


def main() -> int:
    sources = fixture.quartet_cast(duration=8.0, seed=7, octave_bottom=False)

    print(f"{'spread':<12} {'spatial':<9} {'recon dB':>9} {'max corr':>9} {'mean SI-SDR':>12} {'worst':>8}")
    for spread_name, pans in SPREADS.items():
        left, right = stereo_lib.render_stereo(sources, pans, fixture.SAMPLE_RATE)
        mono = 0.5 * (left + right)
        baseline = float(np.mean([scale_invariant_sdr(s, mono) for s in sources.values()]))

        for use_pan in (False, True):
            recon, worst, mean_sdr, worst_sdr, result = evaluate(sources, left, right, 4, use_pan)
            print(
                f"{spread_name:<12} {'pan' if use_pan else 'off':<9} {recon:>9.1f} {worst:>9.3f} "
                f"{mean_sdr:>12.2f} {worst_sdr:>8.2f}"
            )
            if use_pan:
                estimated = ", ".join(f"{p:+.2f}" for p in sorted(set(np.round(result["pans"], 2))))
                print(f"{'':<12} {'':<9} estimated pans: {estimated}")
                # The delivered stem is stereo, and a panned voice is cleanest in the
                # channel it was panned toward, so the mono sum understates what a listener
                # would hear. Report the better channel per part as well.
                matched = match_parts(sources, result["parts"])
                per_channel = []
                for name in sources:
                    if name not in matched:
                        continue
                    index = matched[name]
                    per_channel.append(
                        max(
                            scale_invariant_sdr(sources[name], result["parts_left"][index]),
                            scale_invariant_sdr(sources[name], result["parts_right"][index]),
                        )
                    )
                print(
                    f"{'':<12} {'':<9} best-channel SI-SDR: mean {np.mean(per_channel):>6.2f} "
                    f"worst {min(per_channel):>6.2f}"
                )
        print(f"{'':<12} {'(baseline)':<9} {'':>9} {'':>9} {baseline:>12.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
