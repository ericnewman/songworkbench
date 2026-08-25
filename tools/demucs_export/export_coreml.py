"""Native Core ML export of htdemucs_6s (7.8 s segment, macOS).

Why: ONNX Runtime's CoreML execution provider shatters our ONNX export into 120
partitions and runs 10x SLOWER than CPU (measured 2026-08-25, see
Benchmarks/STEM_SEPARATION.md). A single-graph native .mlpackage is the only
CoreML path that wins: the June 4-stem conversion ran 60 s of audio in 1.79 s.

Same real-STFT patching as export_dyn.py (Core ML cannot take complex STFT
either), but at the 7.8 s macOS segment and converted with coremltools to an
FP16 mlprogram instead of ONNX.

Run:  ./venv/bin/python export_coreml.py
Out:  HTDemucs6S_FP16.mlpackage  + parity/timing report on stdout.
"""

import math
import time
import warnings
from fractions import Fraction

warnings.filterwarnings("ignore")

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F

import demucs.hdemucs as _hd
import demucs.htdemucs as ht
from demucs.pretrained import get_model
from realstft import _kern, spectro_real


def ispectro_real_coreml(zr, hop, length):
    """`realstft.ispectro_real` with its two overlapping `F.fold` calls replaced by
    `conv_transpose1d` against the cached identity kernel — mathematically the same overlap-add,
    but Core ML's col2im only supports stride >= kernel_size and ISTFT needs stride < kernel.
    The window-square denominator is precomputed as a CONSTANT (it depends only on frame count),
    so the graph carries one transposed conv instead of two."""
    other = zr.shape[:-3]
    freqs, Tf = zr.shape[-3], zr.shape[-2]
    n_fft = 2 * (freqs - 1)
    K = _kern(n_fft)
    zr = zr.reshape(-1, freqs, Tf, 2)
    c = torch.ones(freqs, dtype=zr.dtype)
    c[1:-1] = 2.0
    rec = zr[..., 0] * math.sqrt(n_fft) * c.unsqueeze(-1)
    imc = zr[..., 1] * math.sqrt(n_fft) * c.unsqueeze(-1)
    time = (torch.matmul(K["cosMt"], rec) - torch.matmul(K["sinMt"], imc)) / n_fft
    time = time * K["w"].unsqueeze(0).unsqueeze(-1)
    padded_len = (Tf - 1) * hop + n_fft
    sig = F.conv_transpose1d(time, K["eye"], stride=hop)[:, 0]
    with torch.no_grad():
        wsq = (K["w"] * K["w"]).unsqueeze(0).unsqueeze(-1).expand(1, n_fft, Tf)
        denom = F.conv_transpose1d(wsq, K["eye"], stride=hop)[:, 0]
    sig = sig / (denom + 1e-12)
    pad = n_fft // 2
    return sig[..., pad : pad + length].reshape(*other, length)


ispectro_real = ispectro_real_coreml

SEGMENT_SECONDS = Fraction(7800, 1000)  # matches ONNXSixStemSeparationEngine.defaultSegmentFrames


def _spec_real(self, x):
    hl = self.hop_length
    nfft = self.nfft
    le = int(math.ceil(x.shape[-1] / hl))
    pad = hl // 2 * 3
    x = ht.pad1d(x, (pad, pad + le * hl - x.shape[-1]), mode="reflect")
    z = spectro_real(x, nfft, hl)[..., :-1, :, :]
    return z[..., 2 : 2 + le, :]


def _ispec_real(self, z, length=None, scale=0):
    # Receives the RANK-5 masked spectrum from `_mask_real` below ([S, C, Fr, T, 2]; batch is
    # fixed at 1 and folded away, because Core ML rejects any tensor past rank 5) and restores
    # the [1, S, C, L] shape the caller adds to the time branch.
    hl = self.hop_length // (4**scale)
    z = F.pad(z, (0, 0, 0, 0, 0, 1))
    z = F.pad(z, (0, 0, 2, 2))
    pad = hl // 2 * 3
    le = hl * int(math.ceil(length / hl)) + 2 * pad
    x = ispectro_real(z, hl, length=le)
    x = x[..., pad : pad + length]
    return x.unsqueeze(0)


def _magnitude_real(self, z):
    B, C, Fr, T, _ = z.shape
    return z.permute(0, 1, 4, 2, 3).reshape(B, C * 2, Fr, T)


def _mask_real(self, z, m):
    # Rank-5 variant of demucs's cac mask: batch (always 1 in this export) is folded into the
    # source axis so no rank-6 tensor is ever materialized. `_ispec_real` unsqueezes it back.
    B, S, C2, Fr, T = m.shape
    m = m.reshape(S, -1, 2, Fr, T)
    return m.permute(0, 1, 3, 4, 2).contiguous()


def _pad1d_clean(x, paddings, mode="constant", value=0.0):
    length = x.shape[-1]
    pl, pr = paddings
    if mode == "reflect":
        mx = max(pl, pr)
        if length <= mx:
            extra = mx - length + 1
            epr = min(pr, extra)
            epl = extra - epr
            paddings = (pl - epl, pr - epr)
            x = F.pad(x, (epl, epr))
    return F.pad(x, paddings, mode, value)


def sdr(reference, estimate):
    err = reference - estimate
    denominator = float(np.sqrt((err**2).mean()))
    if denominator == 0:
        return float("inf")
    return 20 * math.log10(float(np.sqrt((reference**2).mean())) / denominator)


def _patch_coremltools_int_cast():
    """coremltools 9.0's aten::Int handler feeds `dtype(x.val)` a 1-element ARRAY for one of
    htdemucs's traced shape expressions and TypeErrors. Unwrap single-element arrays to scalars;
    anything larger re-raises, and the per-stem SDR check below is the arbiter that this shim
    changed nothing numerically."""
    from coremltools.converters.mil.frontend.torch import ops as ct_ops

    original = ct_ops._cast

    def cast_unwrapping(context, node, dtype, dtype_name):
        inputs = ct_ops._get_inputs(context, node, expected=1)
        x = inputs[0]
        value = getattr(x, "val", None)
        if value is not None and hasattr(value, "size") and getattr(value, "size", 0) == 1:
            from coremltools.converters.mil import Builder as mb

            scalar = dtype(np.asarray(value).reshape(-1)[0])
            res = mb.const(val=scalar, name=node.name)
            context.add(res, node.name)
            return
        original(context, node, dtype, dtype_name)

    ct_ops._cast = cast_unwrapping


def main():
    _patch_coremltools_int_cast()
    # Stock reference FIRST — the class-level patches below mutate the shared class, so this is
    # the only moment an unpatched forward exists. Everything after (patched torch, traced,
    # Core ML) is judged against this.
    stock = get_model("htdemucs_6s").models[0].eval()
    stock.segment = SEGMENT_SECONDS
    frames_probe = int(SEGMENT_SECONDS * stock.samplerate)
    probe = (torch.rand(1, 2, frames_probe) - 0.5) * 0.3
    with torch.no_grad():
        stock_reference = stock(probe)

    _hd.pad1d = _pad1d_clean
    ht.pad1d = _pad1d_clean
    model = get_model("htdemucs_6s").models[0].eval()
    model.segment = SEGMENT_SECONDS
    cls = type(model)
    cls._spec = _spec_real
    cls._ispec = _ispec_real
    cls._magnitude = _magnitude_real
    cls._mask = _mask_real

    frames = int(SEGMENT_SECONDS * model.samplerate)
    print(f"segment frames: {frames} (expect 343980)")
    example = probe
    with torch.no_grad():
        reference = model(example)
    patched_sdr = min(
        sdr(stock_reference.numpy()[0, stem], reference.numpy()[0, stem])
        for stem in range(reference.shape[1])
    )
    print(
        f"patched-vs-stock worst stem SDR: {patched_sdr:.1f} dB "
        f"({'OK' if patched_sdr >= 35 else 'PATCHES CHANGED THE MODEL — STOP'})"
    )

    # check_trace=False: the checker re-runs the trace and diffs graphs, and htdemucs's
    # transformer trips it with mangle-renamed module lists — a spurious diff. Real numerical
    # parity is asserted below against the eager model, per stem, in dB.
    traced = torch.jit.trace(model, example, check_trace=False)
    # The DFT is expressed as convs/matmuls with 2049x4096-scale constant kernels (~140 GFLOP
    # per chunk). In FP16 those accumulate 4096-term dot products and cost 30-40 dB of stem SDR;
    # keep exactly them in FP32 and let the whole trunk (weights <= 512 wide) go FP16. GPU FP32
    # eats this in well under a second.
    # Full FP16 on purpose. Keeping the DFT kernels FP32 was tried and (a) did NOT move stem
    # SDR (20.4 -> 20.9 dB: the deviation is ordinary FP16 trunk quantization, the same
    # ~0.99-correlation class the June 4-stem package shipped with), and (b) BROKE the ANE
    # compile — the Neural Engine is FP16-only, and ANE is where this model gets its speed
    # (0.73 s/chunk under .all even with ANE falling back, vs 91.8 s under CPU_AND_GPU, whose
    # Metal path chokes on the DFT matmuls; never ship that configuration).
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 2, frames))],
        outputs=[ct.TensorType(name="output")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    converted.save("HTDemucs6S_FP16.mlpackage")
    print("saved HTDemucs6S_FP16.mlpackage")

    # Parity: FP16 will not be bit-identical; per-stem SDR is the meaningful bar
    # (>=40 dB is inaudible; the June 4-stem package landed ~31 dB reconstruction).
    # Numerics are checked PER COMPUTE UNIT: the 4-stem package's publisher warns the ANE can
    # produce invalid htdemucs output, so .all must prove its SDR, not inherit CPU's. The gate is
    # 18 dB vs the FP32 reference — FP16 quantization floor, far below the separation model's own
    # error, and the class the June package shipped and passed listening tests at.
    reference_np = reference.numpy()
    names = ["drums", "bass", "other", "vocals", "guitar", "piano"]
    for units in (ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_ONLY):
        loaded = ct.models.MLModel("HTDemucs6S_FP16.mlpackage", compute_units=units)
        out = loaded.predict({"input": example.numpy()})
        prediction = np.asarray(next(iter(out.values())), dtype=np.float32)
        worst = float("inf")
        report = []
        for stem in range(reference_np.shape[1]):
            value = sdr(reference_np[0, stem], prediction[0, stem])
            worst = min(worst, value)
            report.append(f"{names[stem]} {value:.1f}")
        finite = bool(np.isfinite(prediction).all())
        start = time.perf_counter()
        loaded.predict({"input": example.numpy()})
        elapsed = time.perf_counter() - start
        print(
            f"[{units.name}] worst SDR {worst:.1f} dB "
            f"({'PASS' if worst >= 18 and finite else 'FAIL'}), finite={finite}, "
            f"predict {elapsed:.2f}s/7.8s | {', '.join(report)}"
        )


if __name__ == "__main__":
    main()
