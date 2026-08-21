"""Does stereo position rescue an octave-related part?

    python3 tools/harmony_parts_spike/run_octave.py

The mono spike found that a voice an octave above another is lost outright: the estimator
finds the lower voice first and notches away its harmonic series, which contains the upper
voice's fundamental. 3 of 4 singers recovered, bottom part at -24.4 dB. That matters because
bottom-an-octave-below-top is an ordinary SATB voicing.

Pitch cannot separate them — one's partials are a subset of the other's. Position can. This
measures three configurations on the SAME octave-voiced quartet:

    mono            the original chain, for reference
    stereo mask     spatial term in the mask only (what run_stereo.py already tested)
    stereo track    f0 estimated per pan slice, so the upper voice survives estimation

A near-mono spread is run as the control: if "stereo track" helps there too, it is fitting
noise rather than exploiting position.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
import stereo as stereo_lib  # noqa: E402
from run_spike import correlation, match_parts, scale_invariant_sdr  # noqa: E402

WIDE = {"part1_top": -0.8, "part2_upper_mid": 0.8, "part3_lower_mid": -0.35, "part4_bottom": 0.35}
NEAR_MONO = {"part1_top": -0.1, "part2_upper_mid": 0.1, "part3_lower_mid": -0.03, "part4_bottom": 0.03}


def line_pitches(lines: dict) -> dict[str, list[float]]:
    return {name: [midi for _, _, midi in notes] for name, notes in lines.items()}


def lines_with_a_track(tracks, lines, config) -> int:
    """How many of the four scored parts have at least one f0 track on their pitch.

    This is the question the octave trap actually decides. SI-SDR can look mediocre for many
    reasons; "was this voice ever detected at all" has one cause.
    """
    frame_rate = config.sample_rate / config.hop
    found = 0
    for name, notes in lines.items():
        for start, end, midi in notes:
            hit = False
            for track in tracks:
                midpoint = 0.5 * (track.start + track.end) / frame_rate
                if not (start - 0.1) <= midpoint <= (end + 0.1):
                    continue
                track_midi = 69.0 + 12.0 * np.log2(track.median_hz / 440.0)
                if abs(track_midi - midi) < 0.6:
                    hit = True
                    break
            if hit:
                found += 1
                break
    return found


def run(label, sources, pans, config, lines, **kwargs) -> None:
    left, right = stereo_lib.render_stereo(sources, pans, fixture.SAMPLE_RATE)
    mono = 0.5 * (left + right)
    result = stereo_lib.separate_stereo(left, right, 4, config=config, **kwargs)
    estimates = result["parts"]

    worst = max(
        correlation(estimates[i], estimates[j])
        for i in range(len(estimates))
        for j in range(i + 1, len(estimates))
    )
    matched = match_parts(sources, estimates)
    sdrs = {n: scale_invariant_sdr(sources[n], estimates[matched[n]]) for n in sources if n in matched}
    baseline = float(np.mean([scale_invariant_sdr(s, mono) for s in sources.values()]))
    detected = lines_with_a_track(result["tracks"], lines, config)

    print(
        f"{label:<26} {detected}/4 {len(result['tracks']):>5} {worst:>9.3f} "
        f"{np.mean(list(sdrs.values())):>9.2f} {sdrs.get('part1_top', float('nan')):>9.2f} "
        f"{baseline:>9.2f}"
    )


def main() -> int:
    sources = fixture.quartet_cast(duration=8.0, seed=7, octave_bottom=True)
    lines = fixture.quartet_lines(octave_bottom=True)
    config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)

    print("octave-voiced quartet: part1_top is exactly one octave above part4_bottom\n")
    print(
        f"{'configuration':<26} {'det':>3} {'trks':>5} {'max corr':>9} "
        f"{'mean SDR':>9} {'top SDR':>9} {'baseline':>9}"
    )
    run("wide / mask only", sources, WIDE, config, lines, use_pan=True, spatial_tracking=False)
    run("wide / mask + spatial f0", sources, WIDE, config, lines, use_pan=True, spatial_tracking=True)
    run("wide / mask + octave-aware", sources, WIDE, config, lines, use_pan=True, octave_aware=True)
    run("wide / neither", sources, WIDE, config, lines, use_pan=False, spatial_tracking=False)
    print()
    run("near-mono / mask + spatial", sources, NEAR_MONO, config, lines, use_pan=True, spatial_tracking=True)
    run("near-mono / octave-aware", sources, NEAR_MONO, config, lines, use_pan=True, octave_aware=True)
    run("near-mono / neither", sources, NEAR_MONO, config, lines, use_pan=False, spatial_tracking=False)
    print("\ndet = how many of the 4 scored parts have an f0 track on their pitch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
