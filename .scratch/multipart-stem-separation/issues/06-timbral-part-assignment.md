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

## Update 2026-08-21 — assignment proven, synthesis is the open problem

Measured in `tools/harmony_parts_spike/` (`FINDINGS-timbral-spike.md`):

- Timbral clustering assigns notes to singers at **0.947 accuracy** on three pitch-distinct
  voices, and it carries a voice crossing that pitch-rank assignment cannot.
- Separation quality on that cast: **+12.9 / +13.1 / +3.6 dB SI-SDR** against a −3.6 dB
  baseline, cross-part correlation **0.085**.
- At four voices the assignment still holds (4/4 singers, 0.818) but the split degrades:
  correlation **0.342**, two parts below baseline.
- **Mask synthesis was then attacked directly and is now closed as a dead end.** Per-voice
  measured profiles, per-frame gains, and a per-frame NNLS fit of all voices at once were
  each measured against all four casts: together they buy **1.7 dB** at four parts
  (correlation 0.342 -> 0.264, still short of the 0.2 gate) and nothing at three parts. The
  per-frame gain alone is harmful. Magnitude-domain masking is at its limit — the constraint
  is evidence, not estimation. **Port the simple 1/h comb**; the complexity does not pay.
- **`vocals.double` is removed from the taxonomy**: a unison double shares every partial with
  the lead and never forms its own track. It rides with the lead.

Next: re-run the spike on a real backing stem (needs issue `02` first), then port.
