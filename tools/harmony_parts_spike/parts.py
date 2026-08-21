"""Multi-f0 + timbral part assignment, offline.

This is the Python proof of PRD Layer 3 (`.scratch/multipart-stem-separation/PRD.md`).
It exists to answer one question before any Swift is written: on a vocal stack, do
per-note timbral fingerprints cluster by SINGER strongly enough to assign parts?

Chain:

    STFT -> harmonic-sum salience -> per-frame peaks -> f0 tracks
         -> per-track timbral fingerprint -> clustering into parts
         -> per-part harmonic soft masks -> ISTFT -> one signal per part

Two properties are deliberate and load-bearing:

* **The masks partition unity.** Every part's mask is divided by the sum of all masks,
  so the parts sum back to the input up to the STFT round-trip. That makes
  "reconstruction SDR" a measurement of the transform, not of the assignment, and it
  means no energy is invented or lost by the split.
* **Assignment is per TRACK, not per frame.** A part is a persistent voice, so the
  decision is made once per sung note using that note's whole timbral evidence, then
  applied to all its frames. Per-frame decisions flicker.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.spatial.distance import pdist


# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class STFTConfig:
    n_fft: int = 2_048
    hop: int = 256
    sample_rate: int = 22_050

    @property
    def window(self) -> np.ndarray:
        # sqrt-Hann analysis + sqrt-Hann synthesis with hop = n_fft/8 is COLA-exact,
        # which is what lets the round trip be measured in dB rather than assumed.
        return np.sqrt(np.hanning(self.n_fft + 1)[:-1])

    @property
    def frequencies(self) -> np.ndarray:
        return np.fft.rfftfreq(self.n_fft, 1.0 / self.sample_rate)


def stft(signal: np.ndarray, config: STFTConfig) -> np.ndarray:
    window = config.window
    padded = np.pad(signal, (config.n_fft // 2, config.n_fft), mode="constant")
    frame_count = 1 + (len(padded) - config.n_fft) // config.hop
    frames = np.lib.stride_tricks.as_strided(
        padded,
        shape=(frame_count, config.n_fft),
        strides=(padded.strides[0] * config.hop, padded.strides[0]),
    )
    return np.fft.rfft(frames * window, axis=1)


def istft(spectrogram: np.ndarray, config: STFTConfig, length: int) -> np.ndarray:
    window = config.window
    frames = np.fft.irfft(spectrogram, n=config.n_fft, axis=1) * window
    total = (frames.shape[0] - 1) * config.hop + config.n_fft
    out = np.zeros(total)
    norm = np.zeros(total)
    for index in range(frames.shape[0]):
        start = index * config.hop
        out[start : start + config.n_fft] += frames[index]
        norm[start : start + config.n_fft] += window**2
    out /= np.maximum(norm, 1e-8)
    return out[config.n_fft // 2 : config.n_fft // 2 + length]


# ---------------------------------------------------------------------------
# Salience and peaks
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SalienceConfig:
    minimum_hz: float = 80.0
    maximum_hz: float = 1_000.0
    bins_per_octave: int = 60  # 20 cents
    harmonics: int = 10
    harmonic_decay: float = 0.83

    @property
    def grid(self) -> np.ndarray:
        octaves = np.log2(self.maximum_hz / self.minimum_hz)
        count = int(round(octaves * self.bins_per_octave)) + 1
        return self.minimum_hz * 2.0 ** (np.arange(count) / self.bins_per_octave)


def frame_salience(
    spectrum: np.ndarray, frequencies: np.ndarray, salience_config: SalienceConfig
) -> np.ndarray:
    """Harmonic-sum salience for one frame: S(f) = Σ_h w^(h-1) · |X(h·f)|.

    Monophonic autocorrelation (what `BassLineAnalysis` does) returns one lag and so one
    answer per frame. A salience surface holds several simultaneous f0 candidates, which
    is the whole requirement for harmony.
    """
    grid = salience_config.grid
    out = np.zeros(len(grid))
    for harmonic in range(1, salience_config.harmonics + 1):
        targets = grid * harmonic
        usable = targets < frequencies[-1]
        if not np.any(usable):
            break
        weight = salience_config.harmonic_decay ** (harmonic - 1)
        # Linear interpolation across bins: at 20-cent resolution a partial rarely lands
        # on a bin centre, and nearest-neighbour sampling makes salience comb-shaped.
        out[usable] += weight * np.interp(targets[usable], frequencies, spectrum, right=0.0)
    return out


def salience(magnitude: np.ndarray, config: STFTConfig, salience_config: SalienceConfig) -> np.ndarray:
    """Whole-spectrogram salience surface (diagnostics; `estimate_f0s` is what runs)."""
    return np.vstack(
        [frame_salience(magnitude[frame], config.frequencies, salience_config) for frame in range(magnitude.shape[0])]
    )


def notch_partials(
    spectrum: np.ndarray, frequencies: np.ndarray, f0: float, partials: int, width_hz: float
) -> np.ndarray:
    """Remove one f0's harmonic series from a magnitude spectrum."""
    residual = spectrum.copy()
    for harmonic in range(1, partials + 1):
        center = f0 * harmonic
        if center >= frequencies[-1]:
            break
        residual *= 1.0 - np.exp(-0.5 * ((frequencies - center) / width_hz) ** 2)
    return residual


def octave_above_present(
    spectrum: np.ndarray, frequencies: np.ndarray, f0: float, partials: int, threshold: float = 3.0
) -> bool:
    """Is there an independent voice an octave above `f0`, hiding inside its partials?

    This is the octave trap, and it costs a whole part. A voice at 2·f0 contributes ONLY
    to the even partials of f0, so a full notch of f0 deletes it: measured on the quartet
    fixture, the C4 bottom voice was found first and its notch erased 523 Hz — its own 2nd
    partial and the C5 top voice's fundamental at once. The top voice was then never
    detected: 3 parts recovered out of 4.

    Subtracting more gently is NOT the fix — it lets the sub-harmonic ghosts back in. Tried
    and measured: track count 16 -> 41, note-assignment accuracy 0.95 -> 0.63 on the
    distinct cast. The two failure modes pull in opposite directions, so the notch stays
    aggressive and the octave gets its own test.

    The test: odd partials belong to the lower voice alone, so each even partial is
    predicted from its two odd NEIGHBOURS and compared against what is actually there.
    Neighbours, not a global fit — a straight line through the odd partials assumes a
    smoothly decaying spectrum, and formants are exactly what makes that false, so the
    global version fired constantly on voices with no octave partner at all (measured:
    note-assignment accuracy on the distinct cast fell 0.95 -> 0.65 from phantom voices).

    **This is off by default because it does not yet pay for itself.** Swept at thresholds
    1.7 / 2.2 / 3.0 against both casts, the best quartet result was 3 of 4 singers (the same
    as leaving it off) while the distinct cast degraded from 0.95 to 0.73 / 0.73 / 0.67
    note-assignment accuracy, with one part's SI-SDR collapsing below -30 dB as a phantom
    voice captured a part slot. Octave ambiguity is a known-hard multi-f0 problem; it needs
    real work, not a threshold. Kept here, wired and measured, so that work starts from
    evidence rather than from scratch.
    """
    centers = np.array([f0 * h for h in range(1, partials + 1) if f0 * h < frequencies[-1]])
    if len(centers) < 7:
        return False
    amplitudes = np.array([float(np.interp(center, frequencies, spectrum)) for center in centers])
    if amplitudes.max() <= 0:
        return False

    ratios = []
    for index in range(1, len(amplitudes) - 1, 2):  # 0-based: partials 2, 4, 6, ...
        neighbours = np.sqrt(max(amplitudes[index - 1], 1e-12) * max(amplitudes[index + 1], 1e-12))
        if neighbours <= 1e-9:
            continue
        ratios.append(amplitudes[index] / neighbours)
    if len(ratios) < 3:
        return False
    # Majority of even partials must be lifted, not just one near a formant peak.
    return bool(np.median(ratios) > threshold)


def estimate_f0s(
    spectrum: np.ndarray,
    frequencies: np.ndarray,
    salience_config: SalienceConfig,
    maximum_count: int,
    relative_floor: float,
    minimum_separation_cents: float = 70.0,
    rescue_octaves: bool = False,
) -> list[tuple[float, float]]:
    """Iterative-subtraction multi-f0 estimation (Klapuri-style).

    Plain peak-picking on a harmonic-sum surface does not work, and the failure is not
    subtle: measured on the fixture, the strongest peaks under a 392 Hz note were 196,
    130 and 99 Hz — 392/2, 392/3, 392/4. Those sub-harmonic ghosts filled every available
    peak slot and pushed the REAL harmony note (494 Hz) out of the estimate entirely.

    A ghost at f/2 draws almost all its salience from the true f0's partials, because its
    even partials *are* those partials. So: take the strongest candidate, notch its whole
    harmonic series out of the spectrum, and re-score. The ghost loses its support and
    collapses; a genuinely independent voice keeps its own partials and survives.
    """
    residual = spectrum.copy()
    grid = salience_config.grid
    first_peak: float | None = None
    found: list[tuple[float, float]] = []

    for _ in range(maximum_count):
        surface = frame_salience(residual, frequencies, salience_config)
        if surface.max() <= 0:
            break
        index = int(np.argmax(surface))
        if index == 0 or index == len(surface) - 1:
            break

        left, middle, right = surface[index - 1 : index + 2]
        denominator = left - 2.0 * middle + right
        offset = 0.5 * (left - right) / denominator if denominator != 0 else 0.0
        hz = float(grid[index] * 2.0 ** (float(np.clip(offset, -0.5, 0.5)) / salience_config.bins_per_octave))

        if first_peak is None:
            first_peak = float(middle)
        elif middle < relative_floor * first_peak:
            break

        def is_new(candidate: float) -> bool:
            return not any(
                abs(1_200.0 * np.log2(candidate / other)) < minimum_separation_cents for other, _ in found
            )

        if is_new(hz):
            found.append((hz, float(middle)))
            # Octave rescue is OFF by default: measured, it costs more than it recovers.
            # See `octave_above_present` for the numbers.
            if (
                rescue_octaves
                and octave_above_present(residual, frequencies, hz, salience_config.harmonics)
                and is_new(2.0 * hz)
            ):
                found.append((2.0 * hz, float(middle)))

        width = max(2.5 * (frequencies[1] - frequencies[0]), 12.0)
        residual = notch_partials(residual, frequencies, hz, salience_config.harmonics, width_hz=width)
    return found


def pick_peaks(
    frame_salience: np.ndarray,
    grid: np.ndarray,
    maximum_peaks: int,
    relative_floor: float,
    minimum_separation_cents: float,
) -> list[tuple[float, float]]:
    """Local maxima of one salience frame, as (hz, salience), strongest first."""
    peak_value = frame_salience.max()
    if peak_value <= 0:
        return []
    interior = np.arange(1, len(frame_salience) - 1)
    candidates = interior[
        (frame_salience[interior] > frame_salience[interior - 1])
        & (frame_salience[interior] >= frame_salience[interior + 1])
        & (frame_salience[interior] >= relative_floor * peak_value)
    ]
    order = candidates[np.argsort(frame_salience[candidates])[::-1]]

    chosen: list[tuple[float, float]] = []
    for index in order:
        # Parabolic interpolation on the log-frequency axis: without it every f0 snaps to
        # a 20-cent grid, which is coarser than the vibrato we are trying to measure.
        left, middle, right = frame_salience[index - 1 : index + 2]
        denominator = left - 2.0 * middle + right
        offset = 0.5 * (left - right) / denominator if denominator != 0 else 0.0
        offset = float(np.clip(offset, -0.5, 0.5))
        hz = float(grid[index] * 2.0 ** (offset / 60.0))
        if any(abs(1_200.0 * np.log2(hz / other)) < minimum_separation_cents for other, _ in chosen):
            continue
        chosen.append((hz, float(middle)))
        if len(chosen) >= maximum_peaks:
            break
    return chosen


# ---------------------------------------------------------------------------
# Tracks
# ---------------------------------------------------------------------------


@dataclass
class Track:
    frames: list[int] = field(default_factory=list)
    f0: list[float] = field(default_factory=list)
    strength: list[float] = field(default_factory=list)

    @property
    def start(self) -> int:
        return self.frames[0]

    @property
    def end(self) -> int:
        return self.frames[-1]

    @property
    def median_hz(self) -> float:
        return float(np.median(self.f0))


def form_tracks(
    peaks_per_frame: list[list[tuple[float, float]]],
    maximum_step_cents: float = 60.0,
    maximum_gap_frames: int = 6,
    minimum_frames: int = 10,
) -> list[Track]:
    """Link per-frame peaks into continuous f0 tracks.

    A track is one sung note. Grouping first means the timbral fingerprint below is
    computed over a whole note's evidence instead of a single 12 ms frame, where a
    formant estimate is mostly noise.
    """
    active: list[Track] = []
    finished: list[Track] = []

    for frame_index, peaks in enumerate(peaks_per_frame):
        still_active = []
        for track in active:
            if frame_index - track.end > maximum_gap_frames:
                finished.append(track)
            else:
                still_active.append(track)
        active = still_active

        unclaimed = list(peaks)
        for track in sorted(active, key=lambda t: -t.end):
            if not unclaimed:
                break
            reference = track.f0[-1]
            distances = [abs(1_200.0 * np.log2(hz / reference)) for hz, _ in unclaimed]
            best = int(np.argmin(distances))
            if distances[best] <= maximum_step_cents:
                hz, strength = unclaimed.pop(best)
                track.frames.append(frame_index)
                track.f0.append(hz)
                track.strength.append(strength)

        for hz, strength in unclaimed:
            active.append(Track(frames=[frame_index], f0=[hz], strength=[strength]))

    finished.extend(active)
    return [track for track in finished if len(track.frames) >= minimum_frames]


# ---------------------------------------------------------------------------
# Timbral fingerprint
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Fingerprint:
    partial_envelope: np.ndarray  # log partial amplitudes, f0-normalised, unit-sum
    brightness: float  # harmonic centroid in partial index
    tilt: float  # slope of log amplitude vs log partial index
    noisiness: float  # 1 - harmonic energy / total energy in band
    vibrato_rate: float  # Hz
    vibrato_depth: float  # cents
    onset_frame: int

    def vector(self) -> np.ndarray:
        return np.concatenate(
            [
                self.partial_envelope,
                [self.brightness, self.tilt, self.noisiness, self.vibrato_rate, self.vibrato_depth],
            ]
        )


def fingerprint(
    track: Track,
    magnitude: np.ndarray,
    config: STFTConfig,
    partials: int = 8,
) -> Fingerprint:
    """Describe the VOICE that sang this note, as independently of its pitch as possible.

    Sampling at h·f0 rather than at fixed frequencies is what makes the descriptor
    comparable across notes: a singer's formant structure is a property of the singer,
    but it only looks that way if you measure it relative to the f0 being sung.
    """
    frequencies = config.frequencies
    amplitudes = np.zeros(partials)
    harmonic_energy = 0.0
    total_energy = 0.0

    for frame, f0 in zip(track.frames, track.f0):
        spectrum = magnitude[frame]
        for harmonic in range(1, partials + 1):
            target = f0 * harmonic
            if target >= frequencies[-1]:
                continue
            amplitudes[harmonic - 1] += float(np.interp(target, frequencies, spectrum))
        # Noisiness: how much of the band's energy is NOT sitting on this note's partials.
        band = spectrum[(frequencies > 0.5 * f0) & (frequencies < partials * f0)]
        total_energy += float(np.sum(band**2))
        harmonic_energy += float(
            np.sum(
                [
                    np.interp(f0 * h, frequencies, spectrum) ** 2
                    for h in range(1, partials + 1)
                    if f0 * h < frequencies[-1]
                ]
            )
        )

    amplitudes = np.maximum(amplitudes, 1e-9)
    normalised = amplitudes / np.sum(amplitudes)
    log_envelope = np.log(normalised)
    indices = np.arange(1, partials + 1)
    brightness = float(np.sum(indices * normalised))
    tilt = float(np.polyfit(np.log(indices), log_envelope, 1)[0])
    noisiness = float(np.clip(1.0 - harmonic_energy / max(total_energy, 1e-12), 0.0, 1.0))

    cents = 1_200.0 * np.log2(np.array(track.f0) / track.median_hz)
    rate, depth = vibrato(cents, config.sample_rate / config.hop)
    return Fingerprint(
        partial_envelope=log_envelope,
        brightness=brightness,
        tilt=tilt,
        noisiness=noisiness,
        vibrato_rate=rate,
        vibrato_depth=depth,
        onset_frame=track.start,
    )


def vibrato(cents: np.ndarray, frame_rate: float) -> tuple[float, float]:
    """Vibrato rate (Hz) and depth (cents) from a note's detrended f0 contour."""
    if len(cents) < 8:
        return 0.0, float(np.std(cents))
    detrended = cents - np.polyval(np.polyfit(np.arange(len(cents)), cents, 2), np.arange(len(cents)))
    spectrum = np.abs(np.fft.rfft(detrended * np.hanning(len(detrended))))
    frequencies = np.fft.rfftfreq(len(detrended), 1.0 / frame_rate)
    usable = (frequencies > 3.0) & (frequencies < 9.0)
    if not np.any(usable) or spectrum[usable].max() <= 0:
        return 0.0, float(np.std(detrended))
    rate = float(frequencies[usable][np.argmax(spectrum[usable])])
    return rate, float(np.std(detrended) * np.sqrt(2.0))


# ---------------------------------------------------------------------------
# Part assignment
# ---------------------------------------------------------------------------


def assign_parts(
    tracks: list[Track],
    fingerprints: list[Fingerprint],
    part_count: int,
    pitch_weight: float = 0.35,
) -> np.ndarray:
    """Cluster notes into parts by timbre, with pitch register as a weak secondary axis.

    Pitch is included but deliberately underweighted. Weighted to zero, a singer who
    sings both above and below the lead still lands in one cluster (correct) but two
    singers with similar voices in different registers collapse (wrong). Weighted
    heavily, it degenerates into pitch-rank assignment and voice crossings break it.
    """
    if not tracks:
        return np.zeros(0, dtype=int)
    if len(tracks) <= part_count:
        return np.arange(len(tracks))

    features = np.vstack([fp.vector() for fp in fingerprints])
    features = (features - features.mean(axis=0)) / (features.std(axis=0) + 1e-9)

    register = np.array([[1_200.0 * np.log2(track.median_hz / 220.0)] for track in tracks])
    register = (register - register.mean()) / (register.std() + 1e-9)

    combined = np.hstack([features, pitch_weight * register * np.sqrt(features.shape[1])])
    tree = linkage(pdist(combined), method="average")
    return fcluster(tree, t=part_count, criterion="maxclust") - 1


# ---------------------------------------------------------------------------
# Mask synthesis
# ---------------------------------------------------------------------------


def track_partial_profile(
    track: Track, magnitude: np.ndarray, frequencies: np.ndarray, partials: int
) -> np.ndarray:
    """This voice's own partial-amplitude profile, robust to partials it shares.

    Sampling the mixture at h·f0 overstates any partial another voice is also sitting on.
    A singer's spectral envelope is smooth, so cap each partial at what its neighbours
    imply: the inflated ones come back down, the voice's real formant structure survives.
    """
    profile = np.zeros(partials)
    for frame, f0 in zip(track.frames, track.f0):
        for harmonic in range(1, partials + 1):
            center = f0 * harmonic
            if center >= frequencies[-1]:
                break
            profile[harmonic - 1] += float(np.interp(center, frequencies, magnitude[frame]))
    if profile.max() <= 0:
        return np.array([1.0 / h for h in range(1, partials + 1)])

    capped = profile.copy()
    for index in range(len(profile)):
        low = profile[max(index - 1, 0)]
        high = profile[min(index + 1, len(profile) - 1)]
        capped[index] = min(profile[index], max(min(low, high) * 1.6, 0.4 * profile[index]))
    return capped / capped.max()


def nnls_masks(
    tracks: list[Track],
    labels: np.ndarray,
    part_count: int,
    magnitude: np.ndarray,
    config: STFTConfig,
    partials: int = 12,
    width_bins: float = 2.0,
) -> np.ndarray:
    """Fit every voice's amplitude at once, per frame, instead of guessing each in turn.

    The heuristic masks decide a voice's weight from its own partials, so at a collision
    both voices claim the same energy and the split falls back on their assumed shapes.
    Here the frame is modelled as a sum of harmonic templates — one per sounding track,
    each carrying that track's measured partial profile — and the per-voice amplitudes come
    from a non-negative least-squares fit of that model to the observed spectrum. A
    collision is then resolved by what the OTHER partials imply about each voice's level,
    which is evidence the per-voice heuristics cannot see.
    """
    from scipy.optimize import nnls

    frequencies = config.frequencies
    bin_width = frequencies[1] - frequencies[0]
    masks = np.zeros((part_count, *magnitude.shape))

    profiles = [track_partial_profile(track, magnitude, frequencies, partials) for track in tracks]

    # Which tracks sound in each frame, so each frame solves only its own small system.
    by_frame: dict[int, list[tuple[int, float]]] = {}
    for index, track in enumerate(tracks):
        for frame, f0 in zip(track.frames, track.f0):
            by_frame.setdefault(frame, []).append((index, f0))

    for frame, entries in by_frame.items():
        templates = np.zeros((len(frequencies), len(entries)))
        for column, (track_index, f0) in enumerate(entries):
            profile = profiles[track_index]
            for harmonic in range(1, partials + 1):
                center = f0 * harmonic
                if center >= frequencies[-1]:
                    break
                low = int(max(0, np.floor((center - 3.0 * width_bins * bin_width) / bin_width)))
                high = int(min(len(frequencies) - 1, np.ceil((center + 3.0 * width_bins * bin_width) / bin_width)))
                if high <= low:
                    continue
                span = frequencies[low : high + 1]
                templates[low : high + 1, column] += (
                    np.exp(-0.5 * ((span - center) / (width_bins * bin_width)) ** 2)
                    * profile[harmonic - 1]
                )

        active = templates.max(axis=0) > 0
        if not np.any(active):
            continue
        try:
            amplitudes, _ = nnls(templates[:, active], magnitude[frame])
        except RuntimeError:
            amplitudes = np.ones(int(active.sum()))

        column = 0
        for index, (track_index, _) in enumerate(entries):
            if not active[index]:
                continue
            masks[labels[track_index], frame] += amplitudes[column] * templates[:, index]
            column += 1

    total = masks.sum(axis=0)
    unclaimed = total <= 1e-8
    with np.errstate(invalid="ignore", divide="ignore"):
        masks = np.where(unclaimed[None, :, :], 0.0, masks / np.maximum(total, 1e-12)[None, :, :])
    masks[:, unclaimed] = 1.0 / part_count
    return masks


def interval_masks(
    tracks: list[Track],
    labels: np.ndarray,
    part_count: int,
    magnitude: np.ndarray,
    config: STFTConfig,
    partials: int = 12,
    width_bins: float = 2.0,
) -> np.ndarray:
    """Set each voice's level from the partials nothing else is standing on.

    This is the well-conditioned version of the estimator that failed. The NNLS fit
    (`nnls_masks`) read every voice's level off ALL of its partials, collided ones included,
    so at exactly the frequencies where the answer matters most the evidence was a mixture of
    the voices being told apart — and it bought 1.7 dB for 8x the cost.

    The interval sweep says which partials those are, in advance and exactly. Two voices at
    ratio p:q collide wherever the partial index is a multiple of q, so every voice except one
    in a unison or octave pair has partials that are exclusively its own. Estimate the level
    there, then divide the contested bins in proportion to levels that were never contested.

    A voice with NO exclusive partial — the q=1 case — keeps the comb's assumption, because
    there is nothing else to use. That is not a gap in the method; the interval sweep measured
    it as the point where spectral evidence runs out entirely.
    """
    frequencies = config.frequencies
    bin_width = frequencies[1] - frequencies[0]
    tolerance = 2.0 * bin_width
    masks = np.zeros((part_count, *magnitude.shape))

    by_frame: dict[int, list[tuple[int, float]]] = {}
    for index, track in enumerate(tracks):
        for frame, f0 in zip(track.frames, track.f0):
            by_frame.setdefault(frame, []).append((index, f0))

    centers_by_frame: dict[int, dict[int, list[float]]] = {}
    evidence: dict[int, list[float]] = {index: [] for index in range(len(tracks))}

    for frame, entries in by_frame.items():
        spectrum = magnitude[frame]
        centers = {
            index: [f0 * k for k in range(1, partials + 1) if f0 * k < frequencies[-1]]
            for index, f0 in entries
        }
        centers_by_frame[frame] = centers

        for index, _ in entries:
            for k, center in enumerate(centers[index], start=1):
                collides = any(
                    other != index
                    and any(abs(center - theirs) < tolerance for theirs in centers[other])
                    for other, _ in entries
                )
                if collides:
                    continue
                # Expected amplitude of partial k under the comb shape is g/k, so the level
                # this partial implies is its measured magnitude times k.
                evidence[index].append(float(np.interp(center, frequencies, spectrum)) * k)

    # A voice's level is a property of the voice, not of one 12 ms frame. Estimating it per
    # frame is what sank the two previous attempts: thin evidence makes a noisy gain, and a
    # noisy gain amplifies whichever voice is already winning the bin. Pool each track's
    # exclusive-partial evidence across all of its frames and decide once.
    track_gains: dict[int, float] = {}
    for index in range(len(tracks)):
        track_gains[index] = float(np.median(evidence[index])) if evidence[index] else float("nan")
    known = [value for value in track_gains.values() if np.isfinite(value)]
    fallback = float(np.mean(known)) if known else 1.0
    for index in track_gains:
        if not np.isfinite(track_gains[index]):
            track_gains[index] = fallback

    for frame, entries in by_frame.items():
        centers = centers_by_frame[frame]
        for index, _ in entries:
            for k, center in enumerate(centers[index], start=1):
                low = int(max(0, np.floor((center - 3.0 * width_bins * bin_width) / bin_width)))
                high = int(
                    min(len(frequencies) - 1, np.ceil((center + 3.0 * width_bins * bin_width) / bin_width))
                )
                if high <= low:
                    continue
                span = frequencies[low : high + 1]
                bump = np.exp(-0.5 * ((span - center) / (width_bins * bin_width)) ** 2)
                masks[labels[index], frame, low : high + 1] += bump * track_gains[index] / k

    total = masks.sum(axis=0)
    unclaimed = total <= 1e-8
    with np.errstate(invalid="ignore", divide="ignore"):
        masks = np.where(unclaimed[None, :, :], 0.0, masks / np.maximum(total, 1e-12)[None, :, :])
    masks[:, unclaimed] = 1.0 / part_count
    return masks


def harmonic_masks(
    tracks: list[Track],
    labels: np.ndarray,
    part_count: int,
    magnitude: np.ndarray,
    config: STFTConfig,
    partials: int = 12,
    width_bins: float = 2.0,
    mode: str = "comb",
) -> np.ndarray:
    """One soft mask per part, normalised so the masks partition unity.

    Where two parts share a partial the energy is split in proportion to each part's
    modelled amplitude there, which is the standard Wiener-style compromise: neither
    part gets a hole, and the sum is preserved exactly.

    `mode` decides what "each part's modelled amplitude" means, and the three values
    separate two independent changes so each can be measured on its own:

    * `comb` — a fixed 1/h harmonic comb, every track weighted equally. The original.
    * `comb_gain` — the same comb, scaled by a per-frame estimate of how loud this voice
      is right now.
    * `measured` — each track's own measured partial profile, no per-frame gain.
    * `measured_gain` — that profile, scaled by the per-frame gain as well.

    A fixed comb assumes every voice has the same spectral shape, which is the assumption
    the timbral layer spends its effort disproving: two singers on one note get identical
    masks and the split between them becomes arbitrary.
    """
    if mode not in {"comb", "comb_gain", "measured", "measured_gain"}:
        raise ValueError(f"unknown mask mode: {mode}")
    frequencies = config.frequencies
    bin_width = frequencies[1] - frequencies[0]
    masks = np.zeros((part_count, *magnitude.shape))

    for track, label in zip(tracks, labels):
        profile = (
            track_partial_profile(track, magnitude, frequencies, partials)
            if mode.startswith("measured")
            else np.array([1.0 / h for h in range(1, partials + 1)])
        )
        # Per-frame gain: how loud this voice is right now, read from the partials it is
        # least likely to be sharing. A low quantile is the robust choice — collisions can
        # only push a ratio up, never down.
        for frame, f0 in zip(track.frames, track.f0):
            observed = []
            for harmonic in range(1, partials + 1):
                center = f0 * harmonic
                if center >= frequencies[-1]:
                    break
                if profile[harmonic - 1] > 0.05:
                    observed.append(
                        float(np.interp(center, frequencies, magnitude[frame])) / profile[harmonic - 1]
                    )
            uses_gain = mode in {"comb_gain", "measured_gain"}
            gain = float(np.quantile(observed, 0.25)) if (observed and uses_gain) else 1.0

            for harmonic in range(1, partials + 1):
                center = f0 * harmonic
                if center >= frequencies[-1]:
                    break
                low = int(max(0, np.floor((center - 3.0 * width_bins * bin_width) / bin_width)))
                high = int(min(len(frequencies) - 1, np.ceil((center + 3.0 * width_bins * bin_width) / bin_width)))
                if high <= low:
                    continue
                span = frequencies[low : high + 1]
                bump = np.exp(-0.5 * ((span - center) / (width_bins * bin_width)) ** 2)
                masks[label, frame, low : high + 1] += bump * gain * profile[harmonic - 1]

    total = masks.sum(axis=0)
    unclaimed = total <= 1e-8
    with np.errstate(invalid="ignore", divide="ignore"):
        masks = np.where(unclaimed[None, :, :], 0.0, masks / np.maximum(total, 1e-12)[None, :, :])

    # Energy no part claimed (breath, consonants, reverb tails, model residue) has to go
    # somewhere or the parts stop summing to the input. Spreading it evenly is honest:
    # it is audibly "the rest of the stack", not attributed to a singer.
    masks[:, unclaimed] = 1.0 / part_count
    return masks


def separate(
    signal: np.ndarray,
    part_count: int,
    config: STFTConfig | None = None,
    salience_config: SalienceConfig | None = None,
    maximum_peaks: int | None = None,
    relative_floor: float = 0.10,
    mask_mode: str = "comb",
) -> dict[str, object]:
    """Full chain. Returns the part signals plus the intermediate evidence."""
    config = config or STFTConfig()
    salience_config = salience_config or SalienceConfig()
    maximum_peaks = maximum_peaks or part_count + 1

    spectrogram = stft(signal, config)
    magnitude = np.abs(spectrogram)

    # Voiced gating: a frame far below the loudest frame cannot support an f0 claim.
    frame_energy = magnitude.sum(axis=1)
    voiced = frame_energy > 0.02 * frame_energy.max()

    peaks_per_frame = [
        estimate_f0s(magnitude[frame], config.frequencies, salience_config, maximum_peaks, relative_floor)
        if voiced[frame]
        else []
        for frame in range(magnitude.shape[0])
    ]
    tracks = form_tracks(peaks_per_frame)
    fingerprints = [fingerprint(track, magnitude, config) for track in tracks]
    labels = assign_parts(tracks, fingerprints, part_count)
    if mask_mode == "interval":
        masks = interval_masks(tracks, labels, part_count, magnitude, config)
    elif mask_mode == "nnls":
        masks = nnls_masks(tracks, labels, part_count, magnitude, config)
    else:
        masks = harmonic_masks(tracks, labels, part_count, magnitude, config, mode=mask_mode)

    parts = [istft(spectrogram * masks[index], config, len(signal)) for index in range(part_count)]
    return {
        "parts": parts,
        "tracks": tracks,
        "fingerprints": fingerprints,
        "labels": labels,
        "peaks_per_frame": peaks_per_frame,
        "config": config,
        "salience_config": salience_config,
    }
