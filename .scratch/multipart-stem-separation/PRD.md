# PRD — Multi-part vocal and drum separation

Status: needs-triage
Owner: Eric
Target: **at least 4 vocal parts and 4 drum parts**, robust enough to practice against.

## 1. Where we actually are today (verified in-tree, 2026-08-21)

| area | shipped state | evidence |
| --- | --- | --- |
| Drum parts | **4** — kick / snare / cymbals / toms via DrumSep (Hybrid-Demucs ONNX) | `ONNXDrumPieceSeparationEngine.swift`, registered in `StemRefinementEngineFactory.production` |
| Vocal parts | **2 nominally, 0 in practice** | `ONNXKaraokeVocalSeparationEngine.swift`; B8 quality gate FAILED (`tasks/todo.md`), catalog URL is `example.invalid` (`ModelCatalog.swift:139`) |
| Hierarchy / UI | ready for N parts | `StemMixGraph.activeNodes`, `StemMixerChannelProjector`, `StemWaveformLaneProjector` |
| Inverse STFT | **does not exist anywhere in `Sources/`** | `HybridDemucsFrequencyFeatures` is forward-only |

Two facts drive everything below.

**The vocal split is not merely rudimentary — its model is the wrong kind of model.**
`anvuew/karaoke_bs_roformer` is a vocals-vs-instrumental isolator (`instruments:
['Vocals','Instrumental']`). Fed our vocals stem it went out of distribution and split the same
voice across both outputs (lead/residual correlation **+0.514** vs **+0.021** on a full mix;
energy split 28/72). Backing is derived as `parent − lead`, so both outputs inherit the error.
No amount of post-processing rescues this; the checkpoint must be replaced.

**Drums already meet the count but not the robustness bar.** Cymbals is one bucket (hi-hat +
ride + crash together), and the forward STFT packing DrumSep depends on still has no PyTorch
golden-parity test (`tasks/todo.md:911`), so quality complaints today cannot be attributed to the
model rather than to our packing.

## 2. What "4 vocal parts" has to mean

Vocal parts are **homologous sources** — same instrument, same timbre family, overlapping
partials. That is categorically harder than vocals-vs-drums, and it is why no open-weight model
does a 4-way pop harmony split. The literature that does this at all is choir/SATB work
(Petermann et al.; SepACap/SepReformer adapted from speaker separation), trained on a cappella
ensembles, i.e. out of distribution for a pop backing stack.

So the target decomposes into a proposed part taxonomy:

| part | what it is | how it is found |
| --- | --- | --- |
| `vocals.lead` | the main sung line | karaoke model (model-level split) |
| `vocals.double` | unison/octave doubles of the lead | **timbral**: same voice, f0 within ±20 cents or ±1 octave of lead |
| `vocals.harmonyHigh` | harmony above the lead | multi-f0 track ranked above lead, stable across the phrase |
| `vocals.harmonyLow` | harmony below the lead | multi-f0 track ranked below lead |
| `vocals.adlib` (5th, optional) | ad-libs, shouts, whispered/unpitched | **timbral**: low pitch salience, high spectral flux, off-phrase |

This taxonomy is the deliverable to agree on before any modelling. It says a "part" is a
*persistent voice role*, not a per-frame pitch — which is exactly why pitch alone cannot produce
it and timbral analysis is load-bearing.

## 3. Architecture — three layers

### Layer 1 — model split (buy, don't build)

- **Vocals:** replace the failed checkpoint with a genuine lead/backing karaoke model. Live
  candidates: Mel-Band RoFormer karaoke (aufr33/viperx, becruily, gabox, and a fused variant),
  plus a becruily SCNet XL IHF karaoke model. Per `tasks/lessons.md` (2026-07-31), **verify
  before exporting**: (a) the config's instrument list must declare lead/back, not
  Vocals/Instrumental; (b) its full-mix output must be a strict subset of our vocals stem
  (energy ratio well below 1, not ~0.85). Weights are ~1.7 GB for the mel-band checkpoints.
- **Drums:** LarsNet (polimi-ispl) separates **5** — kick, snare, toms, **hi-hat**, cymbals —
  trained on StemGMD. Checkpoints are CC BY-NC 4.0, i.e. the same personal-use gate already
  cleared for the CC-BY-NC base model. It is a spectro-temporal masking model, so it needs the
  same waveform-in/waveform-out ONNX export treatment `tools/karaoke_export/` already proved.

Layer 1 alone yields **2 vocal parts and 5 drum parts**. Drums are then done; vocals are not.

### Layer 2 — native STFT/ISTFT core (the keystone we keep deferring)

Every route to >2 vocal parts is mask-based, and a mask has to be inverted. We have dodged the
ISTFT twice by baking it into an ONNX export; a native part-assignment layer has no graph to hide
behind. Required: STFT/ISTFT with overlap-add and exact window normalisation, parameterised
(n_fft is currently hardcoded to 4096 at `HybridDemucsFrequencyFeatures:11`), with a
golden-parity test against a reference implementation.

Non-negotiable, per `tasks/lessons.md`: a hand-rolled ISTFT produces artifacts that are
**indistinguishable from model quality problems**, which would invalidate every listening gate
downstream. Parity test first, in the same change.

Bonus: this also closes the DrumSep forward-packing parity gap, since both use the same core.

### Layer 3 — pitch + **timbral** part assignment (this is the "some sort of timbral analysis")

Input: the backing stem (and the lead, for double detection). Output: 3-4 part signals.

1. **Multi-f0 salience** per frame over the vocal range. The existing autocorrelation tracker
   (`BassLineAnalysis`) is monophonic by construction — harmony needs a salience surface
   (harmonic-sum / spectral-comb over log-frequency) that can hold 2-4 simultaneous f0s.
2. **Track formation** — link per-frame peaks into continuous f0 tracks with hysteresis, so a
   held third is one track, not 40 frames.
3. **Part assignment — where timbre is required.** Pitch rank alone (`highest = harmonyHigh`)
   flips parts whenever voices cross, and cannot tell a lead double from a harmony at all.
   For each track compute a timbral fingerprint over its voiced frames — MFCC/spectral-envelope
   statistics normalised for f0, plus brightness, breathiness (HNR), vibrato rate/depth — then
   assign tracks to parts by clustering those fingerprints, with pitch rank as the tiebreak and
   phrase-level continuity as a prior. Same singer double-tracked = one cluster near the lead's
   f0; a real harmony = a distinct cluster offset by a stable interval.
4. **Synthesis** — build a soft harmonic mask per part (comb around each track's f0 and its
   partials, energy shared proportionally where partials collide), apply to the backing STFT,
   ISTFT, and write a stem. Constraint: the parts must sum back to the backing stem within
   tolerance, the same invariant the current lead/backing split satisfies at 150.3 dB.

Layer 3 is genuinely new signal processing and the riskiest part of this PRD. It is also the only
route to 4 pop vocal parts with open weights, and it degrades gracefully: if clustering is
inconclusive for a song, emit lead + backing exactly as today rather than four bad stems.

## 4. Robustness — what we will measure (no "finite WAV files were written")

Per-song, automatable:
- **Reconstruction**: Σ parts vs parent ≥ 120 dB SDR (current split: 150.3 dB).
- **Cross-part leakage**: pairwise correlation of part signals < 0.2 (the failed checkpoint hit
  +0.514 — that number is the tripwire).
- **Part consistency**: ≥ 80% of a part's voiced frames assigned to one timbral cluster.
- **Energy plausibility**: no part below −25 dB of the parent claimed as real (reuse
  `HarmonyStemMix.leakageFloorDecibels`, same tell).
- **Cost ceiling**: peak RSS and realtime factor recorded per stage. Precedent to beat — the
  karaoke refiner measured **8.74 GB peak / 0.88x realtime**, which is already bad on macOS and
  impossible on iPad (~3 GB).
- **Listening pass** on a fixed clip set, last, and only once the above pass.

## 5. Phasing

| phase | issue | outcome |
| --- | --- | --- |
| P0 | `01` | Vocal-part taxonomy agreed; failed checkpoint deregistered so the app stops offering a broken split |
| P1 | `02` | Correct karaoke checkpoint verified + exported → real lead/backing (2 parts) |
| P2 | `03` | LarsNet exported and registered → 5 drum parts incl. hi-hat |
| P3 | `04` | Native STFT/ISTFT with golden parity; DrumSep packing parity closed |
| P4 | `05` | Multi-f0 + track formation over the backing stem |
| P5 | `06` | Timbral fingerprinting + part assignment + mask synthesis → 4-5 vocal parts |
| P6 | `07` | Quality gates, memory/runtime budget, UI (the waveform pane already groups parts behind disclosure triangles) |

P1 and P2 are independent of P3-P5 and deliver visible value first. P4/P5 are the R&D.

## 6. Open decisions (blocking)

1. **Audio parts, or analysis?** This PRD assumes separately playable/exportable audio stems. If
   what is wanted is *notated* harmony (which notes each part sings, on the chart), Layer 3 stops
   after step 3 and Layer 2 is not needed at all — a much cheaper project.
2. **Licence posture.** LarsNet is CC BY-NC; the mel-band karaoke weights have unclear terms.
   Both are fine under the existing personal-use gate, neither is fine for a commercial ship.
3. **Cost ceiling.** Is a macOS-only, slower-than-realtime cascade acceptable for these parts, or
   must the whole set stay within some multiple of playback time?
4. **Degrade or refuse?** When timbral clustering is inconclusive, emit lead+backing only, or
   emit 4 parts of lower confidence and mark them draft?
