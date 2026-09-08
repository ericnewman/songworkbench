# Basic Pitch probe (spike)

Ground-truth run of Spotify Basic Pitch (ONNX path) over the app's separated stems, bucketed on the
MetronomeGrid. Results, model contract, and the GO/NO-GO write-up live in `tasks/spike-basic-pitch.md`;
setup commands are at the top of that file. `.probevenv/` (TensorFlow, onnxruntime, coremltools and the
model weights) is gitignored — recreate with `uv venv --python 3.12 .probevenv`.
