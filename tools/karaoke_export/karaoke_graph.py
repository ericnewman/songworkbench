#!/usr/bin/env python3
"""The all-real waveform graph for the karaoke BS-RoFormer, plus checkpoint loading.

Imported by both export_karaoke.py and verify_export.py, and deliberately NOT imported at their
module scope: it pulls in torch, so importing it eagerly would make `--help` require the venv.

The point: the STFT and the INVERSE STFT live INSIDE the exported graph, so the Swift side keeps
its existing waveform contract (`StemChunkPredicting`) and needs no hand-rolled DSP. Same trick as
tools/demucs_export/realstft.py -- torch's exporters reject complex STFT/iSTFT, so both transforms
are rebuilt from all-real ops (conv1d framing, matmul IDFT, fold overlap-add).

Differences from the demucs export: this model's STFT is normalized=False (no 1/sqrt(N) scaling),
and the architecture comes from ZFTurbo's Music-Source-Separation-Training fork, not the pip
package -- the pip package has since moved to hyper-connections and its weights do not match.
"""

import inspect
import math
import sys
from pathlib import Path

import torch
import torch.nn.functional as F
import yaml
from einops import pack, rearrange, unpack

N_FFT = 2048
HOP = 512

# The training chunk (640000 = 14.5 s -> 1251 frames) OOMs the ONNX tracer: the time-axis
# attention is O(T^2) and the exporter holds every intermediate. The chunk is baked into the
# graph, so this also sets the app's segment length -- shorter means less inference memory too,
# which matters because base separation already peaks at 3.91 GB. Precedent: the demucs export
# cut 7.8 s -> 2.5 s for the same reason.
DEFAULT_CHUNK = 262144

FREQS = N_FFT // 2 + 1


def kernels(n_fft, dtype=torch.float32):
    """Build the DFT kernels in float64, then cast.

    These are graph CONSTANTS, so the float64 work is free at runtime. Building them in float32
    is not: the angle 2*pi*k*n/N has k*n up to ~2.1e6 here, and computing that in float32 loses
    enough precision to drop the forward STFT from ~122 dB to ~86 dB against torch.stft -- an
    error the 12-layer transformer then amplifies to ~48 dB at the output.
    """
    n = torch.arange(n_fft, dtype=torch.float64)
    k = torch.arange(n_fft // 2 + 1, dtype=torch.float64).unsqueeze(1)
    ang = 2 * math.pi * k * n / n_fft
    cos_m, sin_m = torch.cos(ang), torch.sin(ang)
    w = torch.hann_window(n_fft, periodic=True, dtype=torch.float64)
    return {
        "Wc": (w * cos_m).unsqueeze(1).contiguous().to(dtype),
        "Ws": (w * sin_m).unsqueeze(1).contiguous().to(dtype),
        "cosMt": cos_m.t().contiguous().to(dtype),
        "sinMt": sin_m.t().contiguous().to(dtype),
        "w": w.to(dtype),
    }


def stft_real(x, K, n_fft=N_FFT, hop=HOP):
    """[B, L] -> [B, F, T, 2]; matches torch.stft(center=True, normalized=False)."""
    xp = F.pad(x.unsqueeze(1), (n_fft // 2, n_fft // 2), mode="reflect")
    re = F.conv1d(xp, K["Wc"], stride=hop)
    im = -F.conv1d(xp, K["Ws"], stride=hop)
    return torch.stack([re, im], dim=-1)


def frame_geometry(chunk, n_fft=N_FFT, hop=HOP):
    """Frame count and padded length for a chunk, as Python ints.

    The chunk length is baked into the exported graph, so frame/bin counts are compile-time
    constants. They MUST be Python ints, not traced tensor shapes: opset-18's `col2im` symbolic
    calls `_get_tensor_sizes(output_size)[0]` and returns None for a dynamic size, which surfaces
    as "TypeError: 'NoneType' object is not subscriptable (Occurred when translating col2im)".
    """
    frames = chunk // hop + 1
    padded = (frames - 1) * hop + n_fft
    return frames, padded


def istft_real(zr, K, length, frames, padded, n_fft=N_FFT, hop=HOP):
    """[B, F, T, 2] -> [B, length]; weighted overlap-add, matching torch.istft."""
    freqs = FREQS
    c = torch.ones(freqs, dtype=zr.dtype)
    c[1:-1] = 2.0
    rec = zr[..., 0] * c.unsqueeze(-1)
    imc = zr[..., 1] * c.unsqueeze(-1)
    time = (torch.matmul(K["cosMt"], rec) - torch.matmul(K["sinMt"], imc)) / n_fft
    time = time * K["w"].unsqueeze(0).unsqueeze(-1)
    sig = F.fold(time, (1, padded), kernel_size=(1, n_fft), stride=(1, hop))[:, 0, 0]
    wsq = (K["w"] * K["w"]).unsqueeze(0).unsqueeze(-1).expand(1, n_fft, frames)
    denom = F.fold(wsq, (1, padded), kernel_size=(1, n_fft), stride=(1, hop))[:, 0, 0]
    sig = sig / (denom + 1e-12)
    pad = n_fft // 2
    return sig[..., pad : pad + length]


class WaveformKaraoke(torch.nn.Module):
    """Mirrors BSRoformer.forward's inference path with only real-valued ops."""

    def __init__(self, model, chunk=DEFAULT_CHUNK):
        super().__init__()
        self.m = model
        self.frames, self.padded = frame_geometry(chunk)
        for name, tensor in kernels(N_FFT).items():
            self.register_buffer(f"k_{name}", tensor)

    @property
    def K(self):
        return {n: getattr(self, f"k_{n}") for n in ("Wc", "Ws", "cosMt", "sinMt", "w")}

    def forward(self, raw_audio):
        m = self.m
        b, ch, length = raw_audio.shape
        spec = stft_real(raw_audio.reshape(b * ch, length), self.K)
        spec = spec.reshape(b, ch, *spec.shape[1:])
        spec = rearrange(spec, "b s f t c -> b (f s) t c")

        x = rearrange(spec, "b f t c -> b t (f c)")
        x = m.band_split(x)

        store = [None] * len(m.layers)
        for i, block in enumerate(m.layers):
            if len(block) == 3:
                linear_tf, time_tf, freq_tf = block
                x, ft_ps = pack([x], "b * d")
                x = linear_tf(x)
                (x,) = unpack(x, ft_ps, "b * d")
            else:
                time_tf, freq_tf = block
            if m.skip_connection:
                for j in range(i):
                    x = x + store[j]
            x = rearrange(x, "b t f d -> b f t d")
            x, ps = pack([x], "* t d")
            x = time_tf(x)
            (x,) = unpack(x, ps, "* t d")
            x = rearrange(x, "b f t d -> b t f d")
            x, ps = pack([x], "* f d")
            x = freq_tf(x)
            (x,) = unpack(x, ps, "* f d")
            if m.skip_connection:
                store[i] = x
        x = m.final_norm(x)

        mask = torch.stack([fn(x) for fn in m.mask_estimators], dim=1)
        mask = rearrange(mask, "b n t (f c) -> b n f t c", c=2)
        spec = rearrange(spec, "b f t c -> b 1 f t c")

        # Complex multiply written out in real arithmetic: no complex tensor ever enters the
        # graph, because torch's ONNX exporters choke on complex dtypes.
        sr, si = spec[..., 0], spec[..., 1]
        mr, mi = mask[..., 0], mask[..., 1]
        out = torch.stack([sr * mr - si * mi, sr * mi + si * mr], dim=-1)

        out = rearrange(out, "b n (f s) t c -> (b n s) f t c", s=m.audio_channels)
        if m.zero_dc:
            out = torch.cat([torch.zeros_like(out[:, :1]), out[:, 1:]], dim=1)
        audio = istft_real(out, self.K, length, self.frames, self.padded)
        return audio.reshape(b, m.audio_channels, length)


def import_bs_roformer(model_code: Path):
    """Import BSRoformer from a vendored ZFTurbo `models/bs_roformer/` tree.

    NOT the `bs-roformer` pip package: it has since moved to hyper-connections, and against this
    checkpoint it reports 668 missing / 240 unexpected state-dict keys.
    """
    path = str(Path(model_code).resolve())
    if path not in sys.path:
        sys.path.insert(0, path)
    from models.bs_roformer.bs_roformer import BSRoformer

    return BSRoformer


def load_karaoke_model(checkpoint: Path, config: Path, model_code: Path, strict_gate=True):
    """Build BSRoformer from the yaml config and load the checkpoint weights."""
    BSRoformer = import_bs_roformer(model_code)

    cfg = yaml.unsafe_load(open(config))
    mc = dict(cfg["model"])
    mc["flash_attn"] = False
    mc["use_torch_checkpoint"] = False  # gradient checkpointing is training-only
    accepted = set(inspect.signature(BSRoformer.__init__).parameters)
    dropped = {k: v for k, v in mc.items() if k not in accepted}
    if dropped:
        print("dropped_unsupported_kwargs:", dropped)
    model = BSRoformer(**{k: v for k, v in mc.items() if k in accepted})

    raw = torch.load(checkpoint, map_location="cpu", weights_only=False)
    state = raw.get("state_dict", raw) if isinstance(raw, dict) else raw
    state = {k.replace("module.", ""): v for k, v in state.items()}
    missing, unexpected = model.load_state_dict(state, strict=False)
    print(f"load_state_dict missing={len(missing)} unexpected={len(unexpected)}")
    if missing:
        print("  first missing:", missing[:6])
    if unexpected:
        print("  first unexpected:", unexpected[:6])
    if strict_gate and (missing or unexpected):
        print("ARCHITECTURE MISMATCH - refusing to continue")
        sys.exit(3)
    model.eval()
    return model
