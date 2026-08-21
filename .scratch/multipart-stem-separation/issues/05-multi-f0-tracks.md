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
