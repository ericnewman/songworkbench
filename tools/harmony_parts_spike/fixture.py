"""Synthetic multi-singer fixture with ground truth.

The point of a synthetic fixture is that every metric downstream has something to be
right or wrong ABOUT. On a real backing stem there is no ground truth, so a part
assignment that looks plausible cannot be distinguished from one that is wrong.

Each singer is a source-filter model: a bandlimited glottal pulse train (harmonics at
1/h amplitude with a per-singer spectral tilt) shaped by three formants. Singers differ
in formants, tilt, vibrato rate/depth, and onset jitter — i.e. in TIMBRE, which is
exactly the axis the part-assignment layer claims to exploit.

The default cast is deliberately the hard case from the PRD taxonomy:

    lead          — the main line
    double        — the SAME singer tracked twice: same formants, ±8 cents, 12 ms late
    harmony_high  — a different singer a third above
    harmony_low   — a different singer a sixth below

`double` is the case pitch alone cannot solve: its f0 is the lead's f0. If a method
separates lead from double, it did so on timbre and micro-timing, not on pitch.
"""

from __future__ import annotations

import numpy as np

SAMPLE_RATE = 22_050


class Voice:
    """One singer: a formant set, a spectral tilt, and a vibrato signature."""

    def __init__(
        self,
        name: str,
        formants: tuple[float, float, float],
        tilt: float,
        vibrato_rate: float,
        vibrato_cents: float,
        bandwidths: tuple[float, float, float] = (90.0, 110.0, 160.0),
    ) -> None:
        self.name = name
        self.formants = formants
        self.tilt = tilt
        self.vibrato_rate = vibrato_rate
        self.vibrato_cents = vibrato_cents
        self.bandwidths = bandwidths

    def envelope(self, frequencies: np.ndarray) -> np.ndarray:
        """Formant envelope (three resonances) times the glottal spectral tilt."""
        gain = np.zeros_like(frequencies)
        for center, bandwidth in zip(self.formants, self.bandwidths):
            gain += 1.0 / (1.0 + ((frequencies - center) / bandwidth) ** 2)
        tilt = (frequencies / 100.0) ** (-self.tilt)
        return gain * tilt


# Two physically distinct singers plus a "same singer" clone used for the double.
SINGER_A = Voice("A", formants=(620.0, 1_180.0, 2_600.0), tilt=0.85, vibrato_rate=5.4, vibrato_cents=28.0)
SINGER_B = Voice("B", formants=(430.0, 1_950.0, 2_900.0), tilt=1.15, vibrato_rate=6.3, vibrato_cents=42.0)
SINGER_C = Voice("C", formants=(760.0, 1_420.0, 2_350.0), tilt=0.65, vibrato_rate=4.7, vibrato_cents=18.0)
SINGER_D = Voice("D", formants=(520.0, 1_650.0, 2_150.0), tilt=1.35, vibrato_rate=5.9, vibrato_cents=12.0)


def midi_to_hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


def render_line(
    voice: Voice,
    notes: list[tuple[float, float, float]],
    duration: float,
    sample_rate: int = SAMPLE_RATE,
    detune_cents: float = 0.0,
    delay_seconds: float = 0.0,
    partials: int = 14,
    seed: int = 0,
) -> np.ndarray:
    """Render one sung line.

    `notes` is a list of (start_seconds, end_seconds, midi_pitch). Silence between notes
    is real silence, which is what makes voiced/unvoiced gating testable.
    """
    rng = np.random.default_rng(seed)
    total = int(round(duration * sample_rate))
    out = np.zeros(total, dtype=np.float64)
    time = np.arange(total) / sample_rate

    for start, end, midi in notes:
        start = start + delay_seconds
        end = end + delay_seconds
        begin_index = int(round(start * sample_rate))
        end_index = min(int(round(end * sample_rate)), total)
        if end_index <= begin_index:
            continue
        length = end_index - begin_index
        local_time = np.arange(length) / sample_rate

        base = midi_to_hz(midi) * 2.0 ** (detune_cents / 1_200.0)
        # Vibrato with a random starting phase, plus slow drift so f0 is never exactly constant.
        vibrato_phase = rng.uniform(0.0, 2.0 * np.pi)
        cents = voice.vibrato_cents * np.sin(
            2.0 * np.pi * voice.vibrato_rate * local_time + vibrato_phase
        )
        drift = 6.0 * np.sin(2.0 * np.pi * 0.35 * local_time + rng.uniform(0, 6.0))
        f0 = base * 2.0 ** ((cents + drift) / 1_200.0)

        # Per-sample phase so vibrato is actually frequency modulation, not a chirp artifact.
        phase = 2.0 * np.pi * np.cumsum(f0) / sample_rate
        note = np.zeros(length, dtype=np.float64)
        for harmonic in range(1, partials + 1):
            frequency = base * harmonic
            if frequency >= 0.45 * sample_rate:
                break
            amplitude = voice.envelope(np.array([frequency]))[0] / harmonic
            note += amplitude * np.sin(harmonic * phase + rng.uniform(0, 2.0 * np.pi))

        # Attack/release so note edges do not click (a click is broadband and would
        # contaminate the salience surface at every f0 at once).
        ramp = int(0.02 * sample_rate)
        window = np.ones(length)
        ramp = min(ramp, length // 2)
        if ramp > 0:
            window[:ramp] = np.linspace(0.0, 1.0, ramp)
            window[-ramp:] = np.linspace(1.0, 0.0, ramp)
        out[begin_index:end_index] += note * window

    peak = np.max(np.abs(out))
    if peak > 0:
        out /= peak
    return out


def cast_lines() -> dict[str, list[tuple[float, float, float]]]:
    """The score: per-singer (start, end, midi) note lists.

    Returned alongside the audio so evaluation has an exact ground truth. Deciding a
    track's true owner by "which source is loudest over this span" does NOT work when
    everyone sings at once — the lead is mixed loudest, so that test labels every track
    `lead` and reports nonsense. Owner has to be decided by which singer was actually on
    that pitch at that moment.
    """
    melody = [
        (0.30, 1.20, 67.0),  # G4
        (1.30, 2.20, 69.0),  # A4
        (2.30, 3.40, 71.0),  # B4
        (3.60, 4.60, 69.0),  # A4
        (4.80, 5.90, 67.0),  # G4
        (6.10, 7.60, 64.0),  # E4
    ]
    # A third above, except the last note, where it holds while the low part climbs past it.
    high = [(s, e, m + 4.0) for s, e, m in melody[:-1]] + [(6.10, 7.60, 68.0)]
    # A sixth below, except the last note, which crosses ABOVE the high part.
    low = [(s, e, m - 9.0) for s, e, m in melody[:-1]] + [(6.10, 7.60, 71.0)]

    return {"lead": melody, "double": melody, "harmony_high": high, "harmony_low": low}


def default_cast(duration: float = 8.0, seed: int = 7) -> dict[str, np.ndarray]:
    """Lead + its double + a harmony above + a harmony below.

    The melody sits in a normal backing-vocal range and includes a deliberate VOICE
    CROSSING: the low harmony rises above the high harmony's held note near the end,
    which is precisely where pitch-rank assignment ("highest track = high harmony")
    breaks and timbre has to carry the decision.
    """
    lines = cast_lines()
    return {
        "lead": render_line(SINGER_A, lines["lead"], duration, seed=seed),
        "double": render_line(
            SINGER_A, lines["double"], duration, detune_cents=8.0, delay_seconds=0.012, seed=seed + 1
        ),
        "harmony_high": render_line(SINGER_B, lines["harmony_high"], duration, seed=seed + 2),
        "harmony_low": render_line(SINGER_C, lines["harmony_low"], duration, seed=seed + 3),
    }


def distinct_cast(duration: float = 8.0, seed: int = 7) -> dict[str, np.ndarray]:
    """Three singers on three distinct pitch lines — no unison double.

    Same melody and same voice crossing as `default_cast`, minus the double. This is the
    tractable case: every part has its own f0 at every instant, so harmonic masking has
    something to key on. Comparing the two casts isolates exactly what the unison double
    costs.
    """
    cast = default_cast(duration=duration, seed=seed)
    del cast["double"]
    return cast


def quartet_cast(duration: float = 8.0, seed: int = 7, octave_bottom: bool = True) -> dict[str, np.ndarray]:
    """Four singers on four distinct pitch lines — the shape of the actual target.

    A four-note stack (root / third / fifth / octave-ish), four different voices, no
    unison. This is the configuration that answers "can we get four vocal parts?",
    because it is the only one where four parts are physically present to be found.
    """
    lines = quartet_lines(octave_bottom=octave_bottom)
    return {
        "part1_top": render_line(SINGER_B, lines["part1_top"], duration, seed=seed),
        "part2_upper_mid": render_line(SINGER_A, lines["part2_upper_mid"], duration, seed=seed + 1),
        "part3_lower_mid": render_line(SINGER_D, lines["part3_lower_mid"], duration, seed=seed + 2),
        "part4_bottom": render_line(SINGER_C, lines["part4_bottom"], duration, seed=seed + 3),
    }


def quartet_lines(octave_bottom: bool = True) -> dict[str, list[tuple[float, float, float]]]:
    """Score for `quartet_cast`, including one voice crossing between the middle parts.

    `octave_bottom` puts the bottom part exactly an octave below the top — the ordinary
    SATB voicing, and the case that breaks multi-f0 estimation, because the bottom voice's
    even partials ARE the top voice's harmonic series. Setting it False moves the bottom
    part up a semitone, which is musically almost the same chord and computationally a
    completely different problem. Running both is how the octave cost gets measured.
    """
    melody = [
        (0.30, 1.20, 72.0),
        (1.30, 2.20, 74.0),
        (2.30, 3.40, 76.0),
        (3.60, 4.60, 74.0),
        (4.80, 5.90, 72.0),
        (6.10, 7.60, 71.0),
    ]
    top = melody
    upper = [(s, e, m - 3.0) for s, e, m in melody[:-1]] + [(6.10, 7.60, 64.0)]
    lower = [(s, e, m - 7.0) for s, e, m in melody[:-1]] + [(6.10, 7.60, 67.0)]
    bottom = [(s, e, m - (12.0 if octave_bottom else 11.0)) for s, e, m in melody]
    return {
        "part1_top": top,
        "part2_upper_mid": upper,
        "part3_lower_mid": lower,
        "part4_bottom": bottom,
    }


def mix(sources: dict[str, np.ndarray], gains: dict[str, float] | None = None) -> np.ndarray:
    gains = gains or {}
    length = max(len(signal) for signal in sources.values())
    total = np.zeros(length, dtype=np.float64)
    for name, signal in sources.items():
        total[: len(signal)] += signal * gains.get(name, 1.0)
    peak = np.max(np.abs(total))
    if peak > 0:
        total /= peak
    return total
