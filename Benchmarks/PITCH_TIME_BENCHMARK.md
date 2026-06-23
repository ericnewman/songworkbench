# Pitch And Time Benchmark

## Fixed Corpus

- The 60-second CCS stem benchmark excerpt.
- Ten 20–30 second clips covering lead vocal, backing vocal, acoustic guitar,
  electric guitar, piano, bass, drums, dense stereo mix, sustained material,
  and transient-heavy material.
- Synthetic sine, harmonic stack, impulse, sweep, and vowel signals.

## Matrix

- Tempo: 0.5, 0.75, 0.9, 1.1, 1.25, 1.5, and 2.0.
- Pitch: -12, -7, -4, +4, +7, and +12 semitones.
- Combined: 0.75/+4, 1.25/-4, and 1.5/+7.
- Signalsmith: default, cheaper, and default with formant compensation.
- AVAudioUnitTimePitch: default plus documented overlap variations.

## Measurements

- Offline real-time factor, CPU time, peak RSS, allocations, and binary delta.
- Real-time callback median/P95/P99/max at 128, 256, and 512 frames.
- Output duration error, pitch error, transient spread/pre-echo, stereo
  correlation, spectral distance, and vowel formant displacement.
- Parameter-step clicks, discontinuities, and CPU spikes.
- Randomized loudness-matched MUSHRA-style listening with hidden reference and
  low-quality anchor.

## Adoption Gate

Adopt Signalsmith only if it has a statistically meaningful listening
advantage and meets the selected callback deadline with margin. Otherwise keep
AVAudioUnitTimePitch as the lower-risk system implementation.

## Execution Status

Executed on the fixed 60-second, 44.1 kHz stereo Float32 CCS excerpt on
2026-06-20. Both tools used optimized arm64 builds and exact requested output
durations.

| Case | AVAudioUnitTimePitch | Signalsmith 1.3.2 |
| --- | ---: | ---: |
| +4 semitones, 1.0x | 0.288 s | 0.464 s |
| 0 semitones, 0.75x | 0.245 s | 0.460 s |

- Both produced 60.000-second pitch-shift output and 80.000-second 0.75x
  output at 44.1 kHz stereo Float32.
- Standalone optimized harness sizes were 62 KB for Apple and 143 KB for
  Signalsmith. These are harness deltas, not final application link-map sizes.
- Signalsmith default configuration reported 5,292-sample blocks, 1,323-sample
  intervals, and 2,646 samples each of input/output latency.
- Signalsmith was 1.6x slower for +4 semitones and 1.9x slower for 0.75x in
  these offline runs, but both were substantially faster than real time.
- Outputs differ materially, as expected for different phase-vocoder
  algorithms. Zero-lag correlation was 0.045 for +4 semitones and 0.016 for
  0.75x; this is not a quality score.
- Apple peaks exceeded 1.0 in both cases (1.126 and 1.360). Signalsmith also
  exceeded 1.0 slightly or materially (1.000 and 1.293), so export requires
  float output or downstream peak management for either engine.

Reproduction tools live in `Benchmarks/Tools/`. The listening portion remains
a human evaluation because objective correlation cannot rank pitch/time
quality.

**Decision:** keep AVAudioUnitTimePitch as the default. It was faster, has no
third-party runtime footprint, and already supports the product range. Keep the
Objective-C++ Signalsmith path as a future quality option only if controlled
listening demonstrates a clear benefit for vocals/formant preservation.
