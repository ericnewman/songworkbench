#!/usr/bin/env python3
"""Gate the exported ONNX: (1) waveform I/O contract, (2) golden parity vs the PyTorch reference.

Parity is what makes a later listening test meaningful -- if the exported graph matches torch,
any quality complaint is the MODEL, not the export. An unfaithful export would make the quality
verdict unfalsifiable.

Synthetic noise is the cheap always-on case; pass --audio to add a real-song chunk, which is the
number worth quoting because noise exercises the mask estimators nothing like music does.
"""

import argparse
import sys
from pathlib import Path

SDR_GATE_DB = 60.0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("onnx", type=Path, help="exported .onnx to verify")
    parser.add_argument("checkpoint", type=Path, help="karaoke BS-RoFormer .ckpt")
    parser.add_argument("config", type=Path, help="matching model config .yaml")
    parser.add_argument(
        "model_code",
        type=Path,
        help="directory holding the vendored ZFTurbo models/bs_roformer/ package",
    )
    parser.add_argument(
        "--audio",
        type=Path,
        default=None,
        help="optional real-audio .wav (44.1 kHz) for a second, musically meaningful parity run",
    )
    return parser.parse_args(argv)


def real_audio_chunk(path, chunk):
    """Loudest `chunk`-sample stereo window of a wav, as a [1, 2, chunk] float32 tensor."""
    import numpy as np
    import soundfile as sf
    import torch

    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    if rate != 44100:
        print(f"WARNING: {path} is {rate} Hz; the model is trained at 44100 Hz")
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    audio = audio[:, :2]
    if len(audio) < chunk:
        audio = np.pad(audio, ((0, chunk - len(audio)), (0, 0)))
    # Pick the loudest window: a quiet intro would make the SDR a measure of silence.
    starts = range(0, max(len(audio) - chunk, 0) + 1, chunk)
    start = max(starts, key=lambda s: float((audio[s : s + chunk] ** 2).sum()))
    print(f"real_audio={path.name} rate={rate} frames={len(audio)} window_start={start}")
    return torch.from_numpy(audio[start : start + chunk].T.copy()).unsqueeze(0)


def parity(session, input_name, model, x, label):
    """Run both graphs on the same input and report ONNX-vs-torch SDR."""
    import numpy as np
    import torch

    with torch.no_grad():
        ref = model(x)
    if ref.ndim == 4:
        ref = ref[:, 0]
    ref = ref.numpy()
    got = session.run(None, {input_name: x.numpy()})[0]

    print(f"\n=== GOLDEN PARITY [{label}] (ONNX vs PyTorch reference) ===")
    print(f"ref_shape={ref.shape} onnx_shape={got.shape}")
    diff = np.abs(got - ref)
    max_abs, mean_abs = diff.max(), diff.mean()
    noise = ((got - ref) ** 2).sum()
    signal = (ref**2).sum()
    sdr = 10 * np.log10(signal / noise) if noise > 0 else float("inf")
    print(f"max_abs_diff={max_abs:.3e}")
    print(f"mean_abs_diff={mean_abs:.3e}")
    print(f"ref_abs_max={np.abs(ref).max():.3e}")
    print(f"SDR_onnx_vs_torch={sdr:.1f} dB")
    return sdr


def main():
    args = parse_args()

    # Deferred so `--help` works outside the venv (these pull in torch / onnxruntime).
    import onnxruntime as ort
    import torch

    from karaoke_graph import DEFAULT_CHUNK, load_karaoke_model

    sess = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
    print("=== CONTRACT ===")
    for i in sess.get_inputs():
        print(f"input  name={i.name} shape={i.shape} type={i.type} rank={len(i.shape)}")
    for o in sess.get_outputs():
        print(f"output name={o.name} shape={o.shape} type={o.type} rank={len(o.shape)}")

    inp = sess.get_inputs()[0]
    is_waveform = len(inp.shape) == 3 and inp.shape[1] == 2
    print(f"contract_is_waveform={is_waveform}")
    if not is_waveform:
        print("CONTRACT GATE FAILED - not waveform in")
        sys.exit(2)

    # The chunk is baked into the graph, so read it back rather than assuming the default.
    chunk = inp.shape[2] if isinstance(inp.shape[2], int) else DEFAULT_CHUNK
    print(f"chunk={chunk}")

    model = load_karaoke_model(args.checkpoint, args.config, args.model_code)

    # Same input the export used.
    torch.manual_seed(0)
    cases = [("synthetic_noise", torch.randn(1, 2, chunk) * 0.05)]
    if args.audio is not None:
        cases.append(("real_audio", real_audio_chunk(args.audio, chunk)))

    sdrs = [parity(sess, inp.name, model, x, label) for label, x in cases]
    print("\nPARITY_PASS" if min(sdrs) > SDR_GATE_DB else "\nPARITY_FAIL")
    if min(sdrs) <= SDR_GATE_DB:
        sys.exit(2)


if __name__ == "__main__":
    main()
