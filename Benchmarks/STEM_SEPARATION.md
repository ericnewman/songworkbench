# Stem Separation Benchmark

## Goal

Determine whether HTDemucs running through Core ML is suitable for a native,
offline macOS stem-separation workflow and materially reduces deployment risk
compared with bundling Python and PyTorch.

## Input

Use a representative 60-second stereo excerpt from the reviewed
`Summertime's here with you` alternate recording. It contains drums, bass,
vocals, and harmonic accompaniment and was previously separated successfully
with Python Demucs.

The excerpt must begin at a musically active section and be generated once as
44.1 kHz stereo WAV. Record its SHA-256 so every candidate receives identical
samples.

## Candidates

1. Python Demucs `htdemucs` as the established quality baseline.
2. HTDemucs Core ML using its documented Swift/macOS inference path.

## Measurements

- Repository, model, and dependency licenses.
- Model download size and on-disk installed size.
- Supported macOS versions and Apple Silicon requirements.
- Cold and warm end-to-end processing time.
- Peak memory where a repeatable measurement is available.
- Output sample rate, channel count, duration, and stem names.
- Mixture reconstruction error after summing all output stems.
- Per-stem RMS and spectral distribution as gross regression checks.
- Listening review for vocal leakage, transient smearing, bass loss, phase
  artifacts, and musical-noise artifacts.

## Acceptance Criteria

- Produces vocals, drums, bass, and other stems from the fixed input.
- All stems preserve input duration, sample rate, and stereo channels.
- No crashes, NaNs, clipped full-scale output, or large reconstruction error.
- Separation is close enough to Python Demucs for practice, lyric alignment,
  beat tracking, and chord analysis.
- Model and dependencies permit distribution in a macOS application.
- Integration does not require shipping a Python or PyTorch runtime.
- Processing time and memory are reasonable for offline work on the current
  Apple Silicon Mac.

## Decision States

- **Adopt:** meets quality and distribution requirements; integrate behind a
  `StemSeparationEngine` protocol.
- **Defer:** promising but blocked by measurable performance, packaging, or
  model-conversion work.
- **Reject:** quality, licensing, stability, or integration cost is unsuitable.

## Benchmark Record: 2026-06-20

### Fixed Input

- Source excerpt: seconds 30 through 90 of the reviewed Apr 20 alternate
  recording of `Summertime's here with you`.
- Format: 44.1 kHz, stereo, 32-bit float WAV.
- Duration: 60.000 seconds.
- Size: 21,168,092 bytes.
- SHA-256:
  `47881ae99990322285269ca727ea39f66750d84b84a6171afe8c37a5273f3803`.

### Python Demucs Baseline

- Runtime: Demucs `htdemucs` from the existing project virtual environment.
- Wall time: 18.38 seconds on the current Apple Silicon Mac.
- Output: vocals, drums, bass, and other; each 60.000 seconds, 44.1 kHz,
  stereo PCM.
- Output encoder produced 16-bit PCM despite requesting `--float32`; torchaudio
  reported that TorchCodec did not fully support the requested encoding. This
  is a baseline-export limitation, not a separation failure.
- Stem RMS levels: vocals -18.07 dBFS, drums -18.62 dBFS, bass -18.68 dBFS,
  other -22.14 dBFS.
- Stem peaks: vocals -2.03 dBFS, drums -0.09 dBFS, bass -5.34 dBFS, other
  -4.09 dBFS.

### Published Core ML Candidate Facts

- Repository release: `dexxdean/htdemucs-coreml` v1.0.0, published April 26,
  2026, with one repository commit and no established adoption history.
- Input: `(1, 2, 441000)` Float32, representing 10 seconds of 44.1 kHz stereo.
- Output: `(1, 4, 2, 441000)` Float32 in vocals, drums, bass, other order.
- Minimum platform: macOS 14 / iOS 17.
- Compute units: CPU and GPU. The publisher warns that Apple Neural Engine
  execution can produce invalid output.
- FP16 release artifact: 144 MB compressed and 222 MB expanded.
- FP32 release artifact: 224 MB compressed and 402 MB expanded.
- The repository's `ATTRIBUTION.md` explicitly states that its pretrained
  HTDemucs weights use the upstream MIT license and permits redistribution of
  the converted package when the MIT notice and Meta attribution are retained.
  This is publisher metadata rather than independent legal advice, but it is an
  explicit distribution grant rather than an inference from the code license.

### Core ML Execution

- Model: downloaded FP16 package, 222 MB expanded.
- Model compile/load: 6.90 seconds.
- Full 60-second separation: 1.95 seconds cold, 1.79 seconds warm.
- Process peak footprint: 2.00 GB (`/usr/bin/time -l` peak-memory metric).
- Output: four 60.000-second, 44.1 kHz stereo Float32 WAV files.
- All output samples are finite; peak magnitude is below full scale.
- Stem correlation against Python HTDemucs: vocals 0.9929, drums 0.9913,
  bass 0.9911, and other 0.9810.
- Summed-stem reconstruction: 0.00658 RMS residual, 31.00 dB SNR, and 0.999605
  correlation to the input. Python produced 0.00670 RMS, 30.84 dB, and
  0.999634 correlation.

The model emits FP16 output with padded strides despite documentation that
describes Float32 contiguous output. Consumers must branch on
`MLMultiArray.dataType` and use its reported strides. Core ML prediction
objects must also be released in a per-chunk autorelease pool; without that,
the seven-chunk run crashed after prediction objects accumulated.

Reproduce with:

```sh
xcrun swiftc -O Benchmarks/Tools/htdemucs_coreml_benchmark.swift \
  -o /tmp/htdemucs_coreml_benchmark
/usr/bin/time -l /tmp/htdemucs_coreml_benchmark \
  HTDemucs_CoreML_FP16.mlpackage INPUT.wav OUTPUT_DIRECTORY
python3 Benchmarks/Tools/compare_stem_outputs.py \
  INPUT.wav PYTHON_STEM_DIRECTORY OUTPUT_DIRECTORY
```

### Decision

**Adopt as an optional downloaded engine behind `StemSeparationEngine`.** It
meets output, reconstruction, license, and runtime criteria and is about 10x
faster than the local Python baseline after model load. Do not bundle it by
default: the 222 MB model, approximately 2 GB processing footprint, CPU+GPU
requirement, and minimal upstream history require visible download/storage
controls and a fallback error path. Objective output comparison found no gross
leakage or boundary regression; a human listening pass remains advisable
before a production release because correlation is not a perceptual metric.
