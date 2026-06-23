# Dependency Evaluation

Reviewed 2026-06-20 for a macOS 14, Apple Silicon-first application.

## Pitch And Time Processing

### AVAudioUnitTimePitch

- Ships with AVFAudio; no application binary or source dependency.
- Public range is -2400...2400 cents and 1/32...32 rate.
- Integrates directly with AVAudioEngine and manual offline rendering.
- Public controls are pitch, rate, and overlap. Apple documents no formant
  preservation control or guarantee.
- Current app implementation uses this engine for real-time playback and
  offline export.

Sources: [AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch),
[pitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch/pitch),
[rate](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch/1389380-rate),
[offline rendering](https://developer.apple.com/documentation/avfaudio/audio-engine).

### Signalsmith Stretch 1.3.2

- MIT-licensed, header-only C++11 library with a vendored Signalsmith Linear
  DSP dependency.
- Supports streaming and exact fixed-length processing, explicit input/output
  latency, multiple-octave pitch shifting, and formant compensation.
- The maintainer recommends modest time ratios around 0.75x...1.5x for best
  quality and warns that unoptimized debug builds can be much slower.
- A production Swift integration should use a narrow Objective-C++ wrapper,
  one mutable stretcher per stream, preallocated planar Float buffers, and no
  concurrent configuration/process calls.

Sources: [repository](https://github.com/Signalsmith-Audio/signalsmith-stretch),
[license](https://raw.githubusercontent.com/Signalsmith-Audio/signalsmith-stretch/main/LICENSE.txt),
[design](https://signalsmith-audio.co.uk/writing/2023/stretch-design/),
[Swift C++ interoperability](https://www.swift.org/documentation/cxx-interop/project-build-setup/).

**Decision:** retain AVAudioUnitTimePitch as the zero-dependency default. Adopt
Signalsmith only if the fixed-corpus listening/performance benchmark shows a
material advantage for difficult vocal and polyphonic transformations while
meeting real-time deadlines. The actual build benchmark remains recorded in
`PITCH_TIME_BENCHMARK.md`.

## Transcription

### FluidAudio / Parakeet

- Apache-2.0 Swift package targeting macOS 14 / iOS 17 with Core ML execution
  on the Apple Neural Engine.
- Fully local after model download and supports sliding-window cancellation.
- Parakeet exposes token timing; word grouping needs application-level
  validation.
- Parakeet TDT v3 is 0.6B parameters. The Core ML model repository is roughly
  1.76 GB.
- NVIDIA Parakeet weights use CC BY 4.0; preserve attribution even when a
  converted repository reports a different package license.

Sources: [FluidAudio](https://github.com/FluidInference/FluidAudio),
[package](https://github.com/FluidInference/FluidAudio/blob/main/Package.swift),
[API](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md),
[Parakeet model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
[Core ML files](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/main).

### whisper.cpp / SwiftWhisper

- whisper.cpp and SwiftWhisper are MIT-licensed and fully local after model
  installation.
- whisper.cpp supports Metal, Accelerate, and optional Core ML encoder
  acceleration. Direct integration provides more control than the SwiftWhisper
  wrapper.
- SwiftWhisper exposes progress, cancellation, and segment timestamps but not a
  stable public word-timestamp abstraction.
- The `large-v3-turbo-q5_0` GGML model is approximately 574 MB; full turbo is
  approximately 1.62 GB.
- Whisper code and weights are MIT-licensed.

Sources: [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[SwiftWhisper](https://github.com/exPHAT/SwiftWhisper),
[Whisper license](https://github.com/openai/whisper),
[GGML model files](https://huggingface.co/ggerganov/whisper.cpp/tree/main).

### Singing Risk

Published speech WER does not establish lyric accuracy. A 2025 lyrics study
reported Whisper full-mix WER around 23% and found systematic deletion of
backing vocals/vocables plus occasional separation-induced hallucinations.
Both original mix and separated vocals must therefore be benchmarked.

Source: [lyrics transcription study](https://arxiv.org/abs/2506.15514).

The fixed CCS song benchmark measured 31.96% WER for FluidAudio/Parakeet versus
5.67% for Whisper Large V3 with previous-text conditioning disabled. FluidAudio
completed in 29.03 seconds at 527 MB resident memory; the measured MLX Whisper
runtime took 95.65 seconds and 3.13 GB. See `TRANSCRIPTION_BENCHMARK.md`.

**Decision:** Whisper accuracy mode is the default for final sung-lyric work.
FluidAudio/Parakeet is the fast-draft option because its Swift/Core ML
integration, ANE execution, cancellation, and lower memory fit interactive use.
Direct whisper.cpp with a quantized model is preferred over depending on MLX in
the app. Models must be downloaded on demand rather than bundled.

## Stem Separation

- Demucs code is MIT-licensed; attribution must be preserved.
- The current HTDemucs Core ML candidate targets macOS 14, accepts 10-second
  44.1 kHz stereo chunks, outputs vocals/drums/bass/other, and requires CPU+GPU
  because the publisher reports invalid Neural Engine output.
- Published model sizes are 222 MB expanded for FP16 and 402 MB for FP32.
- The candidate has minimal adoption history, so runtime and listening
  validation are mandatory before distribution.

Sources: [Core ML candidate](https://github.com/dexxdean/htdemucs-coreml),
[release](https://github.com/dexxdean/htdemucs-coreml/releases/tag/v1.0.0),
[Demucs](https://github.com/facebookresearch/demucs).

The candidate's `ATTRIBUTION.md` explicitly licenses the pretrained HTDemucs
weights under MIT and requires preservation of the MIT notice and Meta
attribution when redistributing the converted model.

**Decision:** adopt as an optional downloaded engine. Fixed-input execution
produced four valid stems in 1.79 seconds warm with 0.981...0.993 correlation
to Python HTDemucs and 31.00 dB summed-stem reconstruction SNR. Its roughly
2 GB peak footprint and minimal upstream history preclude default bundling.

## Current Dependency Footprint

The shipping package currently has no third-party runtime dependency. It uses
SwiftUI, AVFoundation, Accelerate/vDSP, CryptoKit, and Foundation. Large ML
models will be optional, versioned downloads with visible size/license
information and cache controls.
