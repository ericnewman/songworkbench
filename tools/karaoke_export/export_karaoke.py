#!/usr/bin/env python3
"""Export the karaoke BS-RoFormer to a WAVEFORM-in / WAVEFORM-out ONNX graph.

The graph itself lives in karaoke_graph.py; this is the CLI around it. It gates on wrapper-vs-
torch parity before writing anything, so an unfaithful graph never reaches disk.

Run with `python3 -u`: the tracer can be SIGKILLed under memory pressure (exit 137) and Python's
buffered stdout dies with it, which makes an OOM look like a silent, message-free failure.
"""

import argparse
import sys
from pathlib import Path

DEFAULT_CHUNK = 262144


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("checkpoint", type=Path, help="karaoke BS-RoFormer .ckpt")
    parser.add_argument("config", type=Path, help="matching model config .yaml")
    parser.add_argument(
        "model_code",
        type=Path,
        help="directory holding the vendored ZFTurbo models/bs_roformer/ package",
    )
    parser.add_argument("output", type=Path, help="destination .onnx path")
    parser.add_argument(
        "--chunk",
        type=int,
        default=DEFAULT_CHUNK,
        help=f"samples per chunk, baked into the graph (default: {DEFAULT_CHUNK})",
    )
    return parser.parse_args(argv)


def main():
    args = parse_args()

    # Deferred so `--help` works outside the venv (karaoke_graph imports torch).
    import torch

    from karaoke_graph import WaveformKaraoke, load_karaoke_model

    model = load_karaoke_model(args.checkpoint, args.config, args.model_code)

    wrapper = WaveformKaraoke(model, args.chunk).eval()
    torch.manual_seed(0)
    x = torch.randn(1, 2, args.chunk) * 0.05

    with torch.no_grad():
        mine = wrapper(x)
        ref = model(x)
    if ref.ndim == 4:
        ref = ref[:, 0]
    err = (mine - ref).abs().max().item()
    denom = ref.abs().max().item() + 1e-12
    print(f"PARITY wrapper_vs_torch max_abs={err:.3e} rel={err / denom:.3e}")
    print(f"shapes mine={tuple(mine.shape)} ref={tuple(ref.shape)}")
    if err / denom > 1e-3:
        print("WRAPPER PARITY FAILED - refusing to export an unfaithful graph")
        sys.exit(2)

    torch.onnx.export(
        wrapper,
        (x,),
        str(args.output),
        input_names=["input"],
        output_names=["output"],
        opset_version=18,
        dynamo=False,
    )
    print("EXPORTED")


if __name__ == "__main__":
    main()
