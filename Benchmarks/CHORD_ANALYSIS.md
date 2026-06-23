# Native Beat And Chord Analysis

## Fixed Input

The shared 60-second, 44.1 kHz stereo CCS benchmark excerpt with SHA-256
`47881ae99990322285269ca727ea39f66750d84b84a6171afe8c37a5273f3803`.

## Implementations

- Existing Python NumPy/FFmpeg timeline analyzer in
  `scripts/analyze_chord_timeline.py`.
- Native Swift pipeline using streaming AVFoundation decode, Accelerate/vDSP
  windowing and DFT, 12-bin chroma, major/minor templates, onset-envelope
  autocorrelation, practical-pulse tempo disambiguation, and measure-level
  chord voting.

## Results

| Measurement | Python | Native Swift |
| --- | ---: | ---: |
| Tempo | 99.08 BPM | 99.38 BPM |
| Beat count | 99 | 99 |
| Measure-level changes | 24 | 20 |
| Native analysis time | n/a | 0.065 s |

The native measure sequence begins `Bb, Eb, F, Bb, Ab` and ends
`Eb, Bb, Gm, Cm, Gm, Eb`. The Python sequence begins
`Bb, Eb, Ab, Bb, Ab` and ends `Eb, Bb, Eb, Cm, Gm`. Both remain centered on
the expected concert-Eb chord family, but they differ on accompaniment-heavy
and ambiguous measures.

## Validation Decision

The Swift port is validated as a fast editable-timeline initializer and tempo
detector. It is not treated as an authoritative automatic chart: the remaining
harmonic differences are why the UI exposes confidence, timestamps, and direct
editing. Stem-aware bass/accompaniment analysis remains the quality path for
reviewed charts.

The benchmark is reproducible with
`Benchmarks/Tools/native_analysis_benchmark.swift`; deterministic synthetic
tests cover framing, spectrum, chroma, major/minor classification, cancellation,
and 120 BPM click tracking.
