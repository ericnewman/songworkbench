"""f0 tracks -> note events.

Path A (documenting the note progression) and Path B (playable per-voice stems) share the
front half of the chain — STFT, multi-f0, tracks, timbral assignment — and then diverge
completely. Path B continues into mask synthesis and ISTFT. Path A stops here, at note
events, and never needs an inverse transform at all.

A note event is what the preview pane and any notation surface actually consume, and it
matches the shape the app already uses for bass notes (`BassNoteObservation`: timestamp,
MIDI number, confidence, and the fractional pitch it was rounded from, kept so a later pass
can re-arbitrate a borderline rounding).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

import parts as part_lib


@dataclass(frozen=True)
class NoteEvent:
    onset: float  # seconds
    offset: float  # seconds
    midi: int  # rounded MIDI note number
    pitch: float  # fractional MIDI the rounding came from
    confidence: float  # [0, 1]
    part: int  # which voice/part this note belongs to

    @property
    def duration(self) -> float:
        return self.offset - self.onset


def segment_track(
    track: part_lib.Track,
    part: int,
    frame_rate: float,
    strength_ceiling: float,
    split_semitones: float = 0.7,
    minimum_duration: float = 0.06,
) -> list[NoteEvent]:
    """Cut one f0 track into notes wherever its pitch settles somewhere new.

    Tracks are usually already one note each, because the tracker caps frame-to-frame
    motion at 60 cents and a leap therefore starts a new track. The exception that matters
    is a legato slide between two sung pitches, which stays inside one track and has to be
    cut here or two notes get reported as one.

    The comparison is against a running median rather than the previous frame: vibrato of
    ±40 cents would otherwise trip a per-frame threshold several times a second.
    """
    if not track.frames:
        return []

    pitches = 69.0 + 12.0 * np.log2(np.array(track.f0) / 440.0)
    window = max(3, int(0.05 * frame_rate) | 1)
    smoothed = np.array(
        [
            float(np.median(pitches[max(0, i - window // 2) : i + window // 2 + 1]))
            for i in range(len(pitches))
        ]
    )

    boundaries = [0]
    anchor = smoothed[0]
    for index in range(1, len(smoothed)):
        if abs(smoothed[index] - anchor) >= split_semitones:
            boundaries.append(index)
            anchor = smoothed[index]
    boundaries.append(len(smoothed))

    events: list[NoteEvent] = []
    for start, end in zip(boundaries, boundaries[1:]):
        if end <= start:
            continue
        onset = track.frames[start] / frame_rate
        offset = track.frames[end - 1] / frame_rate
        if offset - onset < minimum_duration:
            continue
        pitch = float(np.median(pitches[start:end]))
        # Confidence blends how strong the f0 was with how steady it stayed: a wandering
        # pitch is a weaker claim about a note than a held one at the same salience.
        strength = float(np.mean(track.strength[start:end])) / max(strength_ceiling, 1e-9)
        steadiness = float(np.exp(-np.std(pitches[start:end]) / 0.5))
        events.append(
            NoteEvent(
                onset=onset,
                offset=offset,
                midi=int(round(pitch)),
                pitch=pitch,
                confidence=float(np.clip(strength, 0.0, 1.0) * steadiness),
                part=int(part),
            )
        )
    return events


def notes_from_tracks(
    tracks: list[part_lib.Track], labels, config: part_lib.STFTConfig
) -> list[NoteEvent]:
    """Note events from an already-computed track set.

    Split out from `detect_notes` so the stereo chain — which finds tracks differently — can
    produce notes through exactly the same segmentation and confidence path. Track A and
    Track B share their front half; this is where Track A's half ends.
    """
    frame_rate = config.sample_rate / config.hop
    ceiling = max((max(track.strength) for track in tracks if track.strength), default=1.0)
    events: list[NoteEvent] = []
    for track, label in zip(tracks, labels):
        events.extend(segment_track(track, int(label), frame_rate, ceiling))
    return sorted(events, key=lambda event: (event.onset, event.pitch))


def detect_notes(
    signal: np.ndarray,
    part_count: int,
    config: part_lib.STFTConfig | None = None,
) -> list[NoteEvent]:
    """Path A end to end: audio in, note events out. No masks, no ISTFT."""
    config = config or part_lib.STFTConfig()
    result = part_lib.separate(signal, part_count, config=config)
    return notes_from_tracks(result["tracks"], result["labels"], config)


def match_notes(
    reference: list[tuple[float, float, float]],
    estimated: list[NoteEvent],
    onset_tolerance: float = 0.15,
    pitch_tolerance_cents: float = 50.0,
) -> tuple[int, list[float], list[float], list[tuple[int, int]]]:
    """Greedy note matching on the usual transcription terms: onset window + pitch window.

    Returns the number of matches, the pitch errors in cents, the onset errors in seconds,
    and the index pairs, so caller-side metrics (precision/recall, voice assignment) can be
    computed from one matching rather than several inconsistent ones.
    """
    pairs: list[tuple[float, int, int]] = []
    for reference_index, (start, _, midi) in enumerate(reference):
        for estimate_index, event in enumerate(estimated):
            onset_error = abs(event.onset - start)
            cents = abs(1_200.0 * np.log2(2.0 ** ((event.pitch - midi) / 12.0)))
            if onset_error <= onset_tolerance and cents <= pitch_tolerance_cents:
                pairs.append((onset_error, reference_index, estimate_index))
    pairs.sort()

    used_reference: set[int] = set()
    used_estimate: set[int] = set()
    matched: list[tuple[int, int]] = []
    pitch_errors: list[float] = []
    onset_errors: list[float] = []
    for onset_error, reference_index, estimate_index in pairs:
        if reference_index in used_reference or estimate_index in used_estimate:
            continue
        used_reference.add(reference_index)
        used_estimate.add(estimate_index)
        matched.append((reference_index, estimate_index))
        onset_errors.append(onset_error)
        pitch_errors.append(
            abs(1_200.0 * (estimated[estimate_index].pitch - reference[reference_index][2]) / 12.0)
        )
    return len(matched), pitch_errors, onset_errors, matched
