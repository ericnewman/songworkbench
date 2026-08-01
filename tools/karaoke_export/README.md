# Waveform-in/waveform-out karaoke BS-RoFormer export (lead vs backing vocals)

Produces `karaoke_waveform.onnx`, a rank-3 waveform-in / waveform-out ONNX export of the karaoke
BS-RoFormer that splits a vocal stem into lead and backing vocals.

## Why
The app's stem engines take a waveform contract (`StemChunkPredicting`): rank-3 `[1, 2, samples]`
in, rank-3 out. Community karaoke models ship in neither shape. They are either PyTorch `.ckpt`
(no ONNX at all) or spectrogram/mask-only ONNX: UVR-MDX-NET Karaoke 2 rejects rank-3 input
outright ("Invalid rank for input: Got: 3 Expected: 4"), and a pre-exported mel-band ONNX
declared `requires_external_stft_preprocess` / `requires_external_istft_postprocess` in its
metadata, i.e. it expects the caller to hand-roll the DSP. This export bundles the STFT **and**
the inverse STFT into the graph, so no DSP is re-implemented in Swift and no Python is needed at
runtime. torch's exporters reject complex STFT/iSTFT, so `karaoke_graph.py` rebuilds both from
all-real ops (conv1d framing, matmul IDFT, fold overlap-add) — the same trick as
`tools/demucs_export/realstft.py`.

Three gotchas cost real time and are encoded in the scripts:
- The 640000-sample (14.5 s) training chunk OOMs the tracer — time-axis attention is O(T^2) and
  the exporter holds every intermediate. It dies as a bare SIGKILL (exit 137) and Python's
  buffered stdout is lost with it, so the run looks silent: use `python3 -u`. 262144 samples
  (5.9 s) traces fine.
- `F.fold` lowers to `aten::col2im`, which needs opset 18 **and** a static `output_size`. A
  traced dynamic shape gives "TypeError: 'NoneType' object is not subscriptable (Occurred when
  translating col2im)", hence the Python-int frame geometry in `frame_geometry()`.
- Building the DFT kernels in float32 caps the forward STFT at ~86 dB against `torch.stft`
  (the angle `2*pi*k*n/N` has `k*n` up to ~2.1e6), and the 12-layer transformer amplifies that to
  ~48 dB end-to-end. Build them in float64 and cast to float32 — free, since they are graph
  constants.

## Reproduce
    # Python 3.12: torch has no 3.14 wheels. Install torch FIRST -- resolving `bs-roformer`
    # together with torch drags in an ancient `numba` that fails to build on 3.12.
    uv venv --python 3.12 rfvenv
    uv pip install --python rfvenv/bin/python torch onnx onnxruntime pyyaml einops soundfile
    uv pip install --python rfvenv/bin/python bs-roformer   # for rotary_embedding_torch et al.

    # Weights + config: HuggingFace anvuew/karaoke_bs_roformer
    #   karaoke_bs_roformer_anvuew.ckpt   (204,486,925 bytes)
    #   karaoke_bs_roformer_anvuew.yaml

    # Architecture code: ZFTurbo Music-Source-Separation-Training, models/bs_roformer/
    #   (bs_roformer.py + attend.py) -- NOT the `bs-roformer` pip package, which has moved to
    #   hyper-connections and mismatches this checkpoint by 668 missing / 240 unexpected
    #   state-dict keys. Vendor it as a package tree:
    #     zf/models/__init__.py                    (empty)
    #     zf/models/bs_roformer/__init__.py        (empty)
    #     zf/models/bs_roformer/bs_roformer.py
    #     zf/models/bs_roformer/attend.py

    rfvenv/bin/python -u export_karaoke.py kara.ckpt kara.yaml zf karaoke_waveform.onnx
    rfvenv/bin/python -u verify_export.py karaoke_waveform.onnx kara.ckpt kara.yaml zf \
        --audio real.wav

`--chunk` overrides the 262144-sample chunk baked into the graph.

## Validation (2026-07-31)
- `load_state_dict` missing=0 unexpected=0 (architecture matches the checkpoint exactly).
- Exported `karaoke_waveform.onnx`, 232.5 MB, opset 18: input `[1,2,262144]` rank-3 waveform ->
  output `[1,2,262144]` rank-3 waveform.
- Wrapper (real-arithmetic STFT/iSTFT) vs stock complex-STFT torch model: max abs 2.3e-8.
- Golden parity ONNX vs PyTorch on real audio: **103.1 dB SDR** (max_abs 1.99e-05,
  mean_abs 4.77e-07). Synthetic noise: 91.8 dB.
- Verified loadable by the app's own ONNX Runtime, with the rank-3 waveform contract accepted and
  rank-4 spectrogram shapes rejected.

## Wiring (TODO)
Consumed as a refiner on the vocals stem, producing `StemID.vocalLead` / `StemID.vocalBacking`
from the base separation's vocals output. Segmentation and overlap-add come for free by reusing
`CoreMLStemSeparationEngine` with segmentFrames 262144. The artifact is not yet hosted for
download, so nothing fetches it at runtime yet.
