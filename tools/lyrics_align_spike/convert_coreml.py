#!/usr/bin/env python3
"""Probe: does the LyricsAlignment-MTL acoustic model convert to Core ML, and does
the converted model match PyTorch numerically?

The spike flagged the three bidirectional LSTMs as the one real conversion risk and
noted nobody has published a conversion. This answers both concretely.

Two things this does beyond a naive trace:

  1. The stock forward calls `x.view(sizes[0], sizes[1]*sizes[2], sizes[3])` with
     sizes read off a traced tensor; coremltools cannot scalarize those and fails
     with "only 0-dimensional arrays can be converted to Python scalars". We convert
     at a FIXED frame count, so the shapes are static and can be written as literals.

  2. It folds in what wrapper.py does after the model — sum over the pitch axis for
     MTL, then log_softmax — so the Core ML model emits the phoneme posteriorgram
     [T, 41] that forced alignment consumes, instead of raw logits the Swift side
     would have to post-process.

Usage: convert_coreml.py [frames]   (frames = mel frames; must be a multiple of 3)
"""
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "LyricsAlignment-MTL")
sys.path.insert(0, REPO)

N_PHONE = 41
N_PITCH = 47
N_FEATS = 32
MEL_BINS = 128


class StaticShapeAcoustic(nn.Module):
    """AcousticModel with literal shapes and the posteriorgram maths folded in."""

    def __init__(self, base, frames):
        super().__init__()
        self.cnn_layers = base.cnn_layers
        self.rescnn_layers = base.rescnn_layers
        self.maxpooling = base.maxpooling
        self.fully_connected = base.fully_connected
        self.bilstm = base.bilstm
        self.classifier = base.classifier
        # maxpool is (2, 3): mel 128 -> 64, time F -> F // 3
        self.t_out = frames // 3
        self.feat = N_FEATS * (MEL_BINS // 2)

    def forward(self, x):
        x = self.cnn_layers(x)
        x = self.rescnn_layers(x)
        x = self.maxpooling(x)
        x = x.view(1, self.feat, self.t_out)  # literal, not traced sizes
        x = x.transpose(1, 2)
        x = self.fully_connected(x)
        x = self.bilstm(x)
        x = self.classifier(x)
        x = x.view(1, self.t_out, N_PHONE, N_PITCH)
        x = torch.sum(x, dim=3)          # MTL: marginalise the pitch head
        return F.log_softmax(x, dim=2)   # [1, T, 41] log-probs


def main():
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 2049
    frames -= frames % 3
    os.chdir(REPO)

    import coremltools as ct
    import utils
    from model import AcousticModel

    base = AcousticModel(1, 256, (N_PHONE, N_PITCH), N_FEATS, 1, 0.1)
    utils.load_model(base, "./checkpoints/checkpoint_MTL", cuda=False)
    base.eval()

    model = StaticShapeAcoustic(base, frames).eval()
    example = torch.rand(1, 1, MEL_BINS, frames)
    with torch.no_grad():
        ref = model(example)
    print(f"input  : {tuple(example.shape)}")
    print(f"output : {tuple(ref.shape)}  (torch log-probs)")

    print("tracing...")
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    print("converting to Core ML (mlprogram, fp32)...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mel", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="logprobs", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )

    out_path = os.path.join(HERE, f"LyricsAlignmentMTL_{frames}.mlpackage")
    mlmodel.save(out_path)
    size = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fs in os.walk(out_path)
        for f in fs
    )
    print(f"saved  : {os.path.basename(out_path)}  ({size/1e6:.1f} MB)")

    print("verifying against PyTorch...")
    pred = mlmodel.predict({"mel": example.numpy().astype(np.float32)})
    got = np.asarray(pred[list(pred.keys())[0]]).reshape(ref.shape)
    exp = ref.numpy()
    diff = np.abs(got - exp)
    a = exp.reshape(-1, N_PHONE).argmax(-1)
    b = got.reshape(-1, N_PHONE).argmax(-1)
    print(f"  max abs diff        : {diff.max():.3e}")
    print(f"  mean abs diff       : {diff.mean():.3e}")
    print(f"  argmax agreement    : {100*np.mean(a==b):.2f}%   <- what alignment depends on")
    print("  VERDICT             :", "MATCHES" if diff.max() < 1e-2 else "DIVERGES")


if __name__ == "__main__":
    main()
