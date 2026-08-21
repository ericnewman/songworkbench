"""Stereo evidence for part separation.

The mono spike closed with a specific claim: at four voices the limit is *evidence*, not
estimation — three progressively cleverer magnitude masks bought 1.7 dB between them. This
module tests the obvious source of extra evidence, and the one real backing stacks actually
carry: **where each voice sits in the stereo field.**

Two voices colliding on a partial are indistinguishable in a mono magnitude spectrum. If
they are panned differently, that same bin has an inter-channel level ratio that is a
mixture of their two pan positions — so a voice's share of the bin becomes estimable
instead of assumed.

Kept separate from `parts.py` so the validated mono chain is not disturbed; the f0 tracking,
fingerprinting and clustering are reused from there unchanged.
"""

from __future__ import annotations

import numpy as np

import parts as part_lib


def pan_gains(pan: float) -> tuple[float, float]:
    """Equal-power panning. -1 is hard left, +1 is hard right."""
    angle = (np.clip(pan, -1.0, 1.0) + 1.0) * 0.25 * np.pi
    return float(np.cos(angle)), float(np.sin(angle))


def render_stereo(
    sources: dict[str, np.ndarray], pans: dict[str, float], sample_rate: int
) -> tuple[np.ndarray, np.ndarray]:
    """Mix mono sources into a stereo field at the given pan positions."""
    length = max(len(signal) for signal in sources.values())
    left = np.zeros(length)
    right = np.zeros(length)
    for name, signal in sources.items():
        gain_left, gain_right = pan_gains(pans.get(name, 0.0))
        left[: len(signal)] += signal * gain_left
        right[: len(signal)] += signal * gain_right
    peak = max(np.max(np.abs(left)), np.max(np.abs(right)))
    if peak > 0:
        left /= peak
        right /= peak
    return left, right


def track_pan(
    track: part_lib.Track,
    left_magnitude: np.ndarray,
    right_magnitude: np.ndarray,
    frequencies: np.ndarray,
    partials: int = 10,
) -> float:
    """Estimate where this voice sits, from the partials it is least likely to share.

    Every partial gives a pan reading, but a shared one reads as a blend of two voices.
    The median across partials is the robust summary: a voice would have to be colliding
    on most of its harmonic series at once for it to mislead.
    """
    readings = []
    for frame, f0 in zip(track.frames, track.f0):
        for harmonic in range(1, partials + 1):
            center = f0 * harmonic
            if center >= frequencies[-1]:
                break
            magnitude_left = float(np.interp(center, frequencies, left_magnitude[frame]))
            magnitude_right = float(np.interp(center, frequencies, right_magnitude[frame]))
            total = magnitude_left + magnitude_right
            if total <= 1e-9:
                continue
            readings.append((magnitude_right - magnitude_left) / total)
    return float(np.median(readings)) if readings else 0.0


def spatial_masks(
    tracks: list[part_lib.Track],
    labels: np.ndarray,
    part_count: int,
    left_magnitude: np.ndarray,
    right_magnitude: np.ndarray,
    config: part_lib.STFTConfig,
    partials: int = 12,
    width_bins: float = 2.0,
    pan_sigma: float = 0.30,
) -> np.ndarray:
    """Harmonic masks weighted by how well each bin's observed pan matches each voice.

    The harmonic template says *where* a voice's energy should be; the spatial term says
    *how much* of what is actually there belongs to it. Neither is sufficient alone: pan
    without harmonics cannot tell two co-panned voices apart, and harmonics without pan is
    the mono chain that already hit its ceiling.
    """
    frequencies = config.frequencies
    bin_width = frequencies[1] - frequencies[0]
    masks = np.zeros((part_count, *left_magnitude.shape))

    total_magnitude = left_magnitude + right_magnitude
    with np.errstate(invalid="ignore", divide="ignore"):
        observed_pan = np.where(
            total_magnitude > 1e-9, (right_magnitude - left_magnitude) / np.maximum(total_magnitude, 1e-12), 0.0
        )

    pans = [track_pan(track, left_magnitude, right_magnitude, frequencies) for track in tracks]

    for track, label, pan in zip(tracks, labels, pans):
        for frame, f0 in zip(track.frames, track.f0):
            for harmonic in range(1, partials + 1):
                center = f0 * harmonic
                if center >= frequencies[-1]:
                    break
                low = int(max(0, np.floor((center - 3.0 * width_bins * bin_width) / bin_width)))
                high = int(min(len(frequencies) - 1, np.ceil((center + 3.0 * width_bins * bin_width) / bin_width)))
                if high <= low:
                    continue
                span = frequencies[low : high + 1]
                bump = np.exp(-0.5 * ((span - center) / (width_bins * bin_width)) ** 2) / harmonic
                affinity = np.exp(
                    -0.5 * ((observed_pan[frame, low : high + 1] - pan) / pan_sigma) ** 2
                )
                masks[label, frame, low : high + 1] += bump * affinity

    total = masks.sum(axis=0)
    unclaimed = total <= 1e-8
    with np.errstate(invalid="ignore", divide="ignore"):
        masks = np.where(unclaimed[None, :, :], 0.0, masks / np.maximum(total, 1e-12)[None, :, :])
    masks[:, unclaimed] = 1.0 / part_count
    return masks, pans


def separate_stereo(
    left: np.ndarray,
    right: np.ndarray,
    part_count: int,
    config: part_lib.STFTConfig | None = None,
    use_pan: bool = True,
) -> dict[str, object]:
    """Full stereo chain. f0 tracking runs on the mid signal; masking uses both channels.

    Tracking on mid rather than per channel is deliberate: a voice panned hard to one side
    is weak in the other, and running the estimator twice would produce two track sets that
    then have to be reconciled. The mid has every voice in it.
    """
    config = config or part_lib.STFTConfig()
    mid = 0.5 * (left + right)

    left_spectrogram = part_lib.stft(left, config)
    right_spectrogram = part_lib.stft(right, config)
    mid_magnitude = np.abs(part_lib.stft(mid, config))
    left_magnitude = np.abs(left_spectrogram)
    right_magnitude = np.abs(right_spectrogram)

    salience_config = part_lib.SalienceConfig()
    frame_energy = mid_magnitude.sum(axis=1)
    voiced = frame_energy > 0.02 * frame_energy.max()
    peaks_per_frame = [
        part_lib.estimate_f0s(mid_magnitude[frame], config.frequencies, salience_config, part_count + 1, 0.10)
        if voiced[frame]
        else []
        for frame in range(mid_magnitude.shape[0])
    ]
    tracks = part_lib.form_tracks(peaks_per_frame)
    fingerprints = [part_lib.fingerprint(track, mid_magnitude, config) for track in tracks]
    labels = part_lib.assign_parts(tracks, fingerprints, part_count)

    if use_pan:
        masks, pans = spatial_masks(
            tracks, labels, part_count, left_magnitude, right_magnitude, config
        )
    else:
        masks = part_lib.harmonic_masks(tracks, labels, part_count, mid_magnitude, config)
        pans = [0.0] * len(tracks)

    parts_left = [part_lib.istft(left_spectrogram * masks[i], config, len(left)) for i in range(part_count)]
    parts_right = [part_lib.istft(right_spectrogram * masks[i], config, len(right)) for i in range(part_count)]
    return {
        "parts_left": parts_left,
        "parts_right": parts_right,
        "parts": [0.5 * (l + r) for l, r in zip(parts_left, parts_right)],
        "tracks": tracks,
        "labels": labels,
        "pans": pans,
    }
