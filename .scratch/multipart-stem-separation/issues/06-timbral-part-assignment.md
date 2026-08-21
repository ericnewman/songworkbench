# 06 — Timbral fingerprinting, part assignment, and mask synthesis

Status: needs-triage

## Why timbre and not just pitch

Pitch rank alone ("highest track = high harmony") flips parts the moment two voices cross, and it
cannot distinguish a double-tracked lead from a harmony at all — a unison double and the lead have
the same f0 by definition. Part identity is a property of the *voice*, so it has to be measured
from the voice.

## Work

- Per-track timbral fingerprint over voiced frames: MFCC / spectral-envelope statistics normalised
  for f0, brightness, harmonic-to-noise ratio, vibrato rate and depth.
- Cluster fingerprints into parts; pitch rank is the tiebreak, phrase-level continuity is a prior
  (a part should not change identity mid-phrase).
- Double detection: a track whose fingerprint clusters with the lead and whose f0 sits within
  ±20 cents or ±1 octave of the lead is `vocals.double`, not a harmony.
- Synthesis: soft harmonic mask per part (comb around f0 and partials, energy shared
  proportionally where partials collide) → apply to the backing STFT → ISTFT (issue 04) → stem.
- Degrade path: if clustering is inconclusive, emit lead + backing exactly as today rather than
  four unreliable stems.

## Acceptance

- [ ] Σ parts vs backing parent ≥ 120 dB SDR.
- [ ] Pairwise cross-part correlation < 0.2.
- [ ] Part consistency ≥ 80% of voiced frames in one cluster per part.
- [ ] Synthetic multi-singer fixture (known parts) recovers the right number of parts.
- [ ] Degrade path proven by a test with a single-voice backing stem.
- [ ] Listening pass, last.
