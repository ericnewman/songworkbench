# 02 — Verify and export a genuine lead/backing karaoke checkpoint

Status: needs-triage

## Work

Candidates: Mel-Band RoFormer karaoke (aufr33/viperx, becruily, gabox, fused), becruily SCNet XL
IHF karaoke. `openmirlab/melband-roformer-infer` aggregates the checkpoints and their configs,
which is the cheapest way to read instrument lists without downloading 1.7 GB each.

**Verification BEFORE export** (this is the `tasks/lessons.md` 2026-07-31 rule):
1. Config instrument list declares lead/back — not `['Vocals','Instrumental']`.
2. Fed the full mix, output energy is a strict subset of our vocals stem (ratio well below 1;
   ~0.85 means it is reproducing the stem we already have).
3. Fed our vocals stem (the cascade's actual input), lead/residual correlation stays near 0.
   +0.514 was the failure signature.

Then export waveform-in/waveform-out ONNX via the `tools/karaoke_export/` recipe (float64 DFT
kernels, opset 18, chunk sized to survive the tracer) and re-run golden parity against PyTorch.

## Acceptance

- [ ] Parity ≥ 79 dB on the loudest window (the demucs export precedent).
- [ ] Cascade leakage correlation < 0.2 on at least 5 songs.
- [ ] Peak RSS and realtime factor recorded; compared against the 8.74 GB / 0.88x precedent.
- [ ] Catalog entry has a real download URL, sha256, size; `optionalRefinementIDs` membership
      keeps onboarding unblocked.
- [ ] Listening pass on a fixed clip set.
