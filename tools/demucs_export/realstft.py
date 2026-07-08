import math, torch
import torch.nn.functional as F

# Precompute STFT kernels ONCE as constants so the ONNX exporter sees static conv weights.
_K = {}
def _kern(n_fft):
    key = n_fft
    if key not in _K:
        dt = torch.float32
        n = torch.arange(n_fft, dtype=dt)
        k = torch.arange(n_fft//2+1, dtype=dt).unsqueeze(1)
        ang = 2*math.pi*k*n/n_fft
        cosM = torch.cos(ang); sinM = torch.sin(ang)          # [freqs,n_fft]
        w = torch.hann_window(n_fft, periodic=True, dtype=dt)
        _K[key] = {
            "Wc": (w*cosM).unsqueeze(1).contiguous(),          # [freqs,1,n_fft]
            "Ws": (w*sinM).unsqueeze(1).contiguous(),
            "cosMt": cosM.t().contiguous(),                    # [n_fft,freqs]
            "sinMt": sinM.t().contiguous(),
            "eye": torch.eye(n_fft, dtype=dt).unsqueeze(1).contiguous(),  # [n_fft,1,n_fft]
            "w": w,
        }
    return _K[key]
_kern(4096)  # warm the cache at import (constants, not traced)

def spectro_real(x, n_fft, hop):
    *other, L = x.shape
    x = x.reshape(-1, 1, L)
    K = _kern(n_fft)
    pad = n_fft//2
    xp = F.pad(x, (pad, pad), mode='reflect')
    re = F.conv1d(xp, K["Wc"], stride=hop) / math.sqrt(n_fft)   # [B,freqs,T]
    im = -F.conv1d(xp, K["Ws"], stride=hop) / math.sqrt(n_fft)
    z = torch.stack([re, im], dim=-1)
    freqs, Tf = z.shape[-3], z.shape[-2]
    return z.reshape(*other, freqs, Tf, 2)

def ispectro_real(zr, hop, length):
    *other, freqs, Tf, _ = zr.shape
    n_fft = 2*(freqs-1)
    K = _kern(n_fft)
    zr = zr.reshape(-1, freqs, Tf, 2)
    c = torch.ones(freqs, dtype=zr.dtype); c[1:-1] = 2.0
    rec = zr[...,0] * math.sqrt(n_fft) * c.unsqueeze(-1)
    imc = zr[...,1] * math.sqrt(n_fft) * c.unsqueeze(-1)
    time = (torch.matmul(K["cosMt"], rec) - torch.matmul(K["sinMt"], imc)) / n_fft  # [B,n_fft,T]
    time = time * K["w"].unsqueeze(0).unsqueeze(-1)
    padded_len = (Tf - 1)*hop + n_fft
    sig = F.fold(time, output_size=(1, padded_len), kernel_size=(1, n_fft), stride=(1, hop))[:,0,0]
    wsq = (K["w"]*K["w"]).unsqueeze(0).unsqueeze(-1).expand(1, n_fft, Tf)
    denom = F.fold(wsq, output_size=(1, padded_len), kernel_size=(1, n_fft), stride=(1, hop))[:,0,0]
    sig = sig / (denom + 1e-12)
    pad = n_fft//2
    return sig[..., pad:pad+length].reshape(*other, length)
