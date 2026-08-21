# 05 — Multi-f0 salience and track formation over the backing stem

Status: needs-triage

## Problem

`BassLineAnalysis` estimates f0 by normalised autocorrelation and is monophonic by construction —
one lag, one answer. Harmony needs 2-4 simultaneous f0s per frame.

## Work

- Harmonic-sum / spectral-comb salience over a log-frequency axis across the vocal range,
  producing a per-frame salience surface rather than a single peak.
- Peak picking with a salience floor, then track formation: link peaks across frames with
  hysteresis and a maximum per-frame cent deviation, so a held note is one track.
- Voiced/unvoiced gating reusing the existing vocal-activity detection
  (`AudioFileAnalysisService.swift:1902`) so silence cannot manufacture tracks.

## Acceptance

- [ ] On synthesised 3-part harmony (known f0s), ≥ 90% frame-level recall of each part's f0
      within 50 cents.
- [ ] On a monophonic passage, produces exactly one track — no phantom harmonies.
- [ ] Deterministic and pure (no I/O), unit-tested like `BassLineAnalysis`.

## Update 2026-08-21 — algorithm proven offline

`tools/harmony_parts_spike/` implements this stage and measures it
(`FINDINGS-timbral-spike.md`). Two results change how this issue should be built:

- **Plain harmonic-sum peak-picking does not work.** Sub-harmonic ghosts (f0/2, f0/3, f0/4)
  outrank real harmony notes and fill every peak slot. Iterative subtraction — find the
  strongest candidate, notch its whole harmonic series, re-score — cut the track count from
  48 to 18 on a fixture where 18 was correct. Build the Swift version this way from the start.
- **Octave-related voices collapse.** The lower voice's even partials are the upper voice's
  series, so the notch deletes the upper voice. Measured cost: 3 of 4 singers recovered. A
  gentler subtraction and an explicit octave test were both tried and both lost; see the
  findings. Treat octave handling as a separate research item, not part of this issue.

Acceptance criteria below are unchanged and now have reference numbers to hit.
