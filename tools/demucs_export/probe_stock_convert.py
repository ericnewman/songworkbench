"""Probe: can coremltools 9 convert STOCK htdemucs_6s (complex torch.stft/istft) directly?

The real-STFT patched export converts but runs 70 s/chunk with 20 dB stems — the
hand-rolled DFT convs are the suspect for both. coremltools grew native
torch.stft lowering after our ONNX tooling was written; if the stock graph
converts, none of the patches are needed and the STFT runs as proper FFT ops.
"""

import time
import warnings
from fractions import Fraction

warnings.filterwarnings("ignore")

import coremltools as ct
import numpy as np
import torch

from demucs.pretrained import get_model

# Same converter edge case the patched export hit: aten::Int over a 1-element array.
from coremltools.converters.mil.frontend.torch import ops as ct_ops

_original_cast = ct_ops._cast


def _cast_unwrapping(context, node, dtype, dtype_name):
    inputs = ct_ops._get_inputs(context, node, expected=1)
    value = getattr(inputs[0], "val", None)
    if value is not None and hasattr(value, "size") and getattr(value, "size", 0) == 1:
        from coremltools.converters.mil import Builder as mb

        res = mb.const(val=dtype(np.asarray(value).reshape(-1)[0]), name=node.name)
        context.add(res, node.name)
        return
    _original_cast(context, node, dtype, dtype_name)


ct_ops._cast = _cast_unwrapping

model = get_model("htdemucs_6s").models[0].eval()
model.segment = Fraction(7800, 1000)
frames = int(model.segment * model.samplerate)
example = (torch.rand(1, 2, frames) - 0.5) * 0.3
with torch.no_grad():
    reference = model(example)

traced = torch.jit.trace(model, example, check_trace=False)
converted = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 2, frames))],
    outputs=[ct.TensorType(name="output")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.CPU_AND_GPU,
)
converted.save("HTDemucs6S_stock_FP16.mlpackage")
print("saved HTDemucs6S_stock_FP16.mlpackage")

loaded = ct.models.MLModel(
    "HTDemucs6S_stock_FP16.mlpackage", compute_units=ct.ComputeUnit.CPU_AND_GPU
)
out = loaded.predict({"input": example.numpy()})
prediction = np.asarray(next(iter(out.values())), dtype=np.float32)
reference_np = reference.numpy()
names = ["drums", "bass", "other", "vocals", "guitar", "piano"]
import math


def sdr(a, b):
    d = float(np.sqrt(((a - b) ** 2).mean()))
    return float("inf") if d == 0 else 20 * math.log10(float(np.sqrt((a**2).mean())) / d)


worst = min(sdr(reference_np[0, i], prediction[0, i]) for i in range(6))
for i in range(6):
    print(f"  stem {names[i]:7s} SDR: {sdr(reference_np[0, i], prediction[0, i]):6.1f} dB")
print(f"worst stem SDR: {worst:.1f} dB")
for run in range(3):
    start = time.perf_counter()
    loaded.predict({"input": example.numpy()})
    print(f"predict {run}: {time.perf_counter() - start:.2f}s for 7.8s of audio")
