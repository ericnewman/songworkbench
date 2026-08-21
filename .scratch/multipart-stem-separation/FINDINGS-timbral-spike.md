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

## Follow-up 2 — stereo evidence, and it is the lever

The mask work concluded the limit was evidence rather than estimation, and named stereo
position as the untested source of it. Tested. `run_stereo.py` reproduces this.

Four pitch-distinct voices, panned, separated with and without a spatial term in the mask.
The spatial term weights each bin by how well its observed inter-channel ratio matches each
voice's estimated pan; pan per voice is the median reading across its partials.

| spread | spatial | max correlation | mean SI-SDR (mono sum) | best-channel SI-SDR | baseline |
| --- | --- | --- | --- | --- | --- |
| wide (±0.8 / ±0.35) | off | 0.292 | −7.73 | — | −4.91 |
| wide | **on** | **0.161** | −6.87 | **−2.75** | −4.91 |
| narrow (±0.3 / ±0.12) | off | 0.325 | −5.41 | — | −4.84 |
| narrow | on | 0.300 | −5.20 | −3.27 | −4.84 |
| near-mono (±0.1 / ±0.03) | off | 0.337 | −5.52 | — | −4.83 |
| near-mono | on | 0.335 | −5.48 | −5.02 | −4.83 |

**Cross-part leakage passes its gate for the first time at four parts**: 0.292 → 0.161
against a < 0.2 requirement, where every mask refinement combined had only reached 0.264.
Best-channel SI-SDR — the honest read for a stereo stem, since a panned voice is cleanest in
the channel it sits in — goes from below the unseparated baseline to **+2.2 dB above it**.

The near-mono row is the control, and it is why this can be believed: with the voices
stacked in the middle the spatial term changes nothing (0.337 → 0.335, SI-SDR at baseline).
The improvement scales with how far apart the voices actually sit, which is what a real
positional effect looks like and what fitting noise does not. Estimated pans land within
about 0.1 of the true ones (±0.70 / ±0.27 recovered from ±0.8 / ±0.35).

**Practical consequence, and it is a design constraint, not a nicety: run part separation on
the STEREO backing stem, never on a mono downmix.** Demucs-family separation preserves the
original mix's panning in its stems, so a backing stack that was spread in the mix arrives
spread in the stem — and downmixing to mono, which the natural implementation does, throws
away the single strongest piece of evidence available for telling those voices apart.

Four parts are still not *clean* (+2.2 dB over baseline is a long way from the three-part
case's +13 dB). But the direction is now established and cheap to exploit.

## Follow-up 3 — the two paths separate, and the data says so

Eric's read (2026-08-21): note detection for documenting the progression, and playable
single-voice stems, are two goals that may want different solutions. Measured, they do —
they share the front half of the chain and then diverge completely, and they fail in
different places for different reasons.

`run_notes.py` scores note events (onset/offset/MIDI/confidence, the shape
`BassNoteObservation` already uses) instead of separated audio.

| cast | reference | notes | P | R | F1 | pitch err | onset err |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `distinct` (3 voices) | distinct notes | 18 | 0.810 | 0.944 | **0.872** | 8.5¢ | 27.5 ms |
| `quartet_no_octave` | distinct notes | 24 | 0.636 | 0.583 | 0.609 | 4.6¢ | 27.8 ms |
| `quartet` (octave) | distinct notes | 24 | 0.552 | 0.667 | 0.604 | 5.9¢ | 25.1 ms |
| `hard` (unison double) | **distinct notes** | 18 | 0.750 | 0.833 | **0.789** | 7.3¢ | 26.7 ms |
| `hard` | per-singer notes | 24 | 0.750 | 0.625 | 0.682 | 7.3¢ | 26.7 ms |

**The unison double is free for Path A and fatal for Path B.** Same audio, same chain: as a
stem it is unrecoverable (−35 dB, never even forms a track), and as notation it costs
nothing, because two singers in unison are *one note on the page*. The last two rows are the
same detection scored against the two different references — F1 0.789 vs 0.682 — and at a
0.10 confidence gate the `hard` cast scores **identically to `distinct`** (P 0.882 / R 0.833).
A whole failure mode of Path B simply does not exist for Path A.

**Pitch is not the problem; spurious notes are.** Pitch error is 4.6-8.5 cents everywhere,
well inside a semitone, and onset error is ~27 ms — about one hop plus the attack. Where the
F1 falls, it falls on precision and recall of *which notes exist*, never on what pitch they
were.

**Confidence gating converts that into a shippable posture.** The app's stated position is
that generated analysis is a draft until the user reviews it, so the question is not the F1
but whether a threshold exists where everything written down is correct:

| cast | gate | kept | P | R | F1 |
| --- | --- | --- | --- | --- | --- |
| `distinct` | 0.10 | 17 | 0.882 | 0.833 | **0.857** |
| `distinct` | 0.20 | 12 | **1.000** | 0.667 | 0.800 |
| `hard` | 0.10 | 17 | 0.882 | 0.833 | **0.857** |
| `hard` | 0.20 | 11 | **1.000** | 0.611 | 0.759 |
| `quartet_no_octave` | 0.10 | 20 | 0.700 | 0.583 | 0.636 |

At three voices there is a gate where **every note reported is correct**, at two-thirds
recall. That is the right trade for notation: a wrong note on the page costs more trust than
a missing one, and a missing one is exactly what an editable draft is for. At four voices no
gate rescues it — confidence stops discriminating — so Path A has its own four-voice problem,
and it is a different problem from Path B's.

**Architectural consequence: Path A does not need Layer 2 at all.** It stops at note events,
so no inverse STFT, no mask synthesis, no per-voice audio. That removes the single largest
piece of new DSP from its critical path, and it means Path A can ship long before Path B —
on evidence Path B has not yet produced.

## Follow-up 4 — the octave trap, attacked with stereo

Recommended step 4 said octave separation was worth retrying with stereo evidence in hand,
because two voices an octave apart are inseparable by pitch but perfectly separable by
position. Tested on the octave-voiced quartet (`part1_top` exactly one octave above
`part4_bottom`), `run_octave.py`. `det` counts how many of the four scored parts have an f0
track on their pitch — the question the octave trap actually decides.

| configuration | det | tracks | max corr | mean SI-SDR | top part SI-SDR |
| --- | --- | --- | --- | --- | --- |
| wide / neither | 3/4 | 22 | 0.082 | −11.71 | −45.45 |
| wide / spatial mask only | 3/4 | 22 | 0.074 | −11.60 | −45.70 |
| wide / **pan-slice f0 estimation** | **4/4** | 47 | 0.324 | −28.16 | −36.63 |
| wide / **octave-aware f0** | 3/4 | 26 | 0.388 | **−3.41** | −18.46 |
| near-mono / pan-slice f0 | 4/4 | 31 | 0.251 | −21.83 | −70.04 |
| near-mono / octave-aware f0 | 3/4 | 28 | 0.239 | −6.70 | +0.65 |
| near-mono / neither | 3/4 | 28 | 0.239 | −6.70 | +0.66 |

Baseline is −4.8 dB.

**First: spatial masking alone cannot help an octave pair, and it is worth saying why.** By
the time the mask runs, the upper voice is already gone — the estimator ran on the mono mid,
found the lower voice first, and notched away its harmonic series, which *contains* the upper
voice's fundamental. `wide / spatial mask only` is identical to `wide / neither` (3/4, −11.6
vs −11.7). The earlier stereo win was real, but it was a win about *sharing* energy between
detected voices, not about detecting a voice that was never there.

**Pan-slice estimation recovers the voice, but not for the reason it claims.** Estimating f0
inside each of five pan slices and pooling the candidates does reach 4/4 — and so does the
near-mono control, where there is almost no position to exploit. That makes it noise-fitting,
not positional evidence, and it costs dearly: tracks 22 → 47, leakage 0.074 → 0.324, mean
SI-SDR −11.6 → −28.2. **Rejected**, same verdict and same reason as the mono octave test.

**The octave-aware estimator is selective and partly works.** It adds a partner at 2·f0 only
when the spectral test AND a positional test both fire — the positional test comparing how
the even partials are panned against how the odd ones are (odd partials belong to the lower
voice alone, so a difference means somebody else is on the even ones). The control is exactly
right this time: on the near-mono spread it is **inert**, reproducing the no-op numbers to
two decimals (0.239 / −6.70 / +0.65 vs +0.66), because the evidence it requires is absent.
On the wide spread it fires, adds four tracks, and lifts mean SI-SDR from **−11.60 to −3.41**
(+8.2 dB, the largest single improvement measured on this cast).

But it still reports 3/4: it does not fire on enough frames to give the top voice a sustained
track. Its gate is `octave_above_present`, the spectral test already known to be unreliable,
so the positional evidence never gets consulted on most frames.

**Where to resume**: relax or replace the spectral precondition and let the positional test
carry the decision on its own. The near-mono control is the guard that makes that safe to
try — it caught the pan-slice approach cleanly, and it will catch a too-loose gate the same
way. Not attempted here: it is a third octave iteration, and the risk of tuning to one 8 s
fixture outweighs the value of another point estimate.

## Follow-up 5 — octave rescue, done properly and still not ready

Follow-up 4 ended with a named next step (stop gating the octave test behind the unreliable
spectral test) and a named risk (tuning to one 8 s fixture). This does it across **four
seeds**, both spreads, with the near-mono control AND the two non-octave casts as a
regression guard. `run_octave_seeds.py` reproduces it. Averages over seeds 3/7/11/19:

| cast | config | det | max corr | mean SI-SDR |
| --- | --- | --- | --- | --- |
| octave quartet, wide | off | 3.00/4 | 0.088 | −11.59 |
| | gated | 3.00/4 | 0.308 | −4.82 |
| | ungated | **4.00/4** | 0.333 | −9.48 |
| | **per-track** | **4.00/4** | 0.456 | −8.35 |
| octave quartet, near-mono (control) | off / per-track | 3.00/4 | 0.186 | −7.58 |
| `quartet_no_octave`, wide | off | 4.00/4 | 0.157 | **−6.71** |
| | per-track | 4.00/4 | 0.179 | −11.75 |
| `distinct` (3 voices), wide | off | 3.00/3 | 0.063 | **+5.30** |
| | per-track | 3.00/3 | 0.171 | −5.43 |

**Two things were fixed along the way, and both were real bugs rather than tuning.**

*Per-frame → per-track.* Firing on per-frame evidence injected phantom partners into casts
with no octave pair, taking `distinct` from +5.30 to −12.74 dB. Interference between any two
voices moves the even/odd pan balance on SOME frames; only a real partner moves it on most.
Deciding once per note — the rule the rest of this chain already follows — removed that.

*The evidence measure was medianing away its own signal.* Diagnosed by printing the per-track
vote table: the real bottom voice's tracks (midi 60/62/64) scored **0.03-0.36** agreement and
earned no partner, while junk tracks near midi 55 scored **0.87-1.00** and earned bogus ones.
Partial 2 is the only informative one — it is where a partner's fundamental sits — and above
it the partner's energy has decayed by 1/h, so four near-even mixtures outvoted the one bin
carrying the signal. Comparing partial 2 against its odd neighbours (1 and 3) instead takes
detection from 3.00/4 to **4.00/4 on every seed**, with the control still perfectly inert.

**And it is still not shippable.** Every configuration that recovers the octave voice also
damages the casts that already worked: `distinct` +5.30 → −5.43, `quartet_no_octave` −6.71 →
−11.75. A specificity constraint — only rescue a voice that is MISSING, i.e. skip when a
track already sits within 150 cents of 2·f0 — was the obvious candidate explanation and was
tested: it moved `distinct` from −5.12 to −5.43, i.e. **not at all**. So the hypothesis that
the regression comes from re-detecting an already-detected voice is **wrong, and the real
cause is unknown.** That is the next question, and it is a better question than the one this
follow-up started with.

Left **opt-in and off** (`separate_stereo(octave_partners=True)`); the default path and every
previously recorded number are unchanged, verified by re-running `run_stereo.py` (0.292 →
0.161 reproduces exactly) and `selftest.py` (9/9).

## Recommended next steps

0. **Split the work into two tracks with separate gates and separate shipping order.**
   Track A (notes) is cheaper, needs no ISTFT, is immune to the unison case, and already has
   a 100%-precision operating point at three voices. Track B (stems) needs the whole DSP
   stack and is still below baseline at four voices. Sequencing them together holds the
   cheap one hostage to the expensive one.
1. **Amend the PRD taxonomy**: drop `vocals.double` as a separable part; state that a
   double rides with the lead. For Track A it is not even a distinct note.
2. **Target three parts as the shipping goal** (lead + two harmonies), with four as a
   stretch that depends on (3) and (4).
3. ~~**Improve mask synthesis before anything else**~~ — **done and closed**, see the
   follow-up section above. Per-voice profiles, per-frame gains, and a per-frame NNLS fit
   were all measured; together they buy 1.7 dB at four parts and change nothing at three.
   Magnitude-domain masking is at its limit. A phase-aware/complex mask remains untried and
   is the only remaining idea in this direction worth spending on.
4. **Treat octave separation as its own research item.** Four attempts recorded (follow-ups
   4 and 5). Detection is SOLVED — 4.00/4 across four seeds, control-clean, via per-track
   decisions plus a partial-2-vs-odd-neighbours evidence measure. What is not solved is why
   enabling it degrades the non-octave casts; the obvious explanation was tested and refuted.
   Resume there, with `run_octave_seeds.py` as the harness.
5. **Build the part layer on stereo input from the start.** See follow-up 2 — a mono
   downmix discards the evidence that makes four parts plausible at all.
6. **Re-run on real audio** before committing to the Swift port: the fixture has no
   consonants, breath, reverb, or separation artifacts, and every one of those will hurt.
   `run_spike.py --input backing.wav` is ready for that; it needs a real backing stem,
   which in turn needs PRD issue `02` (a genuine lead/backing checkpoint) to land first.

## Caveat

Synthetic sources only. The fixture models voices as harmonic source-filter signals with
vibrato — good enough to prove that timbral clustering separates singers, and useless for
predicting behaviour on breathy consonants, reverb tails, or the artifacts a separation
model leaves behind. Every number above should be read as an upper bound.
