"""Print the track table with ground truth, to see WHERE the chain loses a part.

    python3 tools/harmony_parts_spike/debug_tracks.py [distinct|hard] [parts]

One row per detected note: when a part comes out wrong, this says whether the cause was
f0 estimation (wrong hz), track formation (fragmented spans), or clustering (right hz,
wrong label).
"""

from __future__ import annotations

import sys
from collections import Counter
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import fixture  # noqa: E402
import parts as part_lib  # noqa: E402
from run_spike import track_truth  # noqa: E402

cast = sys.argv[1] if len(sys.argv) > 1 else "hard"
part_count = int(sys.argv[2]) if len(sys.argv) > 2 else 4

sources = {"hard": fixture.default_cast, "distinct": fixture.distinct_cast, "quartet": fixture.quartet_cast}[cast](duration=8.0, seed=7)
signal = fixture.mix(sources, gains={"lead": 1.0, "double": 0.55, "harmony_high": 0.6, "harmony_low": 0.5})
config = part_lib.STFTConfig(sample_rate=fixture.SAMPLE_RATE)
table = fixture.quartet_lines() if cast == "quartet" else fixture.cast_lines()
lines = {name: notes for name, notes in table.items() if name in sources}

result = part_lib.separate(signal, part_count, config=config)
tracks = result["tracks"]
labels = result["labels"]
fingerprints = result["fingerprints"]
frame_rate = config.sample_rate / config.hop

print(f"cast={cast} parts={part_count} sources={sorted(sources)}")
print(
    f"{'#':>3} {'start':>6} {'end':>6} {'hz':>8} {'midi':>6} {'label':>5} {'truth':>13} "
    f"{'bright':>7} {'tilt':>6} {'vibHz':>6} {'vibC':>6}"
)
truths = []
for index, (track, label, fp) in enumerate(zip(tracks, labels, fingerprints)):
    midi = 69.0 + 12.0 * np.log2(track.median_hz / 440.0)
    truth = track_truth(track, lines, config, sorted(sources))
    truths.append(truth)
    print(
        f"{index:>3} {track.start / frame_rate:>6.2f} {track.end / frame_rate:>6.2f} "
        f"{track.median_hz:>8.1f} {midi:>6.1f} {label:>5} {truth:>13} "
        f"{fp.brightness:>7.2f} {fp.tilt:>6.2f} {fp.vibrato_rate:>6.2f} {fp.vibrato_depth:>6.1f}"
    )

print("\nlabel -> true owners:")
for label in sorted(set(labels)):
    owners = Counter(truths[i] for i in range(len(tracks)) if labels[i] == label)
    print(f"  {label}: {dict(owners)}")
