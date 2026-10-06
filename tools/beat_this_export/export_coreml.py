"""Convert beat_this (CPJKU, MIT) to the bundled Core ML model `BeatThis.mlpackage`.

The app tracks beats and downbeats with this model (Eric, 2026-10-06: the built-in tracker
picked 4/3 or 2x the real tempo on 8 of 14 album tracks; beat_this matched his counted tempos).
Python runs only here, at conversion time; the app runs the package through Core ML.

Input:  log-mel spectrogram chunk, shape (1, 1500, 128) — 30 s at 50 frames per second,
        computed exactly like `beat_this.preprocessing.LogMelSpect` (Swift: `BeatThisMel`).
Output: `beat` and `downbeat` probabilities, shape (1, 1500) each (sigmoid folded in).

Run with an environment that has torch, torchaudio, soxr and coremltools (with its native
libraries, i.e. not Python 3.14), plus beat_this, rotary_embedding_torch and einops importable:

    TORCH_HOME=/Volumes/SSD/beat-this-ref/torch \
      PYTHONPATH=/Volumes/SSD/beat-this-ref/.venv/lib/python3.14/site-packages \
      tools/lyrics_align_spike/.venv/bin/python tools/beat_this_export/export_coreml.py \
      BundledModels/BeatThis.mlpackage path/to/song.wav
"""

import sys

import coremltools as ct
import numpy as np
import torch
from beat_this.inference import load_model
from beat_this.preprocessing import LogMelSpect, load_audio

CHUNK = 1500
BANDS = 128


def _patch_coremltools_scalar_cast():
    """coremltools 9.0 folds a constant one-element tensor with `int(array)`, which NumPy 2
    rejects ("only 0-dimensional arrays can be converted"). Same function, `.item()` first."""
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops

    def _cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
            raise ValueError("input to cast must be either a scalar or a length 1 tensor")
        if x.can_be_folded_to_const():
            value = np.asarray(x.val).reshape(-1)[0].item()
            res = mb.const(val=dtype(value), name=node.name)
        elif len(x.shape) > 0:
            res = mb.cast(
                x=mb.squeeze(x=x, name=node.name + "_item"), dtype=dtype_name, name=node.name
            )
        else:
            res = mb.cast(x=x, dtype=dtype_name, name=node.name)
        context.add(res, node.name)

    ops._cast = _cast


def _constant_rotary(self, t, seq_dim=None, offset=0, scale=None):
    """`RotaryEmbedding.rotate_queries_or_keys` for a fixed input size: the sequence length is a
    Python int, so the rotation tables trace as constants. Core ML cannot convert the library's
    cache-length arithmetic. Same math as `apply_rotary_emb` with start_index 0 and scale 1."""
    seq_dim = self.default_seq_dim if seq_dim is None else seq_dim
    n = int(t.shape[seq_dim])
    # Built in NumPy so it enters the graph as a constant, not as traced einsum/repeat ops.
    # Same table as RotaryEmbedding.forward: outer(positions, freqs), each column repeated twice.
    table = np.repeat(np.outer(np.arange(n), self.freqs.detach().numpy()), 2, axis=-1)
    freqs = torch.from_numpy(table.astype(np.float32))
    if seq_dim == -3:
        freqs = freqs[:, None, :]
    width = freqs.shape[-1]
    middle, right = t[..., :width], t[..., width:]
    pairs = middle.unflatten(-1, (width // 2, 2))
    rotated = torch.stack((-pairs[..., 1], pairs[..., 0]), dim=-1).flatten(-2)
    return torch.cat((middle * freqs.cos() + rotated * freqs.sin(), right), dim=-1)


class Probabilities(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, spect):
        out = self.model(spect)
        return torch.sigmoid(out["beat"]), torch.sigmoid(out["downbeat"])


def main(output_path, check_audio):
    # The reference output comes from the unmodified model, before the export patch below.
    signal, rate = load_audio(check_audio)
    if signal.ndim == 2:
        signal = signal.mean(1)
    if rate != 22050:
        import soxr

        signal = soxr.resample(signal, in_rate=rate, out_rate=22050)
    spect = LogMelSpect()(torch.tensor(signal, dtype=torch.float32))
    chunk = spect[3000 : 3000 + CHUNK].unsqueeze(0)
    with torch.no_grad():
        ref_beat, ref_down = Probabilities(load_model("final0", "cpu")).eval()(chunk)

    from rotary_embedding_torch import RotaryEmbedding

    RotaryEmbedding.rotate_queries_or_keys = _constant_rotary
    model = Probabilities(load_model("final0", "cpu")).eval()
    example = torch.zeros(1, CHUNK, BANDS)
    with torch.no_grad():
        # The rotary embedding caches its tables on first use, so two traces differ textually;
        # the comparison against PyTorch below is the real check. (torch.export is cleaner but
        # emits `alias` nodes coremltools 9.0 cannot read.)
        traced = torch.jit.trace(model, example, check_trace=False)
    _patch_coremltools_scalar_cast()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spect", shape=(1, CHUNK, BANDS), dtype=np.float32)],
        outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = (
        "beat_this final0 (CPJKU, MIT): beat and downbeat probabilities for 30 s of log-mel."
    )
    mlmodel.save(output_path)

    # Verify against PyTorch on a real chunk: the probabilities and the frames they peak on.
    got = ct.models.MLModel(output_path).predict({"spect": chunk.numpy()})
    for name, ref in (("beat", ref_beat), ("downbeat", ref_down)):
        ref = ref.numpy().ravel()
        new = np.asarray(got[name]).ravel()

        def peaks(x):
            inner = x[1:-1]
            return set(np.flatnonzero((inner > 0.5) & (inner >= x[:-2]) & (inner >= x[2:])))

        shared = len(peaks(ref) & peaks(new))
        print(
            f"{name}: max |diff| {np.abs(ref - new).max():.4f}, "
            f"peaks {len(peaks(ref))} vs {len(peaks(new))}, shared {shared}"
        )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
