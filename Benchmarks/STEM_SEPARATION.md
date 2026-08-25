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

## 2026-08-25 — Current 6-stem ONNX path, CPU vs CoreML EP (measured)

Machine: 8P+4E Apple Silicon, 24 GB. Input: "What's the Use" (3:36, 44.1 kHz
stereo). Release build, cold analysis cache, both optional refiners disabled,
`--stages separation` via the headless CLI.

| Provider | Wall clock | Notes |
| --- | --- | --- |
| CPU (production default) | 49 s | 6 threads, ~3.9 GB arena |
| CoreML/ANE (`SW_STEM_COREML=1`, since removed) | 472 s | graph split into 120 partitions of 1542 nodes; per-partition CPU<->ANE handoffs dominate |

Verdict: the CoreML execution provider is ~10x SLOWER for this export and was
removed rather than left as a trap. The karaoke BS-RoFormer ONNX fails the same
way (179 partitions of 3341 nodes, ~59 s compile per session, SIGKILLed twice
on 24 GB). ONNX Runtime's CoreML EP requires near-total op coverage in one
partition to win; neither export has it. Acceleration paths that could work:
a native Core ML model conversion (single graph, no EP partitioning) or a
smaller/faster model export — not a provider flag on the existing ONNX files.

For context, karaoke lead/backing refiner on the same track and build: 473 s
originally, 310 s after raising intra-op threads 4->8, 172 s after skipping
near-silent chunks and halving overlap to 1/8 segment.

## 2026-08-26 — Native Core ML export of htdemucs_6s (tools/demucs_export/export_coreml.py)

Converted the SAME 6-stem model the ONNX path uses, via torch.jit.trace +
coremltools 9 (FP16 mlprogram, fixed 7.8 s input). Required: the repo's
real-STFT patch (Core ML has no general complex dtype — native torch.stft
lowers, but the first slice on the complex tensor fails), a conv-transpose
overlap-add in place of F.fold (Core ML col2im needs stride >= kernel), a
rank-5 rewrite of the cac mask (rank-6 tensors rejected), and an aten::Int
converter shim. Patched-vs-stock parity 66 dB worst stem: patches are clean.

Per 7.8 s chunk, same Mac as all measurements above:

| Configuration | Time | Worst stem SDR vs FP32 torch | Verdict |
| --- | --- | --- | --- |
| .all (ANE fails to compile; FP16 Metal carries it) | 0.48 s | 19.2 dB, finite | PASS — ship candidate |
| .cpuOnly | 0.40 s | 9.7 dB | FAIL — numerics, not speed |
| .cpuAndGPU with FP32 DFT ops | 91.8 s | — | never ship; Metal chokes on FP32 matmuls |
| ONNX Runtime CPU (production) | ~1.7 s | exact-class | current baseline |

Compute unit CHANGES NUMERICS for this model: the Swift integration must pin
.all and treat any fallback as an error, not a degradation. FP16-vs-FP32
deviation of ~19-30 dB is the same class as the shipped June 4-stem package
(0.99 correlation) and far below the separation model's own error; the ship
gate is a real-song A/B against the ONNX production stems plus downstream
chord/beat equality, not synthetic SDR alone.

Projected: base separation for a 3:36 song ~15-20 s vs 49 s ONNX CPU, and it
frees the CPU for the transcription/refiner phases that now run concurrently.

### Real-song A/B, native Core ML vs production ONNX (2026-08-26)

"What's the Use" (3:36), release CLI, cold cache, refiners off, engine behind
`SW_STEM_NATIVE_COREML_MODEL`:

- Wall clock: 37 s (includes first-run mlpackage compile) vs 49 s ONNX CPU.
  Inference is ~18 s of the 37; stem WAV writing now dominates.
- Stem parity vs the ONNX stems: vocals 58.1 dB, guitar 55.4, drums 55.1,
  accompaniment 54.7, bass 53.9, other 43.4 — all above the 40 dB inaudible
  bar. Piano reads 22.4 dB only because the stem is ~-70 dBFS silence in this
  track; its absolute difference is -93 dBFS.
- The synthetic-noise SDR (~19-30 dB) understated real-music parity by ~35 dB:
  random noise is out-of-distribution and FP16-hostile. Judge FP16 conversions
  on real audio.

Not yet promoted to default: needs a distribution decision for the 172 MB
mlpackage (host alongside the other catalog models vs bundle) and a listening
pass. The ONNX CPU path remains the default and the fallback.
