# 04 — Native STFT/ISTFT core with golden parity

Status: needs-triage

## Problem

There is no inverse STFT in `Sources/`. Both prior mask-model integrations dodged it by baking
STFT+ISTFT into the ONNX export. Native part assignment (issues 05/06) is mask-based with no
graph to hide behind, so the core has to exist.

`HybridDemucsFrequencyFeatures` is forward-only and hardcodes n_fft 4096 (`:11`); DrumSep depends
on it, so generalising it is a shared-path change.

## Work

- Parameterised STFT (n_fft, hop, window) on the existing vDSP path.
- ISTFT with overlap-add and exact window normalisation (COLA-correct).
- Golden-parity tests against a reference implementation, including the float64-kernel lesson from
  the karaoke export: float32 DFT kernels cost ~35 dB before any model runs.
- Close the open DrumSep gap: PyTorch golden parity for the forward packing.

## Acceptance

- [ ] Round-trip STFT→ISTFT of real audio ≥ 120 dB SDR.
- [ ] Parity vs reference ≥ 100 dB on forward transform.
- [ ] DrumSep packing parity test lands with a recorded number.
- [ ] No regression in DrumSep output (byte-comparable or ≥ 120 dB SDR vs the previous path).
