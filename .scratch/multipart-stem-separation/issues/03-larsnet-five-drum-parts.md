# 03 — LarsNet: five drum parts including a separate hi-hat

Status: needs-triage

## Rationale

DrumSep already gives 4 (kick/snare/cymbals/toms), so the count target is met — but hi-hat, ride
and crash share one bucket, which is the part players most want isolated. LarsNet (polimi-ispl,
StemGMD) separates kick, snare, toms, hi-hat, cymbals. Checkpoints are CC BY-NC 4.0 — the same
posture as the CC-BY-NC base model, acceptable under the personal-use gate, not for a commercial
ship.

## Work

- Bank of parallel U-Nets doing spectro-temporal soft masking → mask output, so it needs the same
  waveform-in/waveform-out export treatment as the karaoke model (STFT + ISTFT inside the graph).
- Decide whether it replaces DrumSep or is offered alongside it (storage: every combination is a
  full extra stem set with no eviction policy today).

## Acceptance

- [ ] Export parity ≥ 79 dB.
- [ ] Σ parts vs drums parent ≥ 120 dB SDR.
- [ ] Hi-hat part passes a listening check against the cymbals part (they must not be the same
      signal twice).
- [ ] Registered, installable from the catalog, visible as five mixer channels and five waveform
      lanes end to end (`tasks/lessons.md` 2026-07-28).
