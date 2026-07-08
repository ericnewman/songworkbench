# Short-segment 6-stem HTDemucs export (iPad memory fit)

Produces a 3.5s-segment ONNX export of htdemucs_6s so stem separation fits a 4GB iPad
(onnxruntime peak RSS 1.95GB @3.5s vs 3.46GB @7.8s; the stock model OOM-jetsams at ~4.8GB total).

## Why
Stock demucsv4.onnx has a hard-fixed input [1,2,343980] (7.8s) and htdemucs internally pads any
shorter input back up to training_length, so memory can't be cut without re-exporting with a
smaller `model.segment`. torch's exporters reject demucs's complex STFT/iSTFT, so `realstft.py`
replaces spectro/ispectro with an all-real DFT (conv1d framing + matmul IDFT + fold overlap-add).

## Reproduce
    python -m venv venv && ./venv/bin/pip install torch demucs onnx onnxruntime onnxscript
    ./venv/bin/python export_dyn.py    # writes demucsv4_3p5s.onnx (+ .onnx.data)
    # then embed weights into a single file:
    #   onnx.save(onnx.load("demucsv4_3p5s.onnx"), "demucsv4_3p5s.onnx", save_as_external_data=False)

## Validation (2026-07-08)
- ONNX vs torch (patched real-STFT model): max abs diff 5.7e-6.
- Real-STFT vs stock complex-STFT full model: SDR 79dB (inaudible).
- Segment quality A/B (3.5s vs 7.8s, real song, energy-bearing stems): vocals 20dB, bass 18.6,
  drums 16.9, guitar 7.6dB; piano/other are near-silent in that track so their SDR is noise-floor.
- onnxruntime CPU EP peak RSS: 1.95GB @3.5s (fits 4GB iPad with increased-memory-limit).

## Wiring (TODO)
Bundle demucsv4_3p5s.onnx in the iPad app; predictor frameCount 343980 -> 154350;
segmentFrames 343980 -> 154350, overlap = /4; platform-branch (macOS keeps 7.8s); bump
engineVersion so cached stems regen.
