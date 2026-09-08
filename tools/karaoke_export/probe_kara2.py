#!/usr/bin/env python3
"""Discriminator: run UVR_MDXNET_KARA_2 on a vocals stem and score lead vs backing.

KARA_2 is a karaoke MDX-Net (UVR hash 1d64a6d2…): primary_stem Instrumental, is_karaoke true,
n_fft 5120, dim_f 2048, dim_t 256, hop 1024, compensate 1.065.

Fed an already-separated vocals stem, the instrumental output should be backing vocals and
the residual (parent − primary) should be lead. A vocals-vs-instrumental isolator fails this
the way anvuew did: one child ≈ parent, the other a ghost.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort

N_FFT = 5120
HOP = 1024
DIM_F = 2048
DIM_T = 256  # 2 ** 8
COMPENSATE = 1.065
CHUNK = HOP * (DIM_T - 1)  # 261120


def read_float_wav(path: Path) -> tuple[np.ndarray, int]:
    data = path.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE"
    pos = 12
    fmt = nch = sr = None
    audio = None
    while pos + 8 <= len(data):
        chunk = data[pos : pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8 : pos + 8 + size]
        if chunk == b"fmt ":
            audio_format, nch, sr, *_ = struct.unpack_from("<HHIIHH", body, 0)
            fmt = audio_format
        elif chunk == b"data":
            audio = body
        pos += 8 + size
        if size % 2:
            pos += 1
    assert fmt == 3, f"expected IEEE float WAV, got format {fmt}"
    x = np.frombuffer(audio, dtype="<f4").reshape(-1, nch).T.astype(np.float32)
    return x, sr


def hann_periodic(n: int) -> np.ndarray:
    return (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n, dtype=np.float64) / n)).astype(
        np.float32
    )


def stft_pack(chunk: np.ndarray) -> np.ndarray:
    """chunk: [2, CHUNK] -> [1, 4, DIM_F, DIM_T] matching ConvTDFNet.stft."""
    window = hann_periodic(N_FFT)
    pad = N_FFT // 2
    n_bins = N_FFT // 2 + 1
    packed = np.zeros((1, 4, DIM_F, DIM_T), dtype=np.float32)
    for ch in range(2):
        x = np.pad(chunk[ch], (pad, pad))
        frames = np.lib.stride_tricks.sliding_window_view(x, N_FFT)[::HOP]
        frames = frames[:DIM_T] * window
        spec = np.fft.rfft(frames, n=N_FFT, axis=-1)  # [T, n_bins]
        spec = spec.T[:, :DIM_T]  # [n_bins, T]
        packed[0, ch * 2, :, :] = spec.real[:DIM_F]
        packed[0, ch * 2 + 1, :, :] = spec.imag[:DIM_F]
    _ = n_bins
    return packed


def istft_unpack(packed: np.ndarray) -> np.ndarray:
    """[1, 4, DIM_F, DIM_T] -> [2, CHUNK]."""
    window = hann_periodic(N_FFT)
    n_bins = N_FFT // 2 + 1
    pad = N_FFT // 2
    out = np.zeros((2, CHUNK), dtype=np.float32)
    window_sum = np.zeros(CHUNK + 2 * pad, dtype=np.float32)
    for ch in range(2):
        spec = np.zeros((n_bins, DIM_T), dtype=np.complex64)
        spec[:DIM_F] = packed[0, ch * 2] + 1j * packed[0, ch * 2 + 1]
        acc = np.zeros(CHUNK + 2 * pad, dtype=np.float32)
        for t in range(DIM_T):
            frame = np.fft.irfft(spec[:, t], n=N_FFT).real.astype(np.float32) * window
            start = t * HOP
            acc[start : start + N_FFT] += frame
            if ch == 0:
                window_sum[start : start + N_FFT] += window * window
        # torch.istft NOLA: divide by the squared-window envelope, then drop center pad.
        denom = np.maximum(window_sum[pad : pad + CHUNK], 1e-8)
        out[ch] = acc[pad : pad + CHUNK] / denom
    return out


def energy(x: np.ndarray) -> float:
    return float(np.mean(x * x))


def corr(a: np.ndarray, b: np.ndarray) -> float:
    a = a.reshape(-1).astype(np.float64)
    b = b.reshape(-1).astype(np.float64)
    a = a - a.mean()
    b = b - b.mean()
    den = np.linalg.norm(a) * np.linalg.norm(b)
    return 0.0 if den == 0 else float(np.dot(a, b) / den)


def db(v: float) -> float:
    return 20 * math.log10(v) if v > 1e-12 else -999.0


def separate(session: ort.InferenceSession, mix: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Primary = instrumental/backing; lead = mix − primary * compensate."""
    samples = mix.shape[-1]
    lead = np.zeros_like(mix)
    backing = np.zeros_like(mix)
    overlap = N_FFT // 2
    gen = CHUNK - 2 * overlap
    pos = 0
    while pos < samples:
        take = min(gen, samples - pos)
        chunk = np.zeros((2, CHUNK), dtype=np.float32)
        # Match seanghay: leading/trailing n_fft/2 pad lives inside the chunk layout via STFT center.
        chunk[:, overlap : overlap + take] = mix[:, pos : pos + take]
        spek = stft_pack(chunk)
        pred = session.run(None, {"input": spek})[0]
        waves = istft_unpack(pred)
        primary = waves[:, overlap : overlap + take] * COMPENSATE
        backing[:, pos : pos + take] = primary
        lead[:, pos : pos + take] = mix[:, pos : pos + take] - primary
        pos += take
    return lead, backing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vocals", type=Path)
    parser.add_argument(
        "--model",
        type=Path,
        default=Path(__file__).resolve().parent / "models" / "UVR_MDXNET_KARA_2.onnx",
    )
    parser.add_argument("--start", type=float, default=30.0)
    parser.add_argument("--duration", type=float, default=20.0)
    args = parser.parse_args()

    mix, sr = read_float_wav(args.vocals)
    start = int(args.start * sr)
    stop = int((args.start + args.duration) * sr)
    mix = mix[:, start:stop]
    print(f"window {args.start:.1f}s+{args.duration:.1f}s samples={mix.shape[1]} sr={sr}")

    session = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    lead, backing = separate(session, mix)
    e_p = energy(mix)
    e_l = energy(lead)
    e_b = energy(backing)
    print(f"lead_rms_db={db(math.sqrt(e_l)):.2f} backing_rms_db={db(math.sqrt(e_b)):.2f}")
    print(f"lead/parent={e_l / e_p:.3f} backing/parent={e_b / e_p:.3f}")
    print(f"corr lead-parent={corr(lead, mix):.3f} backing-parent={corr(backing, mix):.3f}")
    print(f"corr lead-backing={corr(lead, backing):.3f}")
    recon = lead + backing
    print(f"corr recon-parent={corr(recon, mix):.3f} recon_err_db={db(math.sqrt(energy(recon - mix))):.2f}")
    keep = (0.08 <= e_l / e_p <= 0.90) and (0.08 <= e_b / e_p <= 0.90)
    print(f"quality_gate_keep_children={keep}")
    return 0 if keep else 2


if __name__ == "__main__":
    sys.exit(main())
