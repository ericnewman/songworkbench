# Findings — timbral part-assignment spike (2026-08-21)

Status: needs-triage
Code: `tools/harmony_parts_spike/` · reproduce with `python3 tools/harmony_parts_spike/selftest.py`

Answers the question PRD issue `06` was blocked on, before any Swift was written: **do
per-note timbral fingerprints cluster by singer well enough to assign vocal parts?**

Yes for pitch-distinct parts, with a large measured margin. No for two specific
configurations, and both are structural rather than tuning problems.

## Results

All four casts are 8 s, three or four synthetic singers differing in formants, spectral
tilt, and vibrato, mixed at unequal gains, with a deliberate voice crossing near the end.
Ground truth is the score, so every number below is checkable.

| cast | parts asked | singers recovered | note assignment | max cross-part correlation | per-part SI-SDR (dB) |
| --- | --- | --- | --- | --- | --- |
| `distinct` — 3 voices, 3 lines | 3 | **3/3** | **0.947** | **0.085** | lead **+12.9**, high **+13.1**, low **+3.6** |
| `quartet_no_octave` — 4 voices, 4 lines | 4 | **4/4** | 0.818 | 0.342 | +0.6, −2.0, −3.7, −17.9 |
| `quartet` — bottom an octave below top | 4 | 3/4 | 0.862 | 0.242 | bottom **−24.4** |
| `hard` — 3 voices + unison double of lead | 4 | 3/4 | 0.944 | 0.075 | double **−35.5** |

Unseparated baseline is −3.6 to −5.5 dB SI-SDR, so the `distinct` result is a **~16 dB
improvement** on two of three parts. Reconstruction (Σ parts vs input) is 313 dB on every
cast, because the masks are normalised to partition unity — energy is redistributed, never
invented or lost. The STFT/ISTFT round trip is also 313 dB, which independently validates
the Layer 2 approach: sqrt-Hann analysis and synthesis at hop = n_fft/8 is COLA-exact.

## What this means for the target

**Three parts work today.** Lead, harmony-above, harmony-below separate cleanly, survive a
voice crossing, and the timbral clustering — not pitch rank — is what carries the crossing.

**Four parts are findable but not yet clean.** With four pitch-distinct voices the chain
recovers all four singers and assigns 82% of notes correctly, but the audio quality of the
split degrades badly (cross-part correlation 0.342 against a 0.2 gate, and two parts land
below the unseparated baseline). The assignment layer scales; the *mask synthesis* is what
breaks, because four voices in one octave means most partials are shared and a soft mask
has less and less exclusive evidence to work with. That is the thing to improve, and it is
a narrower problem than the one we started with.

**Two structural limits, both worth designing around rather than fighting:**

1. **A unison double is not separable by any f0-informed method.** It shares every partial
   with the lead by definition. Measured: the double never even forms its own track (18
   tracks where 24 notes were sung), and the part slot allocated to it collects −35 dB of
   noise. The PRD taxonomy listed `vocals.double` as a part; **that entry should be
   removed** — a double belongs inside the lead part, and separating it needs different
   evidence entirely (stereo/phase differences, or a model trained for it).
2. **Octave-related parts collapse into one.** The lower voice's even partials *are* the
   upper voice's harmonic series, so the estimator finds the lower voice first and the
   subtraction step deletes the upper one. Measured: 3 of 4 singers recovered, bottom part
   at −24.4 dB. Moving the bottom voice up one semitone — musically almost the same chord —
   recovers 4 of 4. This matters because bottom-an-octave-below-top is an ordinary SATB
   voicing, so a real four-part stack will hit it regularly.

## What was tried and rejected (so it is not re-litigated)

- **Plain peak-picking on a harmonic-sum salience surface.** Fails outright. Under a 392 Hz
  note the strongest peaks were 196, 130 and 99 Hz — f0/2, f0/3, f0/4 — which filled every
  peak slot and pushed the real harmony note at 494 Hz out of the estimate. Iterative
  subtraction (find strongest, notch its whole series, re-score) fixed it: 48 tracks → 18.
- **Gentler subtraction to protect octave voices.** Subtracting only each partial's
  envelope-predicted share instead of notching. It does protect octaves, but it lets the
  sub-harmonic ghosts back in: tracks 16 → 41, note assignment 0.95 → 0.63. Reverted.
- **An explicit octave-presence test** (odd partials predict even ones; a lifted even series
  means someone is standing on it). Swept at thresholds 1.7 / 2.2 / 3.0: best quartet result
  was 3/4 — no better than leaving it off — while `distinct` fell to 0.73/0.73/0.67 and a
  phantom voice captured a part slot, collapsing one SI-SDR below −30 dB. Left in the code
  wired and off by default (`estimate_f0s(rescue_octaves=True)`) so the next attempt starts
  from evidence.
- **Deciding a note's true owner by "loudest source over its span".** A measurement bug, not
  an algorithm one, but an instructive one: everyone sings at once and the lead is mixed
  loudest, so it labelled every note `lead` and reported 0.53 accuracy for a chain that was
  actually at 0.95. Ground truth now comes from the score.

## Follow-up — mask synthesis attacked directly (same day)

The findings above named mask synthesis as the binding constraint at four parts, so it was
attacked next. Four variants, identical part assignment in every case, so all differences
are attributable to the mask alone. `compare_masks.py` reproduces the table.

| cast | metric | `comb` | `comb_gain` | `measured` | `measured_gain` | `nnls` |
| --- | --- | --- | --- | --- | --- | --- |
| `distinct` (3 parts) | mean SI-SDR | **9.86** | 3.34 | 8.12 | 9.82 | 9.44 |
| | max correlation | 0.085 | **0.030** | 0.095 | 0.061 | 0.076 |
| `quartet_no_octave` | mean SI-SDR | −5.74 | −6.61 | −4.73 | −4.38 | **−4.04** |
| | max correlation | 0.342 | 0.313 | 0.303 | 0.276 | **0.264** |
| `quartet` (octave) | mean SI-SDR | −6.64 | −7.51 | −6.72 | **−6.36** | −6.58 |
| `hard` (unison) | mean SI-SDR | **−4.35** | −11.86 | −5.00 | −4.67 | −5.64 |

- `comb` — fixed 1/h harmonic comb, all tracks weighted equally (the original).
- `comb_gain` — that comb scaled by a per-frame loudness estimate (25th-percentile ratio
  across the track's partials).
- `measured` — each track's own measured partial profile, no per-frame gain.
- `measured_gain` — that profile plus the per-frame gain.
- `nnls` — per frame, model the spectrum as a sum of per-track harmonic templates and solve
  the per-voice amplitudes by non-negative least squares. The principled version: a
  collision is resolved by what each voice's OTHER partials imply about its level.

**Conclusion: mask sophistication is not the lever.** Going from the naive comb to a
per-frame NNLS fit — a substantially more complex estimator, and 8× slower — buys **1.7 dB**
on the four-part target (−5.74 → −4.04 mean SI-SDR) and moves cross-part correlation from
0.342 to 0.264, still short of the 0.2 gate and still below the unseparated baseline. On the
three-part case every variant lands within 0.4 dB of the others, i.e. within noise.

The per-frame gain alone is actively harmful (9.86 → 3.34 on `distinct`, −4.35 → −11.86 on
`hard`): a loudness estimate taken from a voice's own partials is inflated by exactly the
collisions it is meant to arbitrate, so it amplifies whichever voice is already winning.

What this says about the four-part goal: the limit is **evidence, not estimation**. Four
voices inside one octave collide on most partials, and no amount of cleverness recovers a
voice's share of a bin from magnitude alone. Getting past it needs a different kind of
evidence — stereo/phase differences between voices, or a learned model — not a better mask.

**Default left at `comb`.** It is statistically tied at three parts, it is by far the
simplest thing to port to Swift, and the alternatives only pay on a four-part case that is
not shippable anyway. Do not port the complexity; the measurements are here if the four-part
case is ever revisited.

## Recommended next steps

1. **Amend the PRD taxonomy**: drop `vocals.double` as a separable part; state that a
   double rides with the lead.
2. **Target three parts as the shipping goal** (lead + two harmonies), with four as a
   stretch that depends on (3) and (4).
3. ~~**Improve mask synthesis before anything else**~~ — **done and closed**, see the
   follow-up section above. Per-voice profiles, per-frame gains, and a per-frame NNLS fit
   were all measured; together they buy 1.7 dB at four parts and change nothing at three.
   Magnitude-domain masking is at its limit. A phase-aware/complex mask remains untried and
   is the only remaining idea in this direction worth spending on.
4. **Treat octave separation as its own research item.** It is a known-hard multi-f0
   problem; the spike has the harness to measure any attempt in seconds.
5. **Re-run on real audio** before committing to the Swift port: the fixture has no
   consonants, breath, reverb, or separation artifacts, and every one of those will hurt.
   `run_spike.py --input backing.wav` is ready for that; it needs a real backing stem,
   which in turn needs PRD issue `02` (a genuine lead/backing checkpoint) to land first.

## Caveat

Synthetic sources only. The fixture models voices as harmonic source-filter signals with
vibrato — good enough to prove that timbral clustering separates singers, and useless for
predicting behaviour on breathy consonants, reverb tails, or the artifacts a separation
model leaves behind. Every number above should be read as an upper bound.
