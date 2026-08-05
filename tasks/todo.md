# Track B — Richer Stems as a Playback Feature (2026-07-29, NOT STARTED)

Captured on Eric's request so it is not lost. **Do not start** — recorded only.

Independent of Track A below. Track A asks "do better stems improve transcription?" (answer so
far: no). Track B asks for richer stems as a **product feature in their own right** — separately
playable parts for practice — **explicitly worth doing even if transcription never improves**.
The Phase 0 no-go on Track A therefore does NOT block this.

- [ ] **Lead vs backing vocals** — *feasible now*. Design below.
- [ ] **Lead vs rhythm guitar** — *frontier, R&D*. No open weights; the known implementations are
      closed (Moises). `StemID.guitarLead` / `.guitarRhythm` are declared and unregistered
      (`StemSeparation.swift:91-92`). Do not promise this on a schedule.

## Track B design — lead vs backing vocals (PLANNING ONLY, not approved to build)

### Model candidates

| candidate | arch / size | runs on | licence | note |
| --- | --- | --- | --- | --- |
| Mel-Band RoFormer karaoke (aufr33/viperx checkpoint) | Mel-Band RoFormer, ~200 MB | CPU ok, GPU faster | **community-trained, terms unclear** | best quality reported for lead/backing |
| UVR-MDX-NET Karaoke 2 | MDX-Net, ~60 MB ONNX | CPU fine | code MIT; **weights unclear** | smallest, proven, weaker on dense harmony |
| MVSEP MDX23 karaoke | ensemble | heavier | service-linked, **check terms** | ensemble cost probably not worth it here |

Recommendation: **UVR-MDX-NET Karaoke 2 first** — it is the smallest, is ONNX already (so it fits
the existing `StemChunkPredicting` path with no new runtime), and lead/backing is a coarse split
where the quality gap matters less than for chord work. Promote to Mel-Band RoFormer only if a
listening pass rejects it.

**Licence is a genuine blocker to resolve BEFORE download**, not after: the base model is already
CC-BY-NC-4.0 (non-commercial), and these karaoke weights are community-trained with unclear
terms. Two unclear-licence models is a materially worse position than one. Get a definite answer
per artifact, and record `name` + `attribution` in `ModelArtifactLicense` like every other entry.

### Integration — refiner cascade (recommended)

This is a same-instrument split of an existing stem, which is exactly the shape
`NativeStemRefinementEngine` already implements: it feeds a refiner ONLY its parent stem
(`StemSeparation.swift:483-500`) and maps model outputs onto stable child IDs. **DrumSep is the
working precedent** — drums → kick/snare/cymbals/toms, registered in
`StemRefinementEngineFactory.production` (`SongAnalysisPipelineFactory.swift:165`).

So: `parentStemID: StemKind.vocals.id`, outputs mapped to `.vocalLead` / `.vocalBacking`. Cascade
runs after base separation, on the vocals stem only — roughly 1/6th the audio content of a full
mix pass.

Rejected alternatives: a **base-engine swap** is wrong (this splits an existing stem rather than
producing a full stem set) and **`ExternalStemRefinementEngine`** is macOS-only by construction,
which forecloses the iPad path Track B eventually wants.

### Registration and cache impact

- `StemID.vocalLead` / `.vocalBacking` already exist (`StemSeparation.swift:85-86`) — no taxonomy
  change needed.
- Add a `ModelPackageDescriptor` to `ModelCatalog`, add its id to
  `ModelCatalog.optionalRefinementIDs`, or it **blocks first-run onboarding for every user**.
- Cache: `StemRecipeIdentity` already hashes the refiner list
  (`refiners: [String]`, `StemSeparation.swift:138-174`), so adding a refiner changes
  `cacheKey` → existing stems are correctly invalidated and re-derived. **No manual cache work.**
- Bump `taxonomyVersion` on the refiner so older manifests do not alias.

### macOS vs iPad — macOS-first, and now we have the number

Measured 2026-07-29 on this Mac (12-core, 24 GB): the base 6-stem pass peaks at **3.91 GB RSS**
at the 7.8 s segment. That is already **above the iPad ~3 GB per-process ceiling** — which is
exactly why iPad ships the 2.5 s re-export.

The cascade runs sequentially and the ORT session is released after the base pass (commit
`121ecd5`), so peak should be `max(base, refiner)` not the sum. But on iPad the base pass already
warms to ~2.1 GB against a ~3 GB cap, leaving ~0.9 GB — tight for a second model even at ~60 MB
of weights, since the arena dominates, not the weights.
**Ship macOS/Advanced-Desktop only initially; treat iPad as a separate proof.**

### Downstream risk — vocals is NOT presentation-only (verified)

Consumers of `stems.vocals` today:

| consumer | site | risk |
| --- | --- | --- |
| **Transcription (ASR)** | `AnalysisStage.swift:250`, `SongAnalysisPipeline.swift:369` | highest |
| Vocal activity envelope / waveform | `AppModel.swift:1175, 2491` | medium |
| Stem mix export | `StemMixExporter.swift:47` | medium |

The protective detail: those all read the **flat legacy `StemFiles.vocals`**, not the
hierarchical frontier. `StemMixGraph.activeNodes` hides a parent once it has children
(`StemSeparation.swift:347-355`), so the **mixer and waveform lanes switch to lead/backing
automatically while transcription keeps reading the untouched parent**. That is the desired
default: richer playback, zero transcription change.

Two things to verify rather than assume:
1. `StemMixExporter` keys off `files[StemKind.vocals.id]` as its reference file — confirm it
   still resolves when the frontier exposes children instead of the parent.
2. Per `tasks/lessons.md` (2026-07-28), do not call this delivered until catalog, factory
   registration, installed artifact, persisted manifest, AND visible mixer channels are verified
   end to end.

**Opportunity flagged, deliberately out of scope:** pointing ASR at `vocals.lead` instead of the
full vocals could improve transcription by removing backing harmonies. That is a Track A-style
accuracy change and must be measured, not assumed — Track B ships playback only.

### Phased checklist (next pass, mechanical)

- [x] B1 — Licence gate cleared 2026-07-29: SongWorkbench is personal/hobby, so the unclear-terms
      community karaoke weights are acceptable. (Note this does NOT clear a future commercial
      ship; the base model is CC-BY-NC-4.0 and these weights are unclear.)
- [x] B2 — Artifact acquired and contract verified. **THE CONTRACT CHECK FAILED — B3-B8 BLOCKED.**
      `UVR_MDXNET_KARA_2.onnx`, 52,786,726 bytes,
      sha256 `bf32e15105a09c0f7dddd2b67346146334d6f3ecb399ed7638eba2ab07cbf5f4`,
      from `github.com/TRvlvr/model_repo` `all_public_uvr_models`.
      Probed with `Tests/SongWorkbenchTests/KaraokeModelProbeTests.swift`:
      - rank-3 waveform `[1,2,N]` → **rejected**: "Invalid rank for input: Got: 3 Expected: 4"
      - `[1,4,2048,256]` → **accepted**, output `[1,4,2048,256]`
      This is **spectrogram in → spectrogram out**. Every existing engine is waveform-out, so
      nothing in the codebase can consume it.

### B2 BLOCKER — the model needs an inverse STFT this codebase does not have

`StemChunkPredicting` is a waveform contract (`CoreMLStemSeparationEngine.swift:20`). DrumSep
looks like a counterexample but is not: it feeds BOTH a waveform `[1,2,N]` and a packed
spectrogram `[1,4,F,T]` and receives a **waveform** `[1,4,2,N]` back
(`ONNXDrumPieceSeparationEngine.swift`), so `HybridDemucsFrequencyFeatures` only ever runs
**forward**. There is no ISTFT anywhere in `Sources/`.

Making KARA_2 work therefore requires NEW DSP, not mirroring DrumSep:
1. STFT at this model's parameters (n_fft ~5120 / dim_f 2048 / dim_t 256 ≈ 5.9 s chunks);
   `HybridDemucsFrequencyFeatures` hardcodes n_fft 4096 (`:11`), so it would need
   generalising — a shared path DrumSep depends on.
2. **Inverse STFT with overlap-add and exact window normalisation** — entirely new.
3. Complement derivation for the backing stem (`vocals − lead`).

Why this is a stop-and-ask rather than just work: a hand-rolled ISTFT produces artifacts that are
**indistinguishable from model quality problems**, which would invalidate the B8 listening test —
the very gate meant to judge backing-stem quality. The repo already carries an unvalidated
instance of this risk: the DrumSep note says "STFT packing still needs PyTorch golden parity".
Adding a second, larger unvalidated DSP path on top is how this becomes unfalsifiable.

### B2 REDONE via PATH (a) — 2026-07-31 — WAVEFORM EXPORT SUCCEEDED

Decision was path (a): export a waveform-in/waveform-out ONNX ourselves, no Python at runtime.

**Model chosen:** `karaoke_bs_roformer_anvuew.ckpt` + `karaoke_bs_roformer_anvuew.yaml` from
HuggingFace `anvuew/karaoke_bs_roformer`. 204,486,925 bytes. BS-RoFormer, `num_stems: 1` (emits
lead vocals; backing = input − lead). n_fft 2048 / hop 512 / dim 256 / depth 12. Chosen over the
mel-band karaoke checkpoints because they are 1.7 GB vs 195 MB. No declared licence on either
repo — acceptable under the personal-use gate, NOT under any future commercial ship.

**Architecture source:** ZFTurbo `Music-Source-Separation-Training` `models/bs_roformer/`, NOT the
`bs-roformer` pip package. The pip package (1.2.4) has moved to hyper-connections and mismatches
this checkpoint by **668 missing / 240 unexpected** keys. ZFTurbo's code loads it at
**missing=0 unexpected=0**.

**Export:** `scratchpad/export_karaoke.py` — mirrors `BSRoformer.forward`'s inference path in
pure real arithmetic (no complex tensors anywhere), with STFT and ISTFT rebuilt from conv1d /
matmul-IDFT / fold overlap-add, exactly the `tools/demucs_export/realstft.py` trick. Result:
**`karaoke_waveform.onnx`, 232.5 MB, opset 18.**

**CONTRACT GATE — PASSED (this is what killed KARA_2):**

```
input  name=input  shape=[1, 2, 262144] rank=3   <- WAVEFORM
output name=output shape=[1, 2, 262144] rank=3   <- WAVEFORM
```

**GOLDEN PARITY — PASSED:** ONNX vs PyTorch reference on real audio
**SDR 103.1 dB**, max_abs 1.99e-05, mean_abs 4.77e-07. (Synthetic-noise input: 91.8 dB.)
This beats the demucs export precedent (79 dB), so a later listening test judges the MODEL, not
the export.

Three export blockers hit and fixed, all worth knowing for the next export:

1. **OOM at the training chunk.** 640000 samples = 1251 frames; time-axis attention is O(T²) and
   the tracer holds every intermediate → SIGKILL. Exported at **262144 (5.9 s)** instead. The
   chunk is baked into the graph, so this also becomes the app's segment length.
2. **`aten::col2im` needs opset 18** (`F.fold`), and its symbolic requires a **static**
   `output_size` — deriving it from traced tensor shapes fails with
   `'NoneType' object is not subscriptable`. Frame/bin counts are now Python int constants.
3. **Kernel precision, the subtle one.** Building the DFT kernels in float32 gave only 86 dB on
   the forward STFT, which the 12-layer transformer amplified to **48 dB** end-to-end. The angle
   `2πkn/N` reaches k·n ≈ 2.1e6, past float32's resolution. Building kernels in float64 and
   casting to float32 → forward STFT 121.6 dB, end-to-end **103.1 dB**, at zero runtime cost
   (they are graph constants).

- [ ] B3-B8 — unblocked, awaiting Stage 2 approval.
- [ ] Confirm the app's bundled ONNX Runtime loads an **opset 18** graph (verification started).
- [ ] Note for Stage 2: at 262144-sample segments the refiner runs on the vocals stem only; the
      base pass already peaks 3.91 GB, so measure the cascade's added peak before any iPad claim.

### Options considered before path (a) was chosen (kept for the record)

- **(a) Find a waveform-in/waveform-out karaoke export.** Zero new DSP; drops straight into the
  existing refiner path. Cost: Mel-Band RoFormer karaoke weights ship as PyTorch `.ckpt`, so this
  likely needs an export step — precedent exists in `tools/demucs_export/`, which is how the
  current 6-source model was produced. **Recommended if an export is achievable.**
- **(b) Build the STFT/ISTFT pipeline natively.** Keeps the iPad path open long-term. Cost:
  several hundred lines of new DSP, generalising a shared helper DrumSep depends on, and it needs
  a golden-reference parity test or the B8 listening result cannot be trusted.
- **(c) `ExternalStemRefinementEngine` + Python `audio-separator`.** Zero new DSP and the adapter
  already exists and already takes the original mix. macOS-only, and `tasks/lessons.md` allows
  subprocess/Python explicitly as an optional macOS extension but "never the iPad path".
  **Fastest route to actually hearing lead/backing stems.**

Recommendation: **(c) to get playable stems now, (a) as the shipping path.** (b) only if native
iPad lead/backing becomes a firm requirement.
### B3-B8 EXECUTED 2026-07-31 — infrastructure works, MODEL IS WRONG

- [x] B3 — `ModelCatalog.karaokeVocals` added, in `optionalRefinementIDs`. Test asserts both that
      it is optional and that it is offered on Advanced Desktop, so it can never block onboarding.
- [x] B4 — `Sources/SongWorkbench/ONNXKaraokeVocalSeparationEngine.swift`. Mirrors DrumSep's
      shape but NOT its frequency packing: this graph carries its own STFT+ISTFT, so the
      predictor passes raw samples both ways. Lead = model output, backing = parent − lead.
- [x] B5 — Registered in `StemRefinementEngineFactory.production`, parent `vocals` →
      `.vocalLead`/`.vocalBacking`, macOS + Advanced Desktop only.
- [x] **Stitching — no new code.** The engine wraps `CoreMLStemSeparationEngine` with
      `segmentFrames 262144 / overlapFrames 65536` (quarter overlap, same ratio as the base
      engine), so the fixed 5.9 s graph is windowed and overlap-added by the SAME code path the
      six-stem separator uses. Verified on a full 225.6 s stem.
- [x] B6a — **Transcription cannot regress, structurally.**
      `StemRefinementPipelineEngine.separate` returns `stems: baseResult.stems`
      (`StemSeparation.swift:795-799`) — the flat `StemFiles` is passed through untouched, and
      refinement only adds entries to the hierarchical `stemSet`. ASR reads
      `stems?.resolved().vocals` (`AnalysisStage.swift:250`, `SongAnalysisPipeline.swift:371`),
      i.e. the parent. Same for the vocal-activity envelope and stem export.
- [x] B6b — Playback picks up children: `StemMixGraph.activeNodes` hides any parent that has
      children (`StemSeparation.swift:347-351`), and both `StemMixerChannelProjector` and
      `StemWaveformLaneProjector` project off that frontier.
- [x] Cache invalidation — `StemRecipeIdentity` hashes `refiners.map(\.cacheIdentity)`
      (`StemSeparation.swift:807`), so adding this refiner changes the recipe key and old stems
      are re-derived. No manual invalidation.
- [x] B7 — Reconstruction is EXACT by construction: lead + backing vs parent = **150.3 dB SDR**
      (residual rms 3.5e-09), because backing is the residual.
- [x] **Measured memory — 8.74 GB peak RSS** for the refiner alone on a 225.6 s stem, versus
      3.91 GB for the base six-stem pass. Runtime 256.2 s = **0.88x realtime** (slower than
      playback). **iPad verdict: impossible.** 8.74 GB is ~3x the ~3 GB per-process ceiling, and
      that is the cascade stage on its own. macOS-only, and expensive even there.
#### Independent re-verification 2026-07-31 (corrections to the figures above)

- **Real-audio parity is 94.1 dB, NOT 103.1 dB.** The earlier figure came from a fixed 60 s
  offset; `tools/karaoke_export/verify_export.py` deliberately scores the LOUDEST window, which
  is the harder test, and yields 94.1 dB. Synthetic-noise parity reproduces exactly at 91.8 dB.
  Both still clear the 79 dB demucs precedent — the conclusion stands, the number was
  window-dependent and should not be quoted as a single canonical value.
- **Suite is 742 tests, not 711** (0 failures either way).
- **"Only the .onnx changes" was overstated.** A replacement checkpoint also requires:
  `ONNXKaraokeVocalSeparationEngine.segmentFrames` (a compile-time constant that must equal the
  export chunk), the catalog `version`/`sha256`/`expectedSizeBytes`, and — if the model emits
  more than one stem — the transport-slot mapping. Everything else (refiner wiring, stitching,
  cache identity, downstream isolation) is genuinely artifact-agnostic.
- **Memory CONFIRMED and isolated:** Python ORT alone peaks at **7.04 GB** on this graph
  (plateaus after chunk 2), so the 8.74 GB measured under Swift is the model, not harness
  overhead.

- [ ] B8 — **QUALITY GATE FAILED. The checkpoint is the wrong kind of model.**

`anvuew/karaoke_bs_roformer` is a **vocals-vs-instrumental isolator, not a lead-vs-backing
model**, despite the repo name. Evidence:

| test | result | reading |
| --- | --- | --- |
| its own config | `instruments: ['Vocals','Instrumental']`, `target_instrument: Vocals` | trained to split vocals from music |
| output vs the base demucs vocals stem | energy ratio **0.847**, correlation **+0.931** | it reproduces the stem we already have |
| fed the FULL MIX | lead/residual corr **+0.021** | clean, in-distribution separation |
| fed the VOCALS STEM (our cascade) | lead/residual corr **+0.514** | heavy leakage — same voice split across both outputs |
| energy split on vocals stem | lead 28% / backing 72% | implausible for a lead isolate |
| band split | lead 24-31% uniformly across low/mid/high | no vocal-band concentration |

So the cascade feeds it out-of-distribution input, and what comes out is not lead vs backing.
**The lead-only fallback does not apply** — that assumed a good lead and a weak backing; here
neither output is a lead vocal.

- [ ] **NEXT — pick a genuine lead/backing checkpoint.** Look for one whose config declares
      lead/backing (or `instruments: ['lead','back']`-style) rather than Vocals/Instrumental, and
      verify it BEFORE exporting by checking (a) the config's instrument list and (b) that its
      output on a full mix is a strict *subset* of the vocals stem (energy ratio well below 1,
      not ~0.85). The mel-band `becruily` karaoke checkpoint (1.7 GB) is the next candidate.
      The export toolchain and the entire Swift integration are reusable as-is — only the
      artifact changes.
- [ ] Re-run B8 once a correct checkpoint is exported.
- [ ] Host the artifact: `ModelCatalog.karaokeVocals` currently carries a placeholder
      `example.invalid` download URL and the model was installed manually for this test. Real
      sha256/size ARE recorded. Not installable by a normal user yet.

#### Superseded checklist entries
- [ ] B4 — Add an ONNX predictor + engine modelled on `ONNXDrumPieceSeparationEngine.swift`
      (transport-slot mapping, `refinementOutputs` → `.vocalLead` / `.vocalBacking`).
- [ ] B5 — Register in `StemRefinementEngineFactory.production` behind Advanced Desktop.
- [ ] B6 — Verify mixer + waveform lanes show the children; verify transcription still reads the
      parent and its output is byte-identical to before.
- [ ] B7 — Reconstruction check: lead + backing should sum to the parent within tolerance. Per
      `tasks/lessons.md`, "finite WAV files were written" is NOT validation.
- [ ] B8 — Listening pass. Backing vocals are the weak side; ship lead-only if backing fails.

Reuses machinery that already ships: the refinement engine protocol, `StemSetManifest` hierarchy,
`StemMixerChannelProjector`, and the waveform lane projector all already handle child stems — the
DrumSep kick/snare/cymbals/toms refiner is the working precedent. Per `tasks/lessons.md`
(2026-07-28), do not describe advanced-stem infrastructure as delivered stem output: verify
catalog, factory registration, installed artifact, persisted manifest, and visible mixer channels
end to end.

Cross-cutting constraints from the findings doc still apply: iPad ~3 GB ceiling, per-combination
storage growth with no eviction policy, and licensing (base model is CC-BY-NC).

---

# Per-Instrument Stem Algorithm Selection (2026-07-29)

Investigation findings: `tasks/stem-algorithm-selection-findings.md`.

**Thesis under test:** guitar separation quality is the lever on chord accuracy
(htdemucs_6s isolates guitar ~5 dB; BS-RoFormer 6-stem ~9 dB, and chords read the guitar
stem first). **Counter-thesis we must disprove before spending:** the literature is mixed —
there is a published case where Demucs preprocessing made a chord model *worse*, and SDR does
not predict downstream accuracy. So Phase 0 measures real chord/note output, never separation
metrics, and Phase 1 does not start until Phase 0 reports a number.

## Phase 0 — Validation harness (offline, additive, no shipping behavior change)

Goal: measure whether the chord source stem actually moves chord accuracy, before investing
in any new model.

- [x] **Harness host DECIDED: the existing test target.** Every declaration in `Sources/` is
      `internal` — `grep public` returns **zero** — so a standalone `Benchmarks/Tools` binary
      or a new SPM executable target cannot reach the analysis code without restructuring
      `Package.swift` into a library. The test target already has `@testable import` access in
      all 65 files, and `Project.swift:132` globs `Tests/SongWorkbenchTests/**` so a new file
      is picked up by SwiftPM *and* Tuist for free. (`Benchmarks/Tools/native_analysis_benchmark.swift`
      is a stale template — it calls internal types it does not define and the documented bare
      `xcrun swiftc` recipe cannot compile it.)
- [x] **Precedent found:** `Tests/SongWorkbenchTests/ChordDecoderOfflineValidationTests.swift`
      is already an env-gated (`SW_OFFLINE_VALIDATION=1`) offline A/B harness that reads the
      app container's analysis cache and diffs two decoder configurations. Same shape as what
      we need — swap "decoder config A/B" for "stem source A/B".
- [ ] **ACCEPTED COST — harness mirrors rather than calls `HarmonyStage`.** `HarmonyStage.run`
      requires a full `AnalysisStageContext` (request, document, digest closure, cache, stem
      engine, refiners, transcription factory, ChordPro builder, progress closure —
      `AnalysisStage.swift:32-45`), which is not practical to construct offline. The harness
      therefore re-implements the ~40-line stage 1-8 sequence. **This can silently drift from
      production.** Mitigation: a prominent comment pinning the mirrored line range. Upgrade
      path if it bites: extract the sequence into one shared internal function both call —
      deliberately deferred, since that is a change to shipping code.
- [ ] **Hold the beat grid FIXED across arms.** The grid is derived from the DRUMS stem
      (`DrumBeatGrid`, `AnalysisStage.swift:747`) and every downstream step — the 0.8-beat
      filter, onset snapping, consensus — quantizes to it. Compute `beatTimes` once and inject
      the identical grid into all three arms, or the experiment confounds chroma source with
      grid drift and measures nothing.
- [ ] Arms: chords derived from `guitar` stem vs `accompaniment` stem vs full mix. (These are
      the real branches of `HarmonyAudioSourceSelector`, `HarmonyAudioSource.swift:35-40`.)
- [ ] Also run the bass-note arm: `BassLineAnalyzer` on the `bass` stem vs full mix, since
      bass onsets feed back into the chord decoder as switch cues (`AnalysisStage.swift:783`).
- [x] **Ground-truth question RESOLVED.** A full bidirectional ChordPro parser already exists
      (`ChordProDocument.init(parsing:)` → `ChordProParser.parse`, `ChordProDocument.swift:200`),
      and `ChordProChord` is structured (root / suffix / slash bass, with `pitchClass(for:)`)
      — so labels compare as integers, not strings. Timing IS recoverable: the builder emits
      an `{x_chord_times: …}` directive before every row and
      `ChordProChordTimeCarrier.parse(_:)` (`ChordProDraftBuilder.swift:809-824`) already
      returns `(time, label)` pairs. **No new parsing work needed.**
- [ ] **But treat that ground truth as a LABEL oracle only, never a timing oracle.** Three
      caveats: (1) the carrier is deliberately not wired into any import path
      (`ChordProDraftBuilder.swift:795-798`) — it exists as a round-trip proof; (2) timing
      survives only in files this app's builder generated, and only if the user did not delete
      the directive lines — a hand-authored or foreign chart yields chord ORDER only; (3) the
      timestamps in a *user-reviewed* chart were still produced by the decoder, so scoring
      timing against them is **circular**. Compare labels on a shared time grid; do not report
      timing accuracy against a reviewed chart.
- [ ] There is **no labeled corpus and no audio at all in the repo** — zero `.wav/.mp3/.m4a`
      outside `.build`, and `tasks/backlog.md:85` states the catalog "is original songs with
      no ground truth." All existing test audio is synthesized in Swift. So the harness must
      (a) synthesize its own smoke-test song for the always-on path, and (b) take real songs by
      path from the environment. Never commit audio.
- [ ] Report **cross-arm agreement** (pairwise % of time two arms emit the same chord) as well
      as accuracy — it needs no labels, so the harness produces a usable signal on any song
      immediately, before any reviewed chart exists.
- [ ] Metrics, reported per arm:
      - time-weighted root accuracy (fraction of song duration with the correct root)
      - time-weighted full accuracy (root + quality)
      - event count vs ground truth (over/under-segmentation)
      - **vocabulary ceiling:** % of ground-truth chords not representable in the 5-quality
        vocabulary (`ChordQuality` is exactly major/minor/major7/minor7/dominant7,
        `ChordClassification.swift:4-10`). If root accuracy is high but full accuracy is
        capped near this ceiling, the vocabulary is the binding constraint and Phase 1 is the
        wrong investment — say so and stop.
- [ ] Emit a comparison table in the style of `Benchmarks/CHORD_ANALYSIS.md`; write results to
      `Benchmarks/STEM_SOURCE_CHORD_ACCURACY.md`.
- [ ] Song set: start with the existing fixed 60 s benchmark excerpt (sha256
      `47881ae9…f3803`, already shared by `CHORD_ANALYSIS.md` and `STEM_SEPARATION.md`), then
      extend to a small set of the user's reviewed songs. Songs live outside the repo — the
      harness must take a path and skip cleanly when absent, never commit audio.
- [ ] Harness must run with ZERO changes to shipping pipeline behavior. Additive files only.

### Phase 0 acceptance criteria

- [x] Harness runs end-to-end and emits a three-arm comparison (synthetic song; real-song run
      still pending — see Review).
- [x] Identical beat grid across arms is asserted, not assumed.
- [x] Result reports both root and full accuracy plus the vocabulary-ceiling figure.
- [x] `git status` confirms no shipping source file changed.

### Phase 0 review (2026-07-29 — scaffold complete, not yet run on real audio)

Scaffolded `Tests/SongWorkbenchTests/StemSourceChordAccuracyTests.swift` (586 lines, one new
file, zero `Sources/` changes). Two tests: an always-on synthetic 4-bar C-F-G-C smoke test,
and `testRealSongThreeArmComparison` gated on `SW_STEM_SOURCE_EVAL=1` plus
`SW_STEM_SOURCE_EVAL_DIR` / `SW_STEM_SOURCE_EVAL_MIX` / optional `SW_STEM_SOURCE_EVAL_CHART`.
Verified independently of the subagent: `swift test --filter StemSourceChordAccuracyTests`
passes (4.3 s, 1 passed / 1 skipped), `swift format lint --strict` clean, `git status` shows
exactly one added file against the pre-work baseline.

**The synthetic numbers (99% on every arm) are evidence of NOTHING** beyond working plumbing —
sine triads on a hard-coded progression are trivially separable. There is no accuracy
assertion, by design.

Design notes that matter for interpreting the real run:

- **`instrumentOnsets` deliberately varies per arm.** The shared grid, bass notes, and meter
  are held identical, but each arm derives its own onsets from its own audio — because that is
  what production does (`AnalysisStage.swift:766-771` reads onsets from the guitar/other stem).
  So the experiment isolates *audio source*, not *chroma alone*. That is the faithful
  comparison, but it means a win could come from cleaner onsets rather than cleaner chroma.
  If the real run shows a guitar-arm win, re-run with onsets pinned to decide which.
- **The shared grid is anchored to arm 0's bpm.** `DrumBeatGrid` needs a tempo prior and the
  drums stem gives only onsets, so production takes bpm from the harmony result; the harness
  mirrors that using the FIRST arm's bpm. Keep `guitar` first across runs or the grid can shift
  between invocations.
- **Vocabulary ceiling is count-weighted, not time-weighted.** A rare `sus4` held for 30 s is
  under-counted relative to its effect on time-weighted full accuracy. If full accuracy lands
  noticeably below `1 − ceiling`, check this before blaming the stem.
- **Slash bass is stripped** (`C/G` scores as C major), so inversions do not count against the
  ceiling. Marked with a `ponytail:` comment and an upgrade path.

Remaining before the decision gate:

- [x] Run against real separated stems — done, 25 songs / 5,527.9 s from the app container.
- [x] Extend to a small song set — batch mode added (`testBatchAgreementAcrossSeparatedSongs`,
      gated on `SW_STEM_BATCH=1`). Ran 742.6 s, 1 test, 0 failures.
- [x] Write `Benchmarks/STEM_SOURCE_CHORD_ACCURACY.md` from the real results — done.
- [ ] Capture current 6-stem ONNX CPU separation timing (still missing — this run reused
      existing stems and never invoked the separator, so it produced no timing datum).

### Phase 0 RESULT (2026-07-29) — agreement-only, no ground truth

| pair | songs | agree % | root div % | qual div % |
| --- | ---: | ---: | ---: | ---: |
| guitar vs accompaniment | 25 | 79.8 | 15.1 | 5.0 |
| guitar vs fullmix | 5 | 49.8 | 36.7 | 13.5 |
| accompaniment vs fullmix | 5 | 53.1 | 34.7 | 12.2 |

Emitted quality, guitar arm: major 71.8 / minor 20.8 / maj7 6.8 / **m7 0.0** / dom7 0.6.

**DECISION GATE: HELD. Do not start Phase 1 yet.**

Sensitivity is proven — 20 % of song duration changes between guitar and accompaniment, 15.1 %
of it at root level, despite accompaniment *containing* the guitar stem. But high sensitivity is
precisely the precondition for the published failure mode (separation preprocessing degrading a
chord model), and these numbers cannot say which arm is right. Phase 1 would buy a better guitar
stem with no way to evaluate it.

Two findings that redirect the next step:

1. **Ground truth is now a hard prerequisite, not a nice-to-have.** Phase 1's A/B needs it too.
   3-5 hand-verified songs converts this harness from a sensitivity meter to an accuracy meter.
2. **The vocabulary may be the real ceiling.** `m7` is emitted 0.0 % of the time across 92
   minutes; 92.6 % of detected time is a plain triad. No separation improvement recovers a chord
   the classifier will not emit. Worth pricing a vocabulary/classifier experiment against Phase 1
   before committing to either.

- [x] **Ground-truth mode RUN (2026-07-29).** Independent charts found in `~/Documents/CCS
      Files 2` (NOT the app's `draft` documents, and NOT `Desktop/Settle Down.cho`, which is a
      SongWorkbench export and would be circular). Charts are UNTIMED, so scoring is LCS over
      collapsed chord sequences; charts are capo-shape and are transposed to concert pitch.

### Phase 0 FINAL RESULT — accuracy mode (3 songs)

| arm | mean root seq % | mean full seq % |
| --- | ---: | ---: |
| guitar | 77.1 | 72.6 |
| accompaniment | **77.1** | **73.2** |
| fullmix | 76.4 | 65.3 |

Vocabulary ceiling MEASURED: **1.4 % out-of-vocabulary** over 2,361 chord tokens in 37 charts
(0.0 % on all three scored songs). The 5-quality vocabulary covers 98.6 % of the repertoire.

**DECISION: Phase 1 is NO-GO on current evidence.**

- Guitar and accompaniment tie on root accuracy to the decimal (77.1 / 77.1); accompaniment is
  marginally ahead on full quality. The 15.1 % root divergence from the sensitivity run buys no
  accuracy. Output moves; quality does not. The premise "better guitar stem → better chords"
  is not supported.
- Separation vs no separation IS worth its keep (+7.3 pts full-quality over full mix) — but
  that is the shipped benefit, not an argument for a second model.
- **Vocabulary hypothesis REFUTED** (1.4 % OOV). It is not the ceiling.
- **The real levers are stem-independent:** (1) seventh confusion — `maj7` emitted 6.8 % where
  ground truth has literally 0, `m7` emitted 0.0 % where truth has 2.8 %; (2) over-segmentation
  — 1.1× to 3.6× more chord events than the charts carry.

Caveats bounding this: N=3, only ONE a Reviewed chart; LCS is recall-only so absolute levels are
inflated (the guitar-vs-accompaniment comparison is unaffected — near-identical sequence
lengths — but fullmix over-detects more, so separation's edge is understated).

- [ ] **NEXT (supersedes Phase 1):** attack seventh misclassification and over-segmentation,
      both stem-independent and cheaper than a new separation model.
- [ ] Add a precision term to the scorer (F1, not recall-only) so over-segmentation is
      penalised rather than rewarded.
- [ ] Get more Reviewed-tier charts; N=1 at the strong tier cannot carry a decision this size.
- [ ] Capture 6-stem ONNX CPU separation timing (still missing — both runs reused existing
      stems and never invoked the separator).
- [ ] **Decision gate:** Phase 1 starts only if the guitar arm beats the others by a margin
      that survives the song count. A null result is a valid, valuable outcome — it saves the
      entire Phase 1/2 spend.

## Phase 0b — Seventh misclassification: ROOT-CAUSED, fix measured, NOT SHIPPED (2026-07-30)

Attacks lever (1) from the Phase 0 FINAL RESULT. Stem-independent, as predicted.

- [x] **Stage-attribution diagnostic built and run.**
      `Tests/SongWorkbenchTests/ChordQualityStageAttributionTests.swift` (new, additive, zero
      `Sources/` changes), gated `SW_CHORD_STAGE_ATTR=1` + `SW_CHORD_STAGE_ATTR_OUT=<path>`.
      Replays the container's cached harmony analyses through every stage of the real decode
      path (S0 cached frames -> S1 `refineObservations` -> S2 confidence floor -> S3 Viterbi ->
      S4 `mergeSameRootExtensions` -> S5 `decoder.events` cross-check -> S6 event re-root ->
      S7 onset snap -> S8 duration filter -> S9 `ChorusChordConsensus`), tallying the
      chord-quality distribution after each. S5 asserts S1-S4 replicated the real entry point.

### ROOT CAUSE — `BassInformedChordRefiner.refineObservations` (ChordClassification.swift:251-289)

**One stage produces the entire defect.** Every stage after S1 is quality-neutral (Viterbi,
merge, snap, duration filter, and chorus consensus each move 0-2 labels).

| song | S0 maj7 frames | S1 maj7 frames | `major->major7` rewrites | inflation |
| --- | ---: | ---: | ---: | ---: |
| 394f79dd | 8 (0.3 %) | 336 (11.8 %) | 327 | 42x |
| 3af767ca | 17 (0.8 %) | 248 (11.8 %) | 231 | 15x |
| 77e2f562 | 5 (0.2 %) | 441 (13.7 %) | 436 | 88x |
| 89c28733 | 9 (0.4 %) | 257 (10.3 %) | 248 | 29x |

Two independent defects in the same 4 lines:

1. **First-match, not argmax.** `.minor` returns as soon as it shares 2 tones, so a seventh
   sharing all 3 is never considered — and `.minor7` is absent from the candidate list entirely,
   so it can never be produced at any time. A Cm7 (C-Eb-G-Bb) is note-identical to Eb6, so the
   chroma classifier hears Eb major; under a C bass the scan emits a bare `Cm`.
2. **Un-normalised threshold.** A flat "shares >= 2 tones" bar is easier for a 4-note seventh to
   clear than for a 3-note triad, purely because it has more tones to clear it with. B major
   under a G bass shares only {B, F#} with Gmaj7 — promoted anyway.

**`ChorusChordConsensus` is EXONERATED** (1-2 label rewrites/song), but note it runs in
production (`AnalysisStage.swift:847`) and `StemSourceChordAccuracyTests` skips it (:574) — so
the 6.8 % harness figure and the persisted x20 `Gmaj7` count describe DIFFERENT pipelines.
The new diagnostic covers both.

### Candidate fix — measured, then REVERTED. Preserved at `tasks/seventh-reroot-fix.patch`

Argmax over all five qualities; threshold normalised to the CANDIDATE's own size (triad 2-of-3,
seventh 3-of-4); ties to the plain triad. Validated by simulating all three rules against the
same frames in the diagnostic, with the shipping rule reproduced exactly (`faithful=true`) to
prove the simulation trustworthy before any code changed.

Event-level distribution, before -> after (ground truth: maj7 **0 %**, m7 **2.8 %**):

| song | maj7 | m7 |
| --- | --- | --- |
| 394f79dd | 9.8 % -> **2.7 %** | 0.0 % -> **6.7 %** |
| 3af767ca | 7.8 % -> **1.5 %** | 0.0 % -> **3.1 %** |
| 77e2f562 | 15.4 % -> **1.5 %** | 0.0 % -> **3.7 %** |

**But downstream F1 did not follow** (3 charted songs, guitar arm — the arm production uses):

| metric | before | after |
| --- | ---: | ---: |
| mean root F1 | 51.5 | 52.0 |
| mean full F1 | 46.9 | 46.6 |
| mean over-seg ratio | 2.07 | 2.11 |

By chart tier it splits hard: **reviewed 35.2 -> 41.8 root F1 (+6.6)**, transcribed 76.0 -> 71.7
(-4.3), automated 43.3 -> 42.5 (-0.8). The accompaniment arm fell on both (51.8 -> 50.9,
47.4 -> 46.6).

**DECISION: SHIPPED 2026-07-30 on Eric's explicit call** (`apply`). It was initially reverted
pending review, for two reasons — recorded here because they remain the honest caveats:

1. The plan's own bar was "maj7 -> ~0 % AND m7 -> ~2.8 % AND F1 does not fall." The distribution
   half passed decisively; the F1 half is a wash, not a gain.
2. It breaks two EXISTING tests that encode the old rule as deliberate, documented intent:
   `testBassRerootRecoversUpperStructureSeventh` (C# over F# shares only 2 tones with F#maj7 —
   the old >= 2 bar promoted it on purpose; the new 3-of-4 bar rejects it) and
   `testBassRerootRecoversChordMaskedByChromaConfusion` (expects `Ab`, argmax prefers `Abmaj7`,
   which is what C-Eb-G over an Ab bass literally is). **The old >= 2 threshold IS both the
   deliberate upper-structure feature and the maj7 inflation — you cannot keep one without the
   other.** Deleting a tested feature on N=3 with no F1 gain is not a call to make silently.

- [x] **DECISION MADE — SHIPPED.** `tasks/seventh-reroot-fix.patch` applied to
      `ChordClassification.swift` (kept on disk as the record of what changed). The two affected
      tests in `ChordTimelineDecoderTests.swift` were rewritten to encode the new intent rather
      than deleted:
      - `testBassRerootRecoversUpperStructureSeventh` -> **`testBassRerootRejectsTwoToneSeventhCoincidence`**
        (C# over an F# bass now stays `C#`; the comment carries the 15-88x inflation measurement
        that justifies rejecting a two-tone promotion).
      - **`testBassRerootRecoversMinorSeventhMaskedAsRelativeMajor`** added — Eb-major frames over
        a C bass now decode to `Cm7`, the case the first-match scan could never reach.
      - `testBassRerootRecoversChordMaskedByChromaConfusion` now expects `Abmaj7` rather than a
        bare `Ab`. The ROOT recovery this test exists to protect still holds; C-Eb-G over an Ab
        bass genuinely spells Ab-C-Eb-G, and the seventh explains the G that the triad leaves
        unaccounted for.
      Full suite green (`TESTEXIT=0`), `swift format lint --strict` clean.
- [ ] **No cache invalidation was needed** — `BassInformedChordRefiner` runs at DECODE time,
      downstream of the `native-vdsp-beat-chroma` v7 frame cache, whose contents are unchanged.
      But existing per-song documents still hold chord timelines decoded under the old rule:
      **re-analyze a song to see the new labels.**
- [ ] Re-measure once more Reviewed-tier charts exist. Shipping on a flat-F1 result at N=3 was a
      judgement call about which evidence to trust (mechanism correctness + the one Reviewed
      chart's +6.6 root F1), not a demonstrated accuracy win.
- [ ] Either way, get more Reviewed-tier charts first. N=1 at the strong tier still cannot carry
      this, exactly as the Phase 0 review said.
- [ ] Over-segmentation (lever 2) untouched — over-seg ratio is 1.1x-3.7x and dominates F1 on
      the automated-tier song (100 % recall, 27 % precision). Likely the bigger remaining win.

### Reproduce

```sh
# stage attribution (no ground truth needed)
SW_CHORD_STAGE_ATTR=1 SW_CHORD_STAGE_ATTR_OUT=/tmp/stage_attr.txt \
  swift test --filter ChordQualityStageAttributionTests

# accuracy, before/after a fix
SW_STEM_GT=1 SW_STEM_GT_MANIFEST=/tmp/gt_manifest.tsv SW_STEM_GT_OUT=/tmp/gt_before.txt \
  swift test --jobs 1 --filter testGroundTruthSequenceAccuracy
```

`gt_manifest.tsv` rows (mix column intentionally empty -> guitar + accompaniment arms only;
this reproduces the recorded 77.1/77.1 root recall exactly):
`<stemDirHash>\t<container>/Analysis/Stems/<stemDirHash>\t\t<chart .cho>\t<tier>`
with `ChordPro Catalog/Summertime's here with you.cho` (reviewed — NOT the top-level
`Somertime's Here with You.cho`, which is a different, best-effort chart), `Key West Bar.cho`
(transcribed), `ChordPro Catalog/Flip Flops and Barbeque.cho` (automated).

## Phase 0c — Over-segmentation: NO-GO, and the premise is largely an artifact (2026-07-30)

Attacks lever (2) from the Phase 0 FINAL RESULT. **Result: do not tune, and re-frame the lever.**

- [x] **Harness parameterised for sweeps.** `StemSourceChordAccuracyTests.tunedDecoder()` reads
      `SW_CHORD_SWITCH_PENALTY`, `SW_CHORD_WEAK_BEAT_FACTOR`, `SW_CHORD_ONSET_PENALTY_FACTOR`,
      `SW_CHORD_MIN_PENALTY_FRACTION`; the duration filter reads `SW_CHORD_MIN_BEAT_FRACTION`.
      Unset = shipping defaults, verified byte-identical to the pre-change run
      (root F1 52.0 / full 46.6 / over-seg 2.11). The active knobs are echoed into the report as
      a `tuning=` line so a sweep's rows are self-identifying.

### Sweep results (guitar arm, 3 songs, mean)

| config | root F1 | full F1 | root prec | root recall | over-seg |
| --- | ---: | ---: | ---: | ---: | ---: |
| **baseline** (switch 1.5, weak 1.3, minbeat 0.8) | 52.0 | 46.6 | 42.0 | **78.2** | 2.11 |
| switch 2.0 | 52.0 | 47.6 | 42.7 | 75.4 | 1.96 |
| switch 2.5 | 51.9 | 47.0 | 43.5 | 72.9 | 1.81 |
| switch 3.0 | 52.7 | 48.2 | 44.8 | 71.9 | **1.72** |
| weak 1.8 | **50.6** | 46.4 | 41.2 | 75.9 | 2.06 |
| weak 2.4 | 52.6 | 47.5 | 43.5 | 76.8 | 1.97 |
| minbeat 1.0 | 52.2 | 47.2 | 43.6 | 76.0 | 2.00 |
| minbeat 1.25 | **52.9** | 48.1 | **46.1** | 73.1 | 1.81 |
| weak 1.8 + minbeat 1.0 | 51.0 | 46.7 | 42.9 | 74.2 | 1.96 |

**DECISION: NO-GO. No parameter changed.** Three reasons:

1. **Every knob slides along the precision/recall curve; none moves it.** Every config that cuts
   over-segmentation pays for it in recall, roughly 1:1. Total root-F1 spread across the whole
   grid is 50.6-52.9 — about two points.
2. **The response is non-monotonic, which at N=3 means noise.** `weakBeatFactor` 1.3 -> 1.8 makes
   root F1 *worse* (52.0 -> 50.6), then 1.8 -> 2.4 makes it *better* than baseline (52.6). A
   monotone knob cannot really produce that; the corpus cannot resolve differences of this size.
   The combined config is also worse than either of its parts alone. Treat every delta in the
   table above as within noise.
3. **Eric has already listened.** `ChordTimelineDecoder`'s own comments record switch penalty 2.5
   "rode the tonic straight through the reference song's real mid-verse changes (author-confirmed)"
   and 2.0 "absorbed one-beat passing chords ... field reports confirmed many real changes missed."
   The sweep reproduces exactly that as recall falling 78.2 -> 71.9. A metric gain of ~1 F1 point
   at N=3 is not evidence against direct listening — and missing a real change is worse for a
   practice tool than showing an extra one, since a player can ignore a spurious chord but cannot
   play one that was never displayed.

### The premise itself needs re-framing

Over-segmentation is **not uniform across the corpus — it tracks chart granularity, inversely to
chart quality**:

| song | tier | truth chords | detected | over-seg |
| --- | --- | ---: | ---: | ---: |
| 1c2f744d326b | **reviewed** | 75 | 83 | **1.11** |
| 3ba46cbaba9c | transcribed | 84 | 128 | 1.52 |
| f1145c16433f | **automated** | **34** | 126 | **3.71** |

On the ONE human-authored performance chart the detector is within **11 %** of the chart's own
event count — essentially correct. The 3.71x figure comes from a chart carrying **34 chords for an
entire song**, i.e. a sparse skeleton rather than a per-bar chart; that measures the chart's
granularity, not the detector's error. Tightening to `minbeat 1.25` drives the Reviewed song to
over-seg **0.83** — actively UNDER-segmenting — and its root F1 down 41.8 -> 38.0.

**So the recorded "over-segmentation 1.1x to 3.6x" lever overstates the problem** by averaging
charts of wildly different granularity. It should not be treated as an open defect on this
evidence.

- [ ] **Prerequisite before any further chord tuning: more Reviewed-tier charts.** This is now
      demonstrated rather than asserted — the non-monotonic sweep response is the proof that N=3
      cannot resolve the effect sizes in play. Every remaining chord-accuracy question is blocked
      on the corpus, not on ideas.
- [ ] If over-segmentation is still suspected after that, measure it against Reviewed charts only,
      and prefer a lever that uses evidence the decoder currently ignores over another threshold.

## Phase 1 — BS-RoFormer 6-stem guitar as a selectable alternate

Only after Phase 0 clears the gate.

- [ ] Fill the already-declared-but-empty guitar slot: `StemID.guitarLead`/`.guitarRhythm`
      exist (`StemSeparation.swift:91-92`), and the factory documents guitar as blocked
      "until a verified model artifact exists" (`SongAnalysisPipelineFactory.swift:164`).
- [ ] **Design fork — resolve first.** An alternate guitar model is not a refiner of the
      guitar stem; it reads the ORIGINAL mix and produces a competing guitar stem.
      `NativeStemRefinementEngine` feeds a refiner only its PARENT stem
      (`StemSeparation.swift:483-500`), so one of: (a) register it as an alternate BASE
      engine, (b) extend the native refiner to accept the original mix as parent, or (c) use
      `ExternalStemRefinementEngine` — which already exists, already takes `request.inputURL`
      (the original mix), and is macOS-only by design.
- [ ] **Evaluate via the external adapter before building a native path.** `audio-separator`
      behind `ExternalStemRefinementEngine` gets a real A/B with no ONNX export work. Per
      `tasks/lessons.md`, a subprocess/Python integration is an optional macOS extension and
      NEVER the iPad path — so this is an evaluation vehicle, not the shipping design. Only
      port to a native ONNX predictor if the A/B wins.
- [ ] Verify a BS-RoFormer ONNX export actually exists with a checkable license and checksum
      before promising the native path. Do not register a catalog entry without both.
- [ ] Register `ModelPackageDescriptor` with license, sha256, size, entry point — and add it
      to `ModelCatalog.optionalRefinementIDs` or it will **block first-run onboarding for
      every user** (`AnalysisCapabilityProfile.requiresModelPackage`).
- [ ] A/B its chord output against the htdemucs_6s guitar on the SAME songs using the Phase 0
      harness. Cache keys separate the two arms automatically via `StemRecipeIdentity`
      (`StemSeparation.swift:138`) — no manual invalidation needed.
- [ ] Per `tasks/lessons.md`: do not accept "finite WAV files were written" as validation.
      Verify reconstruction error, headroom/clipping, and source mapping.

## Phase 2 — Per-song, per-instrument selection (data model + UI)

- [ ] **Gap 1 — plumbing.** `SongAnalysisCoordinator.makePipeline` is a zero-argument closure
      (`SongAnalysisCoordinator.swift:14`) and `SongAnalysisPipelineRequest` has no separation
      config. Thread a per-run recipe through, following the existing `transcriptionMode` /
      `transcriptionDecodeRate` precedent (`AppModel.swift:1016`).
- [ ] **Gap 2 — availability.** Engine choice is entangled with `AnalysisCapabilityProfile`
      tiers plus a macOS-only `UserDefaults` toggle plus the onboarding gate. A per-song
      choice must COMPOSE with tiers (iPad cannot offer what it cannot run), not bypass them.
- [ ] **Gap 3 — THE SHARP EDGE.** Downstream reads the flat legacy `StemFiles`
      (`stems.guitar`, `stems.bass`) rather than the hierarchical `StemSetManifest` — see
      `HarmonyAudioSource.swift:35`, `AnalysisStage.swift:673,767`. Either an alternate guitar
      lands at `guitar.wav`, or `HarmonyAudioSourceSelector` and friends move onto `StemID`.
      Decide deliberately; this is where a per-instrument feature either stays clean or rots.
- [ ] Persistence: `PracticeSettings` (`PracticeProject.swift:15`) is the natural home — user
      choices, and its hand-written `init(from:)` already decodes-if-present with defaults, so
      no schema migration. (`SongAnalysisDocument` is results, and already records what
      produced the stems via `stemSet.recipeIdentity`.)
- [ ] UI: extend the Models popover (`AnalysisWorkspaceView.swift:409`, where the "Advanced
      stem refinement" toggle already lives) and/or a per-song control near Analyze.
- [ ] **Consider the counter-design.** The per-song transcription-mode picker was deliberately
      REMOVED in backlog #11 in favor of "run every installed mode, let the blend UI be the
      tuning" (`AppModel.swift:789-800, 824`). Decide consciously whether per-song algorithm
      choice is different in kind, or whether the same shape applies here. A picker nobody
      touches is worse than a good default.
- [ ] Storage policy: every algorithm combination is a full extra stem set on disk (6 ×
      stereo float32 WAV per song). Per-song × per-instrument multiplies that and there is NO
      eviction policy today. Decide one before shipping selection.

## Phase 3 — Expansion by feasibility

- [ ] Lead vs backing vocals — lead is strong, backing is rough. Ship lead-only if backing
      does not clear a listening bar.
- [ ] Per-drum-piece cascade — already feasible; DrumSep ships today (macOS + Advanced).
      Mostly a promotion/validation exercise, not new modeling.
- [ ] **Explicitly deferred as NOT FEASIBLE with open weights** (record the reason so this is
      not re-litigated): lead vs rhythm guitar (closed/Moises only); distinct synth stem
      (~2 dB, not usable). Revisit only if open weights appear.

## Cross-cutting constraints and risks

- [ ] **iPad ~3 GB per-process ceiling.** Already forced the 2.5 s bundled re-export (7.8 s
      OOMs, 3.5 s tipped the cap). Running multiple separation models per song on iPad may be
      impossible. Any per-song selection MUST degrade to a single model on iPad.
- [ ] **No timing data for the current 6-stem ONNX CPU path.** The only recorded benchmark is
      the older 4-stem CoreML FP16 engine (`Benchmarks/STEM_SEPARATION.md`). Measure the
      current path before promising switchable models — capture it during Phase 0.
- [ ] **Licensing.** The current base model is CC-BY-NC-4.0 (non-commercial), and the best
      RoFormer weights are community-trained with unclear terms. Audit both before any
      commercial ship. This is a pre-existing exposure, not one this feature creates.
- [ ] **Do not trust `BUILD SUCCEEDED`** (`tasks/lessons.md`, 2026-07-05): CLI `xcodebuild`
      can write to a different DerivedData folder than the running app.
- [ ] Serialize: no second code session on this repo. In-session subagents only, disjoint file
      scopes, and `git status` verified after every subagent reports.

---

# Drum Piece Refinement Registration (2026-07-28)

## Plan

- [x] Register a verified DrumSep ONNX package in `ModelCatalog` (kick/snare/cymbals/toms).
- [x] Add Hybrid-Demucs-compatible frequency features + ONNX drum-piece predictor/engine.
- [x] Wire production `StemRefinementEngineFactory` so Advanced Desktop injects a drums
      parent → `drums.kick|snare|cymbals|toms` refiner when the package is installed.
- [x] Keep default Desktop Full / iPad Reduced profiles unchanged; Advanced remains opt-in.
- [x] Show DrumSep as an optional Models package on desktop without blocking onboarding.
- [x] Document guitar lead/rhythm as blocked until a verified model artifact exists.
- [x] **HARD:** Waveforms card shows a lane for every active frontier stem (including
      refined drum/guitar children), with labels/colors consistent with the mixer.
- [x] **HARD:** Stem Mix volume UI exposes mute/solo/gain/pan for every active frontier
      stem (already channel-projected; verify + regression-test with drum children).
- [x] Add focused tests for catalog/factory/STFT shape + waveform/mixer frontier; run
      stem/factory suite + format check.

## Acceptance criteria

- [x] Catalog entry has license, checksum, size, and entry point for Gridshift DrumSep ONNX.
- [x] Advanced Desktop + installed DrumSep produces a native drum-piece refiner in factory assembly.
- [x] Default desktop/iPad profiles still request no refiners.
- [x] Guitar lead/rhythm remains catalog-unregistered with an explicit follow-up decision.
- [x] When a refined manifest is active, the Stem Mix rail shows child channels (not the
      parent) with working mute/solo/gain/pan, matching existing six-stem UX.
- [x] When a refined manifest is active, the Waveforms card stacks one labeled lane per
      active frontier stem (including `drums.kick` etc.), not only the six `StemKind`s.
- [x] Verification evidence recorded below.

## Review

- Registered `ModelCatalog.drumsep` (Gridshift `drumsep-onnx`, MIT, sha256
  `ecb8509383ccd437…`, 335 071 223 bytes) as an optional refinement package.
- Added `HybridDemucsFrequencyFeatures`, `ONNXDrumPieceSeparationEngine`, and
  `StemRefinementEngineFactory.production` mapping drums → kick/snare/cymbals/toms.
- Advanced Desktop is opt-in via Models → “Advanced stem refinement” (UserDefaults);
  AppModel always assembles with `.production` and `AnalysisCapabilityProfile.current`.
- **Mixer:** `StemMixerChannelProjector` already used the active frontier; added
  scribble short-names for Kick/Snare/Cymbals/Toms and regression coverage.
- **Waveforms:** `stemWaveforms` is now `[StemWaveformLaneModel]` driven by
  `StemWaveformLaneProjector.targets(for:)` (same frontier as the mixer). ContentView
  labels/colors use `StemID.laneColor`; ChordPro stem strips use
  `stemWaveformEnvelope(for:)`.
- Guitar lead/rhythm: taxonomy IDs exist; no verified public ONNX registered yet —
  blocked on model choice (see decision below).
- Verification: focused suite 39 passed (`StemMixerTests`,
  `SongAnalysisPipelineFactoryTests`, `ModelPackageManagerTests`,
  `HybridDemucsFrequencyFeaturesTests`, `StemSeparationTests`).
- Follow-up before calling drum pieces “listening-ready”: install DrumSep, enable
  Advanced, re-analyze a song, and validate reconstruction/listening quality (STFT
  packing still needs PyTorch golden parity).

## Decision needed (guitar)

No verified lead/rhythm guitar ONNX is registered. Options: (a) wait for a community
model with license/checksum, (b) heuristic split (not ML), (c) external Python
refiner. Drum pieces can ship independently.

---

# Degenerate Lyric Lead-In Split (2026-07-28)

## Plan

- [x] Trace Doc Holiday lines 10/11 through persisted segment and word timing.
- [x] Identify the grouping safeguard that preserves the invalid boundary.
- [x] Add a regression for a zero-duration multiword lead-in followed
  immediately by the rest of its phrase.
- [x] Merge only timing-degenerate lead-ins without absorbing legitimate short
  interjections.
- [x] Verify Doc Holiday regrouping, focused/full tests, strict formatting,
  diff checks, and macOS/iPad builds.

## Review

- Doc Holiday line 10 persisted as `Ain't no` with both words and the whole
  segment timed `65.84-65.84`; line 11 began `runner` at `65.89`. The 50 ms
  boundary had no acoustic or musical basis.
- Root cause: the short-fragment merge deliberately protects lines ending in
  `no` as possible standalone interjections. That lexical safeguard ignored
  stronger evidence from the impossible zero-duration multiword timing.
- The grouper now merges a multiword lead-in only when its total duration is at
  most 50 ms and the continuation begins within 250 ms. Normally timed short
  interjections remain protected.
- Bumped the transcription grouping version to
  `grouping-44-degenerate-leadin-merge`; existing projects also migrate through
  the unconditional load-time regrouping pass without re-transcription.
- Live verification: Doc Holiday now persists line 10 as
  `Ain't no runner from the debt you owe.` at `65.84-69.30`, and the former
  line 12 is naturally line 11.
- Verification: all 55 transcription tests passed; full `swift test` passed
  695 tests with 7 environment-dependent skips; strict recursive Swift format
  lint and `git diff --check` passed; macOS Debug and generic physical-device
  iPad Debug builds succeeded.

# Xcode Progress Geometry Diagnostics (2026-07-28)

## Plan

- [x] Reproduce the reported geometry diagnostic under Xcode and capture its
  exact native view and dimensions.
- [x] Trace the invalid native `ProgressView` constraints to the mounted SwiftUI
  control.
- [x] Remove the unsupported transformed control geometry while preserving the
  compact status indicator.
- [x] Relaunch under Xcode and verify the diagnostic no longer appears.
- [x] Run focused/full tests, strict formatting, diff checks, and macOS/iPad
  builds.

## Review

- Reproduced under the Xcode debugger as an AppKit `ProgressView` constraint
  diagnostic: maximum length `16.666667` failed the native minimum/maximum
  validation.
- Root cause was `BackgroundStatusBar` applying `scaleEffect(0.6)` to a native
  small progress indicator inside a fixed 12-point frame. SwiftUI inverted the
  transform into a fractional AppKit layout proposal whose rounded bounds
  crossed.
- Replaced the transform with the platform-supported `.mini` control size while
  retaining the 12-point status slot.
- Rebuilt and relaunched under Xcode; the geometry diagnostic did not return.
- Verification: full `swift test` passed 694 tests with 7
  environment-dependent skips; strict recursive Swift format lint and `git
  diff --check` passed; macOS Debug and generic physical-device iPad Debug
  builds succeeded.

# Excessive Lyric Review Flags (2026-07-28)

## Plan

- [x] Reproduce the warning density against the current persisted song.
- [x] Separate acoustic beat-grid flags from section-template flags and quantify
  which rule dominates.
- [x] Add a regression fixture that represents consistent vocal pickup timing
  without hiding genuinely short, long, or structurally malformed lines.
- [x] Fix the diagnostic baseline at its source and keep hover reasons specific.
- [x] Re-run the live-song diagnostic, focused/full tests, strict formatting,
  diff checks, and macOS/iPad builds.

## Review

- Root cause: `LyricLineDiagnostics` treated a lyric start more than 0.3 beat
  from the nearest detected beat as a likely mis-split. Vocal pickups and
  syncopated phrases do not have to begin on beat centers, so this flagged a
  large fraction of valid lines by construction.
- Removed nearest-beat onset distance as a standalone warning signal. Duration
  outliers and section-template diagnostics remain, and the Review Flags help
  text now describes only those evidence-backed checks.
- On the current 37-line song, acoustic flags fell from 19 to 4: three long
  lines and the short `Whoa-oh` line. Structural diagnostics add four
  line-count mismatch flags, one overlapping a long line, for 7 unique review
  flags instead of roughly half the song.
- Added a regression proving equal-duration phrases with between-beat pickups
  are accepted while the existing short-line regression still passes.
- Verification: focused diagnostic and structure tests passed; full `swift
  test` passed 694 tests with 7 environment-dependent skips; strict recursive
  Swift format lint, `git diff --check`, macOS Debug build, and generic
  physical-device iPad Debug build passed.

# ChordPro and Review Playback Rendering Parity (2026-07-28)

## Plan

- [x] Add a ChordPro-only presentation configuration that uses the same
  `ChordProAppPreview` renderer as Review without exposing the Edit mode.
- [x] Route the ChordPro tab through the shared preview so font, line spacing,
  rhythmic layout, lyric highlighting, bouncing ball, and auto-scroll are identical.
- [x] Preserve ChordPro transpose, export, and display controls.
- [x] Add regression coverage for the ChordPro presentation configuration.
- [x] Run focused/full tests, strict formatting, diff checks, and macOS/iPad builds.

## Review

- `ChordProTrueView` now selects `ChordProTabConfig.chordProPlayback`, which
  fixes `ChordProTabEditor` in App Preview mode while retaining timing, View,
  transpose, export, and JustChords controls.
- ChordPro and Review now instantiate the same `ChordProAppPreview`; typography,
  rhythmic spacing, highlighting, bouncing ball, and auto-scroll have one owner.
- Focused ChordPro layout/highlight suite: 23 passed. Full Swift suite:
  693 passed, 7 environment-dependent tests skipped.
- Strict Swift format lint, `git diff --check`, macOS Debug build, and generic
  physical-device iPad Debug build passed.
- Fresh-binary UI inspection confirmed the ChordPro tab exposes the timing/View
  controls and `chordpro-app-preview`. Automated screenshot capture during live
  playback timed out, so the test process was stopped; playback overlays retain
  their existing focused unit coverage.

# First-Line Lyric Regression and Missing Advanced Stems (2026-07-28)

## Plan

- [x] Reproduce first-line lyric loss from the current persisted analysis and
  identify whether transcription, alignment, persistence, or rendering removes it.
- [x] Reproduce the six-stem limitation from production capability/factory
  configuration.
- [x] Add regression tests at the real failing seams before changing behavior.
- [x] Fix first-line preservation without restoring hallucinated/silent tokens.
- [x] Make mixer controls and metering expose real refined/imported child stems
  dynamically instead of assuming the six base stems.
- [ ] Register verified native desktop refiner model artifacts; do not advertise
  child stems without model files, licenses, checksums, and output taxonomies.
- [x] Run focused and full tests, strict formatting, macOS/iPad builds, and inspect
  representative persisted/rendered output.

## Review

- The live persisted transcription cache already contained only `Amen.` for the
  opening line, proving the loss occurred in ASR rather than ChordPro rendering.
- A bounded retry against the real 18-31 second vocal region recovered
  `The saloon door swung up though he walks in.` with the installed Whisper model.
- Accuracy mode now retries only sparse opening decodes after long intros and
  merges the richer opening without replacing the rest of the full-song result.
- Near-onset correction now preserves leading words in segments that straddle the
  detected vocal onset.
- Current production separation remains six stems because no verified lead/backing,
  drum-piece, or lead/rhythm model artifacts are registered. The mixer and meters
  now expose arbitrary real `StemID` children when a refined manifest exists.
- Focused suite: 242 passed, 1 opt-in model test skipped. Full Swift suite:
  692 passed, 7 environment-dependent tests skipped. Strict format lint and
  `git diff --check` passed. macOS and generic physical-device iPad Debug builds
  both succeeded.

# Native Swift Stem Refinement (2026-07-28)

- [x] Record native Swift/Xcode inference as the primary production direction.
- [x] Add an in-process stem refiner that consumes a selected parent stem.
- [x] Map native model outputs to hierarchical lead/backing, drum-piece, and
  lead/rhythm track IDs without changing the base separator interface.
- [x] Include wrapped engine/model identity in refined-stem cache identity.
- [ ] Register concrete desktop refinement model artifacts after model files,
  licenses, checksums, and output taxonomies are selected.
- [ ] Register smaller iPad refinement artifacts only after device memory and
  reconstruction-quality gates pass.

## Review

- `StemSeparationTests`: 14 passed.
- Full Swift suite: 686 passed, 7 model/corpus-dependent tests skipped.
- Strict Swift format lint passed.
- macOS Debug `SongWorkbench` build succeeded.
- Generic iOS Debug `SongWorkbenchiPad` build succeeded.
- `git diff --check` passed.

# External Stem Refiner Adapter (2026-07-28)

## Plan

- [x] Add a desktop command adapter that conforms to `StemRefinementEngine`.
- [x] Define a small JSON contract for external refiners to return descriptors and audio assets.
- [x] Make the command receive source audio, output directory, source digest, and current stem
      manifest paths without coupling to a specific Python/model stack.
- [x] Add tests for manifest parsing, relative output resolution, and command failure.
- [x] Run focused tests, full tests, lint, diff check, and macOS/iPad builds.

## Acceptance criteria

- [x] A model runner can be integrated by producing a JSON manifest and WAV files in its assigned
      output directory.
- [x] The adapter remains desktop-only for command execution and fails explicitly elsewhere.
- [x] Existing Swift-native refiner and six-stem behavior remains unchanged.
- [x] Verification evidence is recorded here.

## Review

- Added `ExternalStemRefinementEngine`, `ExternalStemRefinementCommandInvocation`,
  `ExternalStemRefinementCommandRunning`, and `ExternalStemRefinementManifest`. The adapter writes
  the current `StemSetManifest` to `stem-refinement-request.json`, runs a desktop command, reads
  `stem-refinement-result.json`, and maps returned tracks into descriptors/assets.
- External commands receive templated arguments for `{input}`, `{outputDirectory}`,
  `{sourceDigest}`, `{requestManifest}`, and `{responseManifest}`. This keeps Python/model runners
  decoupled from Swift while giving them all paths required to produce refined stems.
- Added explicit failures for unsupported platform command execution, non-zero command status, and
  missing response manifest. The existing refinement pipeline still validates declared output stem
  files before persisting a refined result as current.
- Added tests covering command invocation, saved request manifest, relative audio path resolution,
  missing response manifest, and command failure propagation.
- Verification: focused `StemSeparationTests` passed 12 tests; broader stem/factory/pipeline/cache
  tests passed 62 tests; full `swift test` passed 684 tests with 7 skipped and 0 failures; strict
  Swift format lint and `git diff --check` passed; macOS Debug `SongWorkbench` build succeeded;
  generic iOS Debug `SongWorkbenchiPad` build succeeded.

---

# Desktop Stem Refiner Assembly (2026-07-28)

## Plan

- [x] Add an injectable factory for desktop-only stem refinement engines.
- [x] Expose an explicit advanced desktop capability profile without changing the default desktop
      six-stem profile.
- [x] Wire advanced desktop assembly to pass configured refiners into `SongAnalysisPipeline`.
- [x] Add tests proving advanced desktop can inject refiners, while full desktop and iPad do not.
- [x] Run focused tests, full tests, lint, diff check, and macOS/iPad builds.

## Acceptance criteria

- [x] Current desktop and iPad defaults produce no refinement engines unless explicitly configured.
- [x] Advanced desktop has a stable product tier for model-backed stem refiners.
- [x] Refiner assembly has access to the base stem package and current capability profile.
- [x] Verification evidence is recorded here.

## Review

- Added `AnalysisCapabilityProfile.desktopAdvanced` as the opt-in tier for future model-backed
  refiners. The default desktop profile remains `Desktop Full` / `.fullSixStem`, and iPad remains
  `iPad Reduced` / `.reducedSixStem`.
- Added `StemRefinementEngineFactory` with a small context object carrying the active capability
  profile, base stem model package, and observed model statuses. The production default is empty,
  so current behavior is unchanged.
- `SongAnalysisPipelineFactory` now asks the refiner factory only for `.advancedDesktop` runs with
  an available base stem engine, then passes those refiners into `SongAnalysisPipeline`.
- Added tests proving advanced desktop refiner assembly participates in refined-stem cache identity
  without constructing the heavyweight ONNX model, and proving default desktop/iPad profiles never
  request refiners.
- Verification: focused factory/pipeline/stem/cache tests passed 59 tests; full `swift test`
  passed 681 tests with 7 skipped and 0 failures; strict Swift format lint and `git diff --check`
  passed; macOS Debug `SongWorkbench` build succeeded; generic iOS Debug `SongWorkbenchiPad`
  build succeeded.

---

# Plan: Structure tab accuracy — Settle Down live review (Task #43, drafted 2026-07-07)

Eric live-reviewed the Structure tab on Settle Down and flagged 4 issues in one pass. All trace
to the same theme as Task #39 above: parts of `SongStructureOverviewBuilder`/`SongStructureAnalyzer`
lean on lyric-derived signals (line count, exact per-line text/chord equality) where a musically-
grounded, tolerant signal would be more robust.

## A. Verse 3/Verse 4 should be one Bridge — CONFIRMED by Eric, do first

Live data: FORM shows `Verse 3` (2:36-2:46, 2 lines: "thought I would slow down." / "But then I
saw her smile.") and `Verse 4` (2:46-2:55, 3 lines: "She turned my baby someday" / "I think" /
"I am gonna stay") as two separate sections, sandwiched between the 2nd Chorus and the
Instrumental. Every real verse/chorus in this song runs 6-9 lines / 20-50s; these two are 2-3
lines / ~10s each. Read together they're one continuous Bridge.

Root cause: `SongStructureAnalyzer.vocalSections` (ChordProDraftBuilder.swift) splits
unconditionally whenever `gap >= sectionGap` (4.0s) — the actual gap here is 4.38s, just over the
threshold, a natural mid-bridge breath, not a real section boundary. `reclassifyBridgeAndSolo`
(SongStructureOverviewBuilder) exists to relabel a verse-shaped section as Bridge by chord-pattern
mismatch, but never gets the chance because the two halves are never merged back into one section
first.

Eric confirmed target: Intro → Verse 1 → Chorus → Verse 2 → Chorus → **Bridge** → Instrumental →
Chorus → Outro.

Fix direction (not yet implemented): a gap-only split (no classification/kind mismatch) between
two ADJACENT same-kind, non-chorus blocks should require stronger evidence than a kind-change
split — kind changes carry their own independent evidence, a bare gap doesn't. Concretely: after
the existing block-flush loop, merge adjacent `.verse`-kind sections when the gap between them is
modest (not real Instrumental-scale) and at least one side is anomalously short vs. the song's
other verse-kind occurrences (reuse evidence already present in the computed `sections`, not a
fresh magic-number threshold). `sectionGap` itself must NOT simply move higher — that risks
merging genuinely separate verses in other songs (Key West Bar's "Yeah I need a break… in a Key
West bar" continuation test already covers the single-short-trailing-line case; this is the
sibling case of two-or-more short blocks each on their own line-count already, needs its own new
test). Needs a dedicated test fixture reproducing this exact 4-part shape (2 real verses, 1
fragmented-into-two bridge, gap = sectionGap + a hair) before landing.

## B. Chorus phrase pattern shows near-zero repetition (A B C D E F G H for 8-9 lines)

Eric: "the composition of the chorus lists many patterns A B C D E F G H etc. But there seem to
be a lot less than that, so maybe the criteria is off." Confirmed live: CHORUS TEMPLATE phrase
pattern is `A B C D E F G H` — essentially no two lines ever cluster as "the same phrase", which
doesn't match how a real chorus's melody works (a handful of repeating phrase shapes, e.g. AABA/
ABAB, not one-off letters per line).

Root cause: `MelodyPhraseProxy.phraseLetters` (SongStructureOverview.swift ~line 158) clusters
two lines as the same phrase only when their `chordSignatures` arrays are EXACTLY equal
(`$0.signature == signature`) and syllable count is within ±1. Real per-line chord windows
(`chords.filter { $0.time >= line.start && $0.time < line.end }`) pick up timing jitter/passing
chords, so two melodically-identical lines rarely produce byte-identical signature arrays — the
same brittleness `reclassifyBridgeAndSolo` already solved for section-level comparison via
`signaturesMatch` (Jaccard ≥ 0.75, tolerates one passing chord). Fix direction: make
`MelodyPhraseProxy.phraseLetters` cluster via the same tolerant `signaturesMatch`-style
comparison instead of exact `==`.

## C. Instrumental section chord patterns look noisy/ungrounded

Eric: "The chord patterns seem grounded in vocal melody, and go bad when it's instrumental." Live
data: Outro chord pattern alone lists ~19 chord symbols across 36s. Two possible root causes,
NOT yet distinguished:
  1. `buildInstrumentalSummaries`/`chordSignature` aggregation is fine, and the underlying chord-
     DETECTION itself (harmony analysis stage) is genuinely noisier without a vocal melody to
     anchor pitch tracking — a chord-detection-engine accuracy question, not a Structure-tab
     aggregation bug, and a much bigger separate investigation.
  2. Something in how instrumental-section chord windows are sliced/attributed IS a Structure-tab
     bug (distinct from A/B above).
Needs its own investigation pass (compare raw Chords-tab data for the Outro span against what's
displayed here) before deciding which. Do not conflate with A/B's fix.

## D. "Too much dependence on lyrics" in representative/canonical-length selection

Eric's broader callout, and the direct cause of a real bug already observed live: `buildTemplates`
picks each kind's canonical shape via `mostCommonInt(lineCounts)` (a lyric-line-count vote) and
`occurrences.first { $0.lines.count == canonicalLineCount }` for the representative. With Settle
Down's current (buggy, pre-A-fix) verse occurrences at line counts `[6, 4, 2, 3]` — all distinct,
no majority — `mostCommonInt` picks whichever key a Swift `Dictionary` iterates first on a
count-1 tie, which is UNSTABLE/unspecified order. Live-observed: this picked the 2-line Verse 3
fragment as the "representative" VERSE TEMPLATE (`Length: 2 lines`), corrupting the whole verse
template display. Once A is fixed the immediate symptom likely disappears (fewer/no ties), but
the underlying design smell remains: canonical-shape selection is keyed on a lyric-derived count,
not a musical one. Fix direction: prefer a musically-grounded tie-break (bar count/duration, or
matching the kind's majority CHORD pattern the way `reclassifyBridgeAndSolo` already does) over
lyric line count, or at minimum make the tie-break deterministic (e.g. longest duration, or
earliest occurrence) instead of dictionary-iteration-order.

## Suggested order

A first (confirmed, well-scoped, isolated to `SongStructureAnalyzer.vocalSections`) → D (small,
deterministic tie-break fix, verify A alone doesn't already resolve it) → B (isolated to
`MelodyPhraseProxy`) → C (separate investigation, likely bigger scope, decide after A/B/D whether
the symptom persists on a clean structure).

## Live verification (2026-07-07, Settle Down, commit `cd1aa74`, rebuilt app)

- **A confirmed working**: FORM now reads Intro → Verse 1 → Chorus → Verse 2 → Chorus →
  **Verse 3 (2:36–2:55, one continuous section)** → Instrumental → Chorus → Outro — the former
  Verse 3 (2:36–2:46) + Verse 4 (2:46–2:55) fragments merged into one, exactly as Eric confirmed
  he expected. Stayed labeled "Verse 3" rather than being promoted to "Bridge" by
  `reclassifyBridgeAndSolo` — expected/acceptable, since that promotion depends on this song's
  actual chord data clearing the signature-mismatch bar, which wasn't part of what Eric asked to
  fix (he confirmed the STRUCTURAL merge, not a guaranteed Bridge relabel).
- **D confirmed working**: VERSE TEMPLATE now reads `Length: 6 lines` (was `Length: 2 lines`,
  picking the anomalous fragment via an unstable line-count tie before this fix).
- **B mechanism correct but limited real-world impact on this song**: CHORUS TEMPLATE still shows
  `Phrase Pattern: A B C D E F G H` — unchanged. Unit tests confirm the tolerant (Jaccard >= 0.75)
  clustering works correctly on synthetic "one passing chord" jitter. Settle Down's REAL chorus
  chord pattern is far denser than that (~28 chord-signature entries across 9 lines, ~3 chords/
  line on average) — per-line signatures differ by MORE than one passing chord, so even the
  tolerant threshold can't bridge them. This is a strong signal that the underlying chord-
  DETECTION density/jitter itself (Task #46 / Issue C, already deferred as a separate
  investigation) is the deeper root cause behind BOTH the noisy instrumental chord patterns AND
  this residual chorus over-fragmentation — worth investigating together rather than raising
  `MelodyPhraseProxy`'s tolerance threshold in isolation (which would deviate from the
  `signaturesMatch` convention used elsewhere without addressing the real cause).

---
# Plan: music-structure-first lyric segmentation (Task #39, drafted 2026-07-07, NOT started)

Eric approved the direction ("1 Yes. 2 Yes. 3 Yes") — see
[[lyric-segmentation-music-first-direction]] in memory for the full quote/rationale. This is a
plan only. Confirm phasing before starting implementation (Eric's stated preference: plan first,
check in before implementing).

## Where things stand today (grounded in this session's reading, not assumption)

- `TimedLyricSegmentGrouper.group`/`.regroup` (Transcription.swift): text/gap/capitalization/
  comma-driven. Runs 3x independently per song (once per installed transcription mode) AND again
  unconditionally on every `AppModel.applyAnalysis` load. This is the ONLY grouping mechanism
  when just one transcription mode is installed (`runLyricBlendPasses` no-ops entirely when
  `otherModes` is empty — single-mode songs never touch the blend-row machinery at all).
- `LyricBlendRowBuilder` (backlog #11): clusters the (up to 3) modes' already-grouped lines into
  time-windowed rows; `onsetCorroboration`/`onsetPreferredMode` use REAL vocal-stem onsets
  (`InstrumentOnsetDetector.onsets(url:)` on the separated vocals stem) but ONLY to pick BETWEEN
  already-formed candidate rows' timing — never to cut a new boundary. This onset list is computed
  fresh inside `runLyricBlendPasses`'s Task and is NOT persisted in `SongAnalysisDocument` —
  needed for Phase B1 below.
- `LyricPhraseGrouper` (backlog #9 Phase 1): the ONE bar/rhythm-aware pass. Runs LAST, as an
  optional post-pass, gated behind `detectPeriod` finding >=2 full periods of >=0.75-confidence
  chord-per-bar autocorrelation WITHIN a single section OCCURRENCE. A section that occurs once
  (a lone Verse 2, a Bridge) can never produce that evidence and is left entirely to the
  text-driven grouper's output — exactly the gap that let the Settle Down bug through.
- `SongStructureOverviewBuilder` (Task #36, this session): ALREADY does cross-occurrence pooling,
  just for the Structure tab's display, not fed back into segmentation. `buildTemplates` takes the
  MAJORITY line count and a representative chord pattern across ALL occurrences of a kind
  (`mostCommonInt(lineCounts)`), and `reclassifyBridgeAndSolo` already compares each occurrence's
  chord signature against the kind's majority pattern (`chordSignature`/`signaturesMatch`, Jaccard
  >= 0.75). This is most of the "pool evidence across occurrences" machinery Phase B needs —
  reuse it rather than re-deriving cross-occurrence consensus from scratch in `LyricPhraseGrouper`.

## Phase A — done, committed (`9cd6f77`)

`segmentLineStart` capitalization-gate fix. Narrow, safe, ships regardless of everything below
since the text/gap grouper will still exist as the eventual fallback tier.

## Phase B — cross-section pooling + persisted vocal onsets

### Phase B2 — cross-section pooling — done, committed (`80a1f22`)

`LyricPhraseGrouper.regroup` now computes one pooled bar-label-self-similarity decision per
section KIND (verse, chorus) from every occurrence of that kind combined, instead of requiring
each occurrence prove its own period alone. Falls back to the old single-occurrence `detectPeriod`
only when the pool doesn't clear `minimumConfidence`. `totalBars` (not lag-period test-pair count)
gates `minimumFullPeriods`, so pooling is a strict superset of the old per-occurrence behavior when
a kind has only one occurrence (verified: all 11 pre-existing tests pass unchanged). New test
`testLoneVerseBorrowsThePeriodItsConfidentSiblingVersesEstablish` proves the actual new capability
end-to-end (a lone verse at 0.5 confidence alone borrows period 4 from siblings pooling to 0.833).
Full suite run: 600 tests, same 8 pre-existing failures (AppModelTests/MusicLibraryTests
song-library persistence/ordering — confirmed present identically with this change stashed out,
unrelated to lyric grouping) present with and without this change. Not yet live-verified against a
real song — planned alongside Phase B1/C live verification per the risks section below, since
pooling alone has limited visible effect until Phase C promotes it to primary.

### Phase B1 — persist vocal onsets in the schema (not started)

1. **Persist vocal onsets in the schema.** Add `SongAnalysisDocument.vocalOnsets: [TimeInterval]`
   (schemaVersion 12), computed via `InstrumentOnsetDetector.onsets(url:)` on the vocals stem once
   real stem separation completes (harmony/separation stage, wherever the stem file first becomes
   available — NOT recomputed on every load). Old songs: empty array until their next "Analyze
   Song" (or a lazy one-time backfill on load if a vocals stem file already exists on disk —
   decide which during implementation; lazy backfill avoids forcing a re-analysis just to gain
   this field, but adds load-time cost to every old song's first open).
2. **Feed `PhraseTemplate` (or an equivalent lighter derivation) into `LyricPhraseGrouper` as the
   period/line-count source of truth**, replacing `detectPeriod`'s single-occurrence-only
   autocorrelation. Concretely: for a section kind with >=2 worded occurrences, the majority line
   count (already computed by `SongStructureOverviewBuilder.buildTemplates`) implies a phrase
   period in bars (occurrence's own bar span / majority line count, rounded) — apply that period
   to EVERY occurrence of the kind, including ones with too little internal repetition to prove it
   alone (the exact Verse-2-borrows-from-Verse-1/3 case Eric asked for). A kind with only ONE
   occurrence ever (no cross-section evidence at all — a Bridge, most commonly) still falls back
   to `detectPeriod`'s existing single-occurrence autocorrelation, or to Phase C's fallback tier
   if that also fails.
3. New tests: a section that individually has zero repeat evidence but shares its kind with 2+
   confidently-periodic siblings gets segmented using the siblings' period. Regression coverage
   for the existing chorus-determinism guard (must still hold under pooled detection).

## Phase C — promote structure to primary, demote text grouping to fallback (not started)

1. **Boundary snapping switches from "nearest real ASR word gap" to "nearest real vocal onset."**
   `LyricPhraseGrouper.resegmented`'s Stage 1 currently snaps each computed phrase boundary to the
   nearest inter-WORD gap in the flattened ASR word stream (`gapMidpoint`, built from
   `lines.flatMap(\.words)`). Once vocal onsets are persisted (Phase B1), snap to the nearest real
   onset/silence instead — independent of whichever transcription mode's (possibly wrong) word
   timing happened to win the blend. Words still supply TEXT content; onsets supply WHERE a line
   starts. Existing Stage 2 rhyme/syllable nudge (`RhymeSyllableScorer`) still applies on top.
2. **Reorder the pipeline in `AppModel.applyAnalysis`**: run the (now pooled + onset-anchored)
   `LyricPhraseGrouper` pass FIRST wherever chord/beat/onset data exists for a section, and only
   fall back to `TimedLyricSegmentGrouper`'s text/gap/capitalization grouping for spans where beat
   structure genuinely can't be established (no chords/beats at all, or pooled+single-occurrence
   detection both fail confidence) — matches Eric's "lowest priority fallback when all else
   fails." This likely also changes where `TimedLyricSegmentGrouper.group` runs for the INITIAL
   per-mode transcription pass (right now every mode groups into lines before any music-structure
   input exists at all) — needs its own sub-design pass once B is proven out; flagged here so it
   isn't lost, not scoped in detail yet.
3. Word-to-cell assignment: once a phrase-cell's [start,end) is fixed by structure+onsets, bucket
   whichever transcription candidate's words fall in that time range into the cell (nearest-onset
   assignment, same fencing discipline `resegmented` already uses so cells stay non-overlapping) —
   replacing the current "trust the ASR engine's own line break, then just correct it after the
   fact" flow with "structure decides the box, ASR text fills it."

## Risks / open questions to resolve before Phase C lands

- Changing `LyricPhraseGrouper`'s trigger condition from "rare, high-confidence" to "primary,
  broadly-applied" means it will touch FAR more songs' lyrics than it does today — needs a wide
  live-verification pass (multiple real songs, not just Settle Down/Key West Bar) before treating
  it as done, per this project's established verify-live convention.
  `LyricBlendRowBuilder`/`LyricPhraseGrouper`/`TimedLyricSegmentGrouper` together have 100+
  existing tests; expect real churn there, not just additions.
- `TimedLyricSegment.reconciled`'s override/accepted-annotation carry-forward matches by time-
  window overlap — re-verify overrides still survive once cell boundaries move to onset-anchored
  positions (they'll shift slightly vs. today's word-gap-anchored positions).
- Onset detection quality varies by song (percussive/dense mixes vs. clean vocal stems) — decide
  a real confidence/fallback story for "onsets exist but are noisy" distinct from "no onsets at
  all," mirroring `LyricPhraseGrouper`'s existing "no-op, loudly, on low confidence" philosophy.

---
# Fix: segmentLineStart capitalization gate merges lowercase-starting lines (2026-07-07)

Task #37/#38. Eric: "In Settle Down, there are a lot of lines that contain multiple rhythmic
repeating patterns that should have been separate lines. Line 8 is a good example."

Root-caused via the real persisted analysis JSON (`~/Library/Containers/com.local.SongWorkbench/
.../songs/*.json`) and a temporary debug XCTest that called `TimedLyricSegmentGrouper.regroup`/
`LyricPhraseGrouper.regroup` directly on the real data (deleted after diagnosis, never committed):

- `lyricBlendRows` showed the raw candidates were CLEAN: "She makes me want to settle down,"
  [54.40,58.12] and "trading my rowdy friends for a one-horse town." [59.85/60.35,65.78/70.20]
  were two separate, multi-mode-agreed rows.
- `LyricBlendRowBuilder.effectiveLyrics(from:)` maps rows 1:1 to segments, so the ORIGINAL
  `document.lyrics` from a fresh analysis should have been 2 separate lines too.
- But `AppModel.applyAnalysis` unconditionally reruns `TimedLyricSegmentGrouper.regroup` (and then
  `LyricPhraseGrouper.regroup`) on `document.lyrics` on EVERY LOAD. Reconstructing the pre-merge
  2-segment state and feeding it through `TimedLyricSegmentGrouper.regroup` reproduced the exact
  merge live: `segmentLineStart` (the rule meant to force a break at an already-known line-start
  onset even across a short gap) ALSO required `beginsCapitalizedWord(token.text)`. The second
  line's first word, "trading", is lowercase, so the forced break silently didn't fire; the 2.2s
  gap is real but under `maximumGap` (3s) once segment structure is present, so nothing else
  caught it either — the two lines welded into one run-on line.
- This is why the bug is STICKY across reloads: once merged, the sub-boundary (60.35 as its own
  segment start) is gone from `lineStartOnsets` on the next regroup, so it can never self-heal —
  only a fresh "Analyze Song" (which rebuilds `document.lyrics` from `lyricBlendRows` via
  `effectiveLyrics`, bypassing the corrupted stored lyrics entirely) recovers the correct split.
- `LyricPhraseGrouper` (the one bar/rhythm-aware pass) never got a chance to help either: it
  requires >=2 full periods of confident (>=0.75) chord-per-bar autocorrelation WITHIN a single
  section occurrence, and this Verse 2 occurs once — no repetition evidence to detect a period
  from at all.

**Fix**: removed the `beginsCapitalizedWord` requirement from `segmentLineStart`
(`Transcription.swift`) — capitalization is not evidence either way for whether an exact
`lineStartOnsets` time match is a real boundary; requiring it defeated the rule's own purpose.
Added `testGroupingBreaksAtLowercaseSegmentLineStartWithoutRequiringCapitalization` reproducing
the exact field tokens/onsets as a permanent regression test.

**Verification**: `swift format lint --strict`, `swift build`, `swift test` (51/51
`TranscriptionTests` incl. the 3 tests that already exercised `segmentLineStart`-adjacent
behavior via other mechanisms — conjunction-continuation and leading-orphan merging, confirmed
unaffected since those fire regardless of this flag; full suite 599 tests, same pre-existing
8-failure baseline, nothing new). Rebuilt the macOS `.app`, re-ran "Analyze Song" live on Settle
Down (a stale already-merged song can't self-heal on load per the mechanism above — needed a
fresh analysis pass to rebuild `lyrics` from `lyricBlendRows`): both previously-merged lines now
render as clean separate lines ("She makes me want to settle down," / "trading my rowdy friends
for a one-horse town." at [54.40,58.12]/[60.35,65.78], and the analogous Verse 4 occurrence at
[128.08,133.76]/[133.89,138.44]).

## Bigger picture: this is a symptom, not the disease

Eric's follow-up, verbatim: "It still feels like we're adding structure to the found lyrics,
centering on the words as the most important factor. We need to prioritize the music, the beat,
the rhythm, and the structure, then find the most likely lyric for each beat of the song. The
Vocal track onset gives us strong clues as to where the words go, but [we should not let word-
level heuristics] ignore the structure. It has to be musical first and foremost."

Confirmed by this investigation: bar/rhythm structure (`LyricPhraseGrouper`) exists in this
codebase but is a weak, LATE, optional correction layer — gated behind strict per-occurrence
repetition evidence a single verse can never produce alone — while everything upstream (all 3
transcription modes' own line grouping, and the reload-time regroup) is purely text/punctuation/
gap-driven, and vocal onset (`LyricBlendRowBuilder.onsetCorroboration`) is only used to pick
BETWEEN already-formed candidates, never to cut a boundary from scratch.

Eric approved, verbatim ("1 Yes. 2 Yes. 3 Yes - lowest priority fallback when all else fails"):
1. Cross-section/cross-song pooling for bar-period detection (a lone Verse 2 borrows the phrase
   period its sibling verses establish, instead of requiring each occurrence prove its own).
2. Promote bar/beat grid + vocal onset to the PRIMARY line-boundary driver; demote the text/gap/
   capitalization grouper (`TimedLyricSegmentGrouper`) to a fallback used only where beat
   structure can't be established at all (rubato, spoken-word, no chord/beat data).
3. Ship this session's capitalization-gate fix now regardless (done, above) — it's the correct
   behavior for whatever the fallback ends up covering either way.

See Task #39 for the phased implementation plan (drafted, not yet started).

---
# Structure-alignment anomaly detection (2026-07-07)

Task #36. Eric: "I'm curious how we can tell performance with alignment to the established song
structure. It seems like enforcing some level of alignment would have caught these bugs sooner,"
followed by "When we have rhyming sentences, it seems like they would be separate lines, and not
concatenated. So there are other mechanisms we should use to validate the final version."

Added `StructureAlignmentDiagnostics` (`SongStructureOverview.swift`), a pure validation pass
that compares each section occurrence's actual lines against its established `PhraseTemplate`
(built earlier for the Structure tab from Meter/Rhyme/chord-pattern data already computed by
`SongStructureOverviewBuilder`):

- **Line-count mismatch**: if a section occurrence has a different number of lines than its
  template, position-by-position comparison isn't meaningful — flagged as a whole (on the first
  line) with the counts, since a mismatch is itself strong evidence a line was merged or split.
- **Meter + rhyme deviation**: when counts match, each line's syllable count (`SyllableCounter`,
  already exposed as `syllableCount(for:)`) and its established RHYME PARTNER (the other line
  position the template's `rhymeScheme` pairs it with) are checked independently. A line is only
  flagged when BOTH deviate — off-meter alone or a fresh rhyme alone is ordinary songwriting
  variation; both together is a strong tell something got merged, split, or mis-transcribed.
  Chord-event-count-per-line is folded in as a third, corroborating (non-required) signal.
- Rhyme comparison deliberately does NOT compare the letter LABELS in `PhraseTemplate.rhymeScheme`
  directly (`"A"`/`"B"`/…) — those are assigned positionally, fresh, on every call, so two
  independently-computed schemes can coincidentally collide on the same letter at the same index
  without meaning the same phonetic class. Instead it re-checks the actual current words at the
  template's established PARTNER positions via `RhymeDetector.rhymes(_:_:)` directly.
- `SongStructureOverviewBuilder.syllableCount(for:)` and `.rhymeScheme(for:lines:detector:)` were
  un-privated for reuse; `PhraseTemplate` gained a `chordCountPattern: [Int]` field (free from
  `buildTemplates`'s existing `perLineChordSignatures`).
- Wired into the Lyrics tab by MERGING into the existing `showSuspectFlags`/"Review Flags" review
  mechanism (`TimedLyricsEditor.suspectReasons` in `WorkspaceEditorsView.swift`) rather than
  building new UI — same toggle, same warning-triangle icon, same tooltip; a line flagged by both
  the acoustic beat-grid heuristic and the new structural one gets both reasons concatenated.
  Distinct from (and complementary to) `ReviewConfidenceTier`'s per-word ASR-confidence tint,
  which is an acoustic signal, not a structural/linguistic one.

**Testing note**: the SPM test bundle doesn't host the app target's `Resources/`, so
`RhymeDetector.shared` resolves every word to "no entry" in `swift test` (see the pre-existing
`RhymeDetectorTests`'s own hand-built-table workaround). Made `rhymeScheme(for:detector:)` and
`StructureAlignmentDiagnostics.anomalies(in:detector:)` accept an injectable `RhymeDetector`
(default `.shared`, zero production behavior change) so tests can supply a small hand-built table.
Also constructed `SongStructureOverview` test fixtures directly (`Section`/`PhraseTemplate`
struct literals) rather than round-tripping through the full builder pipeline — `Section`-
detection heuristics (`SongStructureAnalyzer`'s word-Jaccard chorus/verse classifier) misfire on
synthetic fixtures that intentionally repeat lines verbatim across occurrences (reads as a real
chorus repeat), which is already covered by `SongStructureOverviewBuilderTests` and isn't this
feature's job to re-verify.

## Live re-verification (incidentally re-covers Task #35)

Rebuilt the macOS `.app` (`xcodebuild`, not `swift build`) and toggled "Review Flags" live on Key
West Bar. The new diagnostic correctly flagged, with concrete reasons:
- Chorus at [118.14, 122.45): `"Line count (1) differs from the established Chorus shape (7
  lines) — a line may have been merged or split incorrectly."` — this is the "There's a a place
  with with no no worries, worries, no no racing racing" run-on line.
- Verse 3 at [126.82, 131.66): `"Line count (1) differs from the established Verse 3 shape (3
  lines)…"` — the "Just cars cars time and time, that's not my fault" run-on line.

This confirms the word-doubling bug **is still present** in Key West Bar's Chorus/Verse 3
sections even after this session's earlier `LyricBlendRowBuilder` overlap-merge fix and
`AnalysisStage.swift` cache-tag bump (still uncommitted — see git status). The tag bump's
effectiveness remains unconfirmed; Task #35 (re-verify/root-cause why re-analysis isn't picking
up the fix for this song) is still open. This diagnostic is a genuinely useful independent
detector of that open bug, not a fix for it.

## Verification

- `swift format lint --strict --recursive Sources Tests`, `swift build`, and `swift test --skip
  AudioPlaybackServiceTests --skip StemPlaybackServiceTests` (606 tests: 2 new
  `StructureAlignmentDiagnosticsTests` passing, same pre-existing 8-assertion
  `AppModelTests`/`MusicLibraryAppModelTests` baseline, nothing new broken) all clean.
- Rebuilt the macOS `.app` via `xcodebuild` and live-verified on Key West Bar as above.

---
# Fix: missed chord changes + dropped end-of-song lyrics (2026-07-04)

# iPad device build smoke test (2026-07-06)

## Acceptance criteria

- [x] The active Xcode iPad destination builds without macOS-only AppKit import errors.
- [ ] If the build succeeds, launch the app on the connected iPad from Xcode. Still open:
      later iPad work reached generic iOS builds, but physical connected-device launch evidence
      is still blocked by device availability/discovery.

## Review

- Updated shared SwiftUI files to use `#if os(macOS)` for AppKit imports/branches instead
  of `canImport(AppKit)`, keeping iPad builds on UIKit paths.
- Fast Xcode diagnostics: clean for `ChordProReadOnlyView.swift`, `ContentView.swift`,
  `WorkspaceEditorsView.swift`, and `PlatformShims.swift`.
- Xcode `BuildProject`: succeeded on 2026-07-06 using the active scheme/destination
  (7.366s). Launch/install still needs Xcode's Run action with the connected iPad selected.
- Follow-up: user reports the iPad is not listed in Xcode. `xcrun devicectl list devices`
  timed out waiting for `CoreDeviceService` to initialize, so current blocker is device
  discovery/trust/CoreDevice state rather than Swift compilation.

## Diagnosis (verified against code + real cached data)

### Symptom 1: Missed chord changes
Owner: `ChordTimelineDecoder` (Viterbi), NOT the old `ChordEventReducer` (only used as no-beat-grid fallback).

1. **Viterbi switchPenalty = 2.0 over-smooths** (`ChordTimelineDecoder.swift:19`).
   A one-window (one-beat) chord excursion pays 2×2.0 nats ⇒ needs ~e⁴≈55× evidence
   dominance in that window to survive. Real sweep on cached frames (Settle Down,
   482 beats, 2105 frames ≥0.45 conf):
   - penalty 2.5 → 106 events; 2.0 → 124; 1.5 → 137; 1.0 → 161; argmax voting → 215.
   Passing chords / one-bar changes are systematically absorbed.
2. **KeyPriorChordRescorer chromaticWeight 0.5** (`KeyAwareChordFiltering.swift:20`)
   compounds with the penalty: real secondary dominants/modulations rarely win.
3. **ChordOnsetAligner + ChordEventDurationFilter interaction**
   (`AudioFileAnalysisService.swift:539-570`, `KeyAwareChordFiltering.swift:101-146`):
   snap's nondecreasing clamp can compress two REAL changes to sub-0.8-beat spacing;
   the duration filter then drops one and `collapseDuplicates` can erase an A-B-A
   into a single A. Persisted docs show min gaps 0.7-1.0 beat, so this fires.

### Symptom 2: Lyrics dropped at end of songs
Owner: `TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail`
(`AudioFileAnalysisService.swift:1492-1513`), applied on the pure-ASR path in
`AnalysisStage.swift:434`.

- The geometric heuristic fires on virtually ANY song: if the 2nd-to-last line ends
  ≥3s before file end and the last line starts within 2s of it (normal singing), the
  cutoff = 2nd-to-last line's end ⇒ **final line(s) always cut**.
- **Proof from real data (Settle Down, pure-ASR)**: raw Whisper cache has
  `[220.8-225.9] "I never thought I'd want to hang around." conf 0.98` and
  `[226.8-229.8] "She makes me want to settle down." conf 1.00` — both missing from
  the final doc (final last end 220.3 in a 257.1s song). Key West Bar similarly loses
  its repeated outro hook (17s of vocals).
- Tests only cover the Summertime hallucination fixtures; no test covers a normal
  final line with `sourceDuration` set — which is why this shipped.
- The heuristic checks only geometry, never whether tail lines look degenerate
  (word count, confidence, duplication) and `min(signalCutoff, lyricBodyEnd)` lets
  it OVERRIDE a correct VAD that says vocals continue.

## Fix plan

### Lyrics (do first — bigger, clearer win)
- [x] `lyricBodyEndBeforeInstrumentalTail`: only return a cutoff when the tail looks
      degenerate — every tail line is (a) ≤2 substantive words, or (b) a normalized
      duplicate of an earlier line or of another tail line. Keeps Summertime blips
      ("I", duplicated "Sunset winks…") cut; keeps real unique closing lines.
- [x] `resolvedCutoff`: geometry may only TIGHTEN the VAD signal cutoff by ≤3s
      (never override a VAD that says vocals continue much later).
- [x] Add regression tests: normal final line + sourceDuration (Settle Down shape),
      repeated-outro-hook kept, Summertime fixtures still pass.

### Chords
- [x] Lower `switchPenalty` 2.0 → 1.5 AND make it onset-aware: pass the instrument
      onsets (already computed for snapping) into the decoder; windows whose start
      lies within ~0.12s of an onset get a reduced penalty (~0.75). Real changes
      happen on attacks; flicker suppression stays for mid-note windows.
- [x] `ChordOnsetAligner.snap`: don't move an event if that compresses gap to the
      previous event below 0.8 of the local beat (kills the sliver source instead of
      deleting real events downstream).
- [x] Keep ChordEventDurationFilter as safety net; add A-B-A regression test proving
      genuine one-beat B on an onset survives the whole pipeline.
- [x] Bump reducer-version suffix in `AnalysisStage.swift:618` so cached raw frames
      re-reduce without re-running chroma.

### Verify
- [x] Unit tests and format checks documented in the review below.
- [ ] Live app re-analysis remains: re-analyze Settle Down + one more song; confirm final
      lyrics reach ~230s and chord event count rises with changes landing on onsets.

## Review (2026-07-05)

Implemented, all in existing files (no tuist generate needed):
- `ChordTimelineDecoder`: switchPenalty 2.0→1.5; new onset-aware per-window penalty
  (×0.5 within 0.12s of an instrument onset); `decode(switchPenalties:)` +
  back-compat constant overload; onsets plumbed from AnalysisStage (computed
  before decode, reused for snap).
- `ChordOnsetAligner.snap(beatTimes:minimumBeatFraction:)`: refuses snaps that
  compress neighbours below 0.8 beat (sliver source eliminated; duration filter
  now truly a safety net).
- `TrailingLyricTailPruner`: `tailLooksDegenerate` (≤2 words or normalized dup)
  gates the geometric body-end; `maxSignalTightening = 3.0` caps how far geometry
  may tighten the VAD cutoff.
- Stage tags bumped: `reduce-12-onset-viterbi`, `grouping-42-degenerate-tail-prune`
  → next analysis re-reduces/re-groups from cached raw data, no re-chroma/re-ASR.
- Tests: +2 decoder (onset excursion survives / far onsets don't discount),
  +4 pruner/aligner (Settle Down kept, Key West hook kept, blip tail still cut,
  no sub-beat snap sliver). Full suite 558 tests: only the 8 pre-existing
  AppModelTests environment failures (identical on clean main, verified by stash).
- swift format lint clean.

Remaining to fully verify: re-analyze Settle Down / Key West in the app and
confirm final lyrics reach ~230s and chord changes land on onsets.

## Batch 2 review (2026-07-05, later)

- **Bass notes positioned on the time axis**: `BassNoteRowFormatter.timedLabels`
  (onset + name); `ChordProPreviewLineView.rowBassNotes` renders each note at
  `rhythmicX(forTime:)` on its own 18px row between the ball/dot reserve and the
  chords (collision-nudged like chords). Flush-left label kept only as
  monospace/override fallback. +2 formatter tests.
- **Duplicated preview lines (ball skips them)**: verified against persisted docs —
  NOT a preview-builder bug. `LyricBlendRowBuilder.buildRows` clusters the 3
  engines' lines with a 1.5s anchor window; engines timing the same line further
  apart (Grass: 20.26 vs 24.90) produced two rows → two rendered lines.
  Fix: `mergeCrossModeDuplicates` — merge adjacent clusters (≤8s apart) whose mode
  sets are DISJOINT and normalized texts equal; real repeated hooks share a mode
  and never merge. +3 tests. Also `ReferenceLyricAligner` now drops pasted-site
  timestamp tokens/lines ("0:00" junk, Flip Flops). +1 test. Existing docs clean
  up on next Analyze (grouping-42 re-groups from cached raw).
- **Smooth auto-scroll**: replaced default spring `scrollTo` with a 1.1s easeInOut
  glide (`ChordProAppPreview.autoScrollGlide`), anchor .center; ScrollView
  clamping inherently defers scrolling until the active line can reach center.
- Full suite 564 tests: only the 8 pre-existing AppModelTests environment
  failures. Lint clean. UI changes need an app rebuild + relaunch to see.

## Batch 3 review (2026-07-05): vocal-onset corroboration (Eric's invariant)

- `LyricBlendRowBuilder.onsetCorroboration(words:vocalOnsets:tolerance:)` — pure
  scorer: fraction of a candidate's word onsets within 0.18s of a vocal-stem
  energy onset (binary search, unit-tested).
- `onsetPreferredMode` / `onsetCorroborated(rows:vocalOnsets:)` — for rows the
  user hasn't picked, flip to the candidate the stem clearly corroborates
  (margin ≥ 0.25 over the accuracy-first default); user picks never touched.
- Wired into `AppModel.runLyricBlendPasses` AFTER reconcile: vocals-stem onsets
  via `InstrumentOnsetDetector` on a detached utility task; missing stem = no-op.
- +4 tests (scorer fractions, flip, user-pick protection, margin). Suite: 561
  run (audible playback suites now skipped locally via --skip to stop the
  "raspberry" — they play a real AVAudioEngine), same 8 pre-existing failures.
- .app rebuilt via xcodebuild (Debug) — RELAUNCH REQUIRED to see today's UI work.

Follow-ups (not started): per-line orphan flag in Review UI (line with ~zero
onset corroboration = suspect), unmatched-onset audit beyond the existing
untranscribedVocalRegions badge, and real-audio validation of the auto-pick
margin on Flip Flops after re-analysis.

## Batch 4 review (2026-07-05, afternoon)

- **Window/layout**: control row's fixed widths made content min ~1,790 > 1,540
  default ⇒ SwiftUI centered + clipped both outer columns. Tab picker moved into
  the middle pane (Eric's suggestion), scrubber/pitch/speed sliders made
  compressible, root minWidth 1,380. Sidebar + stem rail both 360pt (symmetry).
- **Blend fixes round 2**: non-adjacent cross-mode duplicate merge (Grass line
  landed 2 rows past its twin); Lyric Blend window no longer auto-opens —
  toolbar icon glows mint + badge when results are ready.
- **Re-analysis validation (Flip Flops)**: chords 119→133, 0:00 junk gone,
  outro kept; line-2 zipper traced to the non-adjacent duplicate (fix awaits
  next ⌘R).
- **Bass-vs-chord clashes** (measured 24–43%): BassLineAnalyzer parabolic lag
  interpolation + global tuning-offset via clarity-weighted CIRCULAR mean;
  display floor at clarity 0.5. Detuned-fourth regression test.
- **Mixer pan + L/R meters**: StemMixState.pan (persisted, back-compat),
  constant-power panGains, stemStereoLevels post-fader/post-pan, PanKnob rotary
  + HorizontalLRMeter per strip, export carries pan. AVFoundation gotcha: set
  AVAudioMixing params AFTER engine start (unit-test guarded).
- Suite: 568 tests, same 8 pre-existing AppModel env failures. App rebuilt —
  NEEDS RELAUNCH; then ⌘R re-analysis cleans remaining duplicates and applies
  the bass-detector fixes.

## Review: chord/vocal accuracy + timeline placement (2026-07-05)

Findings:
- [x] Harmony decode still windows raw chroma on the harmony engine's original
      `result.beat?.beatTimes`, even after deriving `resolvedBeatTimes` from
      drum onsets. This can pick labels and Viterbi switch discounts on a
      different grid than the one later used for snapping, duration filtering,
      chorus consensus, ChordPro, and playback.
- [x] `VocalWordOnsetAligner` lets multiple adjacent words snap to the same
      vocal onset because it only enforces nondecreasing starts. This can stack
      word anchors/ball timing and inflate onset-corroboration scores for
      candidates whose words are bunched near one energy burst.
- [x] Generated ChordPro still hard-codes `beatsPerBar = 4`, while the live
      preview estimates 3/4/5/6 from lyric-line spacing. Non-4 phrase grids can
      therefore render and persist chord-only rows/barlines differently from the
      preview timeline.

Verification basis:
- Static code review of `AnalysisStage`, `ChordTimelineDecoder`,
  `VocalWordOnsetAligner`, `ChordProDraftBuilder`, `WorkspaceEditorsView`,
  `MeasureGrid`, and associated tests. No implementation changes or test runs
  in this pass.

### Fixes landed (2026-07-05, night)

- **Harmony decode grid**: `ChordTimelineDecoder.events(from:key:bassNotes:instrumentOnsets:beatTimes:)`
  gained an optional `beatTimes` override (defaults to the old embedded-grid
  behavior when omitted, so every other caller is unaffected). `AnalysisStage`
  now passes `resolvedBeatTimes` (the drum-locked grid) explicitly, so chord
  decoding windows chroma on the SAME grid used downstream for snapping,
  duration filtering, chorus consensus, ChordPro, and playback. Reducer/cache
  stage tag bumped `"|reduce-14-bass-snap"` → `"|reduce-15-resolved-beatgrid"`
  to force cached analyses to re-decode. Regression:
  `testExplicitBeatTimesOverridesAnalysisEmbeddedGrid` (constructs a real chord
  change on a "true" grid while the analysis embeds a decoy grid, asserts the
  override wins).
- **VocalWordOnsetAligner stacked anchors**: `snapped(_:toOnsets:tolerance:minimumWordGap:)`
  gained a `minimumWordGap` (default 0.02s) and the nondecreasing clamp
  (`>=`) became a strict `+ minimumWordGap` floor, so adjacent words can no
  longer snap to the identical onset. Regression:
  `testVocalWordOnsetAlignerNeverStacksTwoWordsOnTheSameOnset` (same two-word/
  one-onset fixture as the existing nondecreasing test, strict `>` assertion).
- **ChordPro hard-coded beatsPerBar**: `ChordProDraftBuilder.measureGrid` took
  a `lyrics` parameter and now calls
  `DownbeatEstimator.estimateBeatsPerBar(beatTimes:onsets:)` with the lyric-line
  onsets — the same signal `WorkspaceEditorsView`'s live preview already uses —
  instead of a literal `4`. The doc comment's original justification ("the
  builder has no lyric-onset signal independent of the lyrics") was simply
  wrong: `lyrics: [TimedLyricSegment]` was already in scope. Regression:
  `testChordOnlyRowUsesEstimatedBeatsPerBarFromLyricSpacing` — a differential
  test (proved to fail without the fix, by temporarily hardcoding `4` and
  re-running) that builds the SAME outro chords twice, varying only whether
  the preceding lyric lines are spaced 5 beats or 4 beats apart, and asserts
  the rendered outro bar grid differs.
- Suite: 586 tests, same pre-existing `AppModelTests`/`MusicLibraryTests`
  environment failures (song-file-selection/persistence state, unrelated to
  these 3 fixes) — none in `ChordTimelineDecoderTests`,
  `ChordProDraftBuilderTests`, or the `VocalWordOnsetAligner` tests.
  `swift format lint --strict -r Sources Tests` clean.

## Review: instrumental-row width bug + Rhythmic Spacing always-on (2026-07-05, evening)

- **Instrumental line width** (Eric: "Intro and outro instrumental parts... compressed to
  roughly 1/3 the expected width"): three compounding bugs in `WorkspaceEditorsView.swift`,
  all in the chord-only (no lyric words) row path:
  1. `instrumentalTimeWidth` sized itself from the bar-grid TEXT's own character extent
     (`chordColumnExtent`), not from the row's real duration — a chord symbol is far more
     compact per bar than the words a singer fits into that bar, so a same-duration
     instrumental row rendered a fraction of a sung row's width. Fixed: keyed to
     `lineDuration * pixelsPerSecond` (the SAME scale rhythmic-mode sung lines use),
     falling back to the old character-extent sizing when rhythmic spacing is off.
  2. That fix initially did nothing: `lineStrip`'s `duration` was gated behind
     `instrumentalLane` (guitar/piano envelope) being loaded — an unrelated "is there a
     waveform to draw" concern bundled into the same guard, so it silently returned 0
     whenever no instrument stem was available/loaded at that call site. Decoupled: the
     row's time WINDOW resolves unconditionally; only the drawn peaks/color depend on a
     lane.
  3. Once width was time-based, chord glyphs (still positioned by column-fraction of the
     bar-grid text) clustered wrong. `lineStrip` now also returns the row's real start time;
     threaded through as `rowStartTime` on `ChordProPreviewBlockView`/`ChordProPreviewLineView`;
     `monospaceChordX` uses `(rowChordTimes[index] - rowStartTime) / lineDuration` when
     available. The flat "| . . |" bar-grid text can't stretch to the new width either, so
     it's hidden for instrumental rows once they're on the time-scaled axis (beat dots,
     already time-correct, remain as the structure indicator).
  - Verified live (Flip Flops, Settle Down): instrumental row widths now match/exceed
    adjacent vocal-line widths (previously ~65-90px vs ~230-515px); chords and beat dots
    spread across the full row instead of clustering left; no crash/regression.
- **Rhythmic Spacing toggle removed** (Eric: "always on"): `@AppStorage("rhythmicSpacing")`
  replaced with `private let rhythmicSpacing = true`; menu item deleted. Downstream code
  (three struct-level `var rhythmicSpacing = false` defaults + every conditional) left as-is
  since the parent always passes `true` now — minimal-impact, no behavior change to prune.
- Suite: same 568 tests, same 8 pre-existing AppModel env failures (verified twice, before
  and after this fix).
- **Build gotcha hit during this fix**: `xcodebuild build` via desktop-commander without
  `-derivedDataPath` wrote to a NEW DerivedData hash folder rather than the one the running
  app/Xcode.app uses — two rebuild+relaunch cycles showed zero visual change until caught by
  `stat`-ing the actual running binary's mtime. See tasks/lessons.md. Pin
  `-derivedDataPath` going forward.

## Fix: intro/outro bars rendering 2x too wide (2026-07-05, night)

- **Regression from the same evening's instrumental-row-width fix** (Eric, live: "Intro and
  outro bars are now twice as wide as they should be"), only now visible because that fix put
  chord-only rows on the real-duration `pixelsPerSecond` axis for the first time — the
  underlying bug existed before but was invisible under the old character-count sizing.
- **Root cause**: `WorkspaceEditorsView.chordOnlyLineWindow` splits a multi-row
  intro/instrumental/outro span into `1/rowCount` slices per row, counting `rowCount` by
  scanning `items` for consecutive chord-only rows via raw adjacent-index checks
  (`isChordOnlyRow(index - 1)` / `(index + 1)`). But `ChordProDraftBuilder` emits an
  `{x_chord_times: ...}` directive immediately before EVERY chord-only row (B5 round-trip
  carrier), so in `document.blocks`/`items` each row is actually 2 slots apart
  (directive, row, directive, row, ...), not 1. The raw adjacent check hit the directive and
  stopped immediately, collapsing every multi-row run to `rowCount == 1` — so each row
  claimed the ENTIRE gap instead of its slice.
- **Fix**: extracted the run-scan into a new, directly testable
  `ChordProPreviewIndexing.chordOnlyRunPosition(in:at:)` (`WorkspaceEditorsView.swift`) that
  walks past interleaved directive/comment blocks (anything that isn't a real sung lyric line
  or the array edge) instead of stopping at the first non-adjacent slot, and counts
  `position`/`rowCount` in actual-row hops rather than raw item-offset arithmetic (which would
  still overcount once directives are skipped). `chordOnlyLineWindow` now calls this shared
  function instead of inlining the (buggy) scan.
- Regression: `testChordOnlyRunPositionCountsConsecutiveRowsAcrossInterleavedDirectives`
  (3-row fixture mirroring the real directive/row/directive/row shape, asserts rowCount=3 and
  positions 0/1/2 — confirmed to fail with rowCount=[1,1,1] when reverted to the naive
  adjacent-index check) and `testChordOnlyRunPositionTreatsARealLyricLineAsARunBoundary` (two
  separate 1-row breaks either side of a sung line must not fuse into one false run of 2).
- Suite: 588 tests, same pre-existing `AppModelTests`/`MusicLibraryTests` environment
  failures. Lint clean. App rebuilt (pinned `-derivedDataPath`) and relaunched.

## Plan: "Structure" tab — Form / Harmony / Meter / Rhyme / Melody-proxy (2026-07-06)

Eric's proposal: separate a song's *structure* from its *content* — Form (section
order), Harmony (chord progression), Melody (phrase pattern e.g. AABA), Meter (lyric
syllable pattern), Rhyme (end-rhyme scheme), Lyrics (actual words) — then model each
recurring section as a reusable **Phrase Template** (chord pattern + meter + rhyme
scheme) that instances are checked against. Deviation from the fitted template is a
much stronger anomaly signal than today's per-subsystem heuristics, and would have
caught 2 of the 3 bugs found in the Key West Bar review by hand (short tag-line
misfire, run-on word-stealing) plus the word-doubling class of bug (a line running to
2x its section's normal syllable count is an obvious tell). Confirmed scope with Eric:
Phase 1 ships Form + Harmony + Meter + Rhyme together (not staged), Melody is an
approximate proxy (chord-pattern + meter + rhyme similarity across lines), clearly
labeled as approximate in the UI since there's no real pitch-contour pipeline.

Researched current architecture first (read-only subagent) so this plan targets real
code, not assumptions:

- `SongStructureAnalyzer.vocalSections(for:)` (`ChordProDraftBuilder.swift:795-926`)
  already gives Verse N / Chorus labels + `isProbableContinuation` (today's fix). Only
  `.verse`/`.chorus` kinds — no Intro/Bridge/Solo/Outro distinction.
- Intro/Instrumental/Outro detection is inline in `ChordProDraftBuilder.build(...)`
  (~lines 170-305), bars-based (`gapBars >= 4`), independent of `SongStructureAnalyzer`.
  **No merged whole-song ordered Form list exists yet** — must assemble one from both.
- **No Roman-numeral/scale-degree math exists anywhere.** `MusicalKey.swift` has the
  pitch-class name table (line 16-18) and a private `parseChord(_:)` (line 63-88) to
  reuse for chord-root/quality extraction.
- **Syllable counting and rhyme detection already exist and are unit-tested**:
  `SyllableCounter.swift`, `RhymeDetector.swift` (loads bundled
  `Resources/cmudict_rhyme.tsv`), `RhymeSyllableScorer.swift`, already consumed by
  `LyricPhraseGrouper.swift`. Meter/Rhyme layers reuse these directly — no new phonetic
  code needed.
- UI tabs are a `Picker` over `EditorTab` (`WorkspaceEditorsView.swift:10-35`), state in
  `ContentView.swift:230`, switched view in `WorkspaceEditorsView`. `ChordProReadOnlyView`
  is the closest sibling (read-only, takes a plain rendered string). `SongTimeline` is
  computed on demand by `ChordProDraftBuilder.buildResult(...)` and memoized in
  `AppModel` by source-string cache key (`AppModel.swift:2109`, `songTimelineForPreview()`
  at 2110-2134) — not persisted into the saved analysis JSON. Follow the same pattern:
  derive, don't persist.

### Steps
- [x] New `SongStructureOverview.swift`: `FormSection` (label, kind incl. new
      `.intro/.bridge/.solo/.outro/.instrumental` alongside existing verse/chorus,
      start/end), assembled by merging `SongStructureAnalyzer.vocalSections` with the
      existing bars-gap instrumental detection into one ordered list. Bridge/Solo rule
      (per Eric — "a word-less verse or chorus pattern is usually a solo"): an
      instrumental gap classifies as **Solo** when its chord progression matches an
      already-established Verse/Chorus template's chord pattern over the corresponding
      bar span (i.e. it's that section played wordless) — reuses the same
      chord-pattern-matching the Phrase Template step below needs, no separate
      duration heuristic required. A gap that matches no known template stays generic
      **Instrumental**. **Bridge** is a worded, non-repeating section that doesn't
      match the verse or chorus template. Ship as best-effort v1, expect retuning
      once checked against more real songs.
- [x] Roman-numeral mapping: new small function (on `MusicalKey` or a new
      `RomanNumeralMapper`) — chord root pitch class vs. key root → scale degree,
      quality-aware casing (upper/lower/°/+), reusing `MusicalKey.parseChord`. Chords
      that don't classify cleanly (secondary dominants etc.) fall back to bare
      chord-letter display rather than a wrong numeral.
- [x] Meter: per section, syllable count per lyric line via existing `SyllableCounter`.
- [x] Rhyme: per section, end-rhyme letters (A/B/C/D) per line via existing
      `RhymeDetector`/`RhymeSyllableScorer`.
- [x] Melody proxy: per section, build a per-line signature (chord-pattern hash +
      syllable count + rhyme letter, tolerant match not exact), assign phrase letters
      (A/A/B/A) by first-appearance order within the section. Label as approximate
      in the UI — this is not real melody analysis.
- [x] Phrase Template assembly: for each repeated section kind, pick a canonical
      occurrence and report {length in lines, phrase pattern, chord pattern, lyric
      meter, rhyme} — matches the shape of Eric's Key West Bar example (FORM +
      VERSE TEMPLATE + CHORUS TEMPLATE blocks).
- [x] New read-only `SongStructureView.swift` + `EditorTab.structure` case, wired into
      the same `Picker` as the Review tab; `AppModel.songStructureOverview()` memoized
      the same way as `songTimelineForPreview()` (derive on demand, no cache-migration
      concerns).
- [x] Tests: new `SongStructureOverviewTests.swift` — Roman-numeral cases (incl.
      secondary-dominant fallback), Form-list assembly (vocal + instrumental merge),
      melody-proxy phrase-letter assignment on a synthetic 4-line verse fixture,
      template assembly picking the canonical occurrence. Reuse existing
      `TimedLyricSegment`/`EditableChordEvent` fixture conventions.
- [x] Verify: build, full suite (expect only the pre-existing ~8 AppModelTests/
      MusicLibraryTests env failures), lint, rebuild+relaunch app, eyeball the tab
      against Key West Bar's real data.

## Review (2026-07-06)

Implemented as planned, in one new source file plus small additions:
- `SongStructureOverview.swift`: `SongStructureOverview`/`Section`/`PhraseTemplate`,
  `RomanNumeralMapper` (own small chord-root parser, deliberately separate from
  `MusicalKeyEstimator.parseChord` — didn't touch that already-tested internal),
  `MelodyPhraseProxy`, `SongStructureOverviewBuilder`. Form reuses
  `LyricSectionDeriver.sections` (already merges vocal + instrumental/intro/outro into
  one ordered list — no new merge logic needed there). Bridge/Solo reclassification
  and Phrase Template assembly share one `chordSignature`/`signaturesMatch` comparator
  (exact match, or ≥0.75 Jaccard set-overlap fallback for a single passing chord).
- `AppModel.songStructureOverview()`: cached by `chordProSource` like
  `songTimelineForPreview()`, but simpler (no byte-for-byte round-trip check needed).
- `EditorTab.structure` + `SongStructureView.swift`: read-only, mirrors
  `ChordProReadOnlyView`'s shape (plain scroll, no edit chrome), renders FORM plus a
  template card per repeated worded section kind.
- Tests: 11 new (`RomanNumeralMapperTests`, `MelodyPhraseProxyTests`,
  `SongStructureOverviewBuilderTests` — the last using a hand-built fixture with two
  matching-chord verses, a wordless gap reusing the verse pattern (→ Solo), and a
  worded section with an unrelated pattern (→ Bridge, not "Verse 3")). All passed on
  first run — no red/green needed since nothing existing was being changed.
- Suite: 601 tests, same 8 pre-existing `AppModelTests`/`MusicLibraryTests`
  environment failures, nothing new. Lint clean repo-wide.
- Live-verified on Key West Bar (real data, rebuilt app via `tuist generate` +
  pinned-`-derivedDataPath` `xcodebuild`): Form correctly lists Intro/Verse 1-4/
  Chorus×4/Instrumental/Outro matching the song's real structure, including the short
  ~4s "Verse 3" (the tag-line block task #14 fixed). VERSE/CHORUS templates render
  with real chord/meter/rhyme data. No Bridge/Solo triggered on this song's real
  (noisier) chord data — plausible given the exact/0.75-Jaccard match is tuned against
  clean synthetic data; flagged in the plan as expected v1 retuning territory, not
  treated as a bug.
- **Environment note**: `.build/checkouts` got corrupted mid-session (two ` 2`-suffixed
  duplicate checkout dirs, stale `workspace-state.json`) — almost certainly a
  concurrent process (the iPad-support work landing at the same time) touching the
  same SwiftPM cache. Fixed by removing the duplicates + `workspace-state.json` +
  `repositories` and re-running `swift package resolve`. See `tasks/lessons.md`.

---
# Structure tab first + exhaustive iPad/desktop test pass (2026-07-06)

## What shipped

- Moved `.structure` to the first position in `EditorTab` (enum order = tab order = ⌘-shortcut
  order) in `WorkspaceEditorsView.swift`; updated `ContentView.swift`'s doc comment.
- iPad landscape-only lock: `Project.swift`'s `SongWorkbenchiPad` target now declares only
  `UIInterfaceOrientationLandscapeLeft/Right` in `UISupportedInterfaceOrientations`. Confirmed
  by direct testing that portrait clips the 3-column desktop-style layout (columns/labels cut
  off); this was Eric's own suspicion going in, verified before fixing.
- Exhaustive per-song check, **macOS desktop**: all 4 songs (Key West Bar, Settle Down, Flip
  Flops and Barbeque, Summertime's her with you) render correctly across all 5 tabs.
- Exhaustive per-song check, **iPad Pro 13" simulator**, full pipeline from scratch (Eric's
  explicit choice: "All 4 songs, full pipeline, on iPad"): copied the 4 source audio files into
  the simulator's sandboxed container Documents folder via `simctl get_app_container`, imported
  each through the in-app Files picker, ran Stems → Transcribe → Tempo & Chords → ChordPro for
  all 4. All succeeded; Structure tab verified for each.
  - **Found + documented, not fixed**: Whisper Large V3 Turbo (Accuracy transcription) can't
    install on iPad — `ModelPackageManager.swift`'s `DittoModelArchiveExtractor` shells out to
    `/usr/bin/ditto` (`Process`/NSTask), which is macOS-only; the iOS `#else` branch throws
    `extractionUnsupportedOnPlatform`. This was already flagged in a code comment as tracked/
    known, not a new regression. Fast/Balanced (Parakeet, Core ML) installs and works fine on
    iPad and was used for all 4 songs. Fixing this needs an in-process unzip (Apple Archive
    framework) — real work, left for a dedicated pass.
  - One accidental song deletion during testing (mis-clicked a trash icon next to the "+"
    import button in the cramped iPad header) — re-imported, no lasting effect.

## UI polish requests that came up live during the iPad pass (all shipped + verified both platforms)

- Song list rows: dropped the MP3/M4A file-format caption line (title-only rows, tighter).
- Song list is now collapsible: chevron in the `SongSidebar` header toggles `@AppStorage
  "songSidebarExpanded"` (same key read in both `SongSidebar` and `PlayerView.mainColumns`, so
  the outer split-view frame shrinks too); collapsed state shows just the current song's title,
  tap to re-expand.
- `SongStructureView`'s own header no longer repeats the song title (already shown by the
  shared per-song title above the tab bar) — only the "Approximate" badge remains. This was the
  "wasted space at the top of the screen" Eric flagged; confirmed by reading the view's code.
- Background-activity status ("Ready" / in-progress spinner) moved from a dedicated footer bar
  at the bottom of the window into the `SongSidebar` header row; the footer bar is gone.
- Structure tab: added INTRO/INSTRUMENTAL/OUTRO SECTIONS cards (new
  `SongStructureOverview.InstrumentalSummary`: occurrence count, total time, representative
  chord pattern) alongside the existing VERSE/CHORUS/BRIDGE phrase templates — wordless
  sections previously only showed up as bare rows in the FORM list with no further detail.

## Verification

- `swift build`, `swift test` (601 tests, same 8 pre-existing `AppModelTests`/
  `MusicLibraryTests` baseline failures — confirmed via `git stash` that they fail identically
  on unmodified `main`, so not caused by this session's changes), and `swift format lint
  --strict --recursive Sources Tests` all clean after every batch of changes.
- Rebuilt + relaunched both the macOS app and the iPad simulator app after each change and
  live-verified via screenshots: collapsible list (both directions), tightened Structure
  header, inline "Songs · Ready" status with no footer, and the new instrumental section cards
  — on both platforms.
- Did not add an iOS unit-test target: `SongWorkbenchTests` in `Project.swift` is
  `destinations: .macOS` only and `SongWorkbenchiPad`'s scheme has no `testAction`. Live/manual
  verification on the simulator stood in for iOS-side unit tests this pass.

## Not done / left open

- Whisper-on-iPad archive extraction (see above) — needs an Apple Archive-based in-process
  unzip; `ModelPackageManager.swift` already has the seam (`ModelArchiveExtracting` protocol).
- Task #15 from an earlier session (word-doubling/timing-overlap fix in
  `LyricBlendRowBuilder.swift`, lost to a concurrent-process race) is still pending, untouched
  this session.

---
# Review pane width, iPad nav-bar chrome, ChordPro concatenation bug (2026-07-06, later same day)

Three follow-up reports that came in during/after the iPad testing pass above.

## Review pane forcing left/right panels off-screen

- `ChordProTabEditor`'s toolbar (title/badge/Import/mode picker/timing offset/View menu/Mark
  Reviewed/Transpose/Export/JustChords) is only used by the Review tab (`ChordProReviewTab`
  is the sole caller with `config: .chordPro`, which turns every optional control on) and had
  no width constraint — its summed ideal width exceeded the middle column, especially on iPad,
  pushing `SongSidebar`/`StemMixSidebar` out of the window.
- Fix: split the toolbar into its own `toolbar` computed view and wrap it in a horizontal
  `ScrollView` inside `body`, so it can only ever claim the width it's given instead of forcing
  its parent wider. Dropped the toolbar's trailing `Spacer()` (meaningless inside a horizontal
  ScrollView).
- Verified live on the iPad simulator: Review tab now shows the full toolbar plus both side
  panels, nothing off-screen.

## iPad "wasted space at the top of the screen" (second report, distinct from the Structure-tab one)

- Root cause: `SongSidebar`'s `.navigationTitle("Songs")` (inside `ContentView`'s single
  `NavigationStack`) renders iOS's large-title system nav bar above our own compact collapsible
  header — chrome macOS never shows, since `.navigationTitle` there just sets the window title.
- Fix: new `View.hideSystemNavigationBarCompat()` in `PlatformShims.swift`
  (`.toolbar(.hidden, for: .navigationBar)` on iOS, no-op on macOS), applied right after
  `.navigationTitle("Songs")`.
- Verified live on the iPad simulator: status bar sits directly above the compact header now,
  no large title banner.

## ChordPro lines rendering concatenated/scrambled on iPad ("Summertime's her with you")

Finally root-caused and fixed Task #15 (word-doubling/timing-overlap in
`LyricBlendRowBuilder.swift`), left pending across multiple earlier sessions.

- Root cause (confirmed against the iPad simulator's OWN persisted analysis JSON, pulled via
  `xcrun simctl get_app_container`): with only Parakeet available on iPad (no Whisper/accuracy
  model), `balancedDraft`'s own line grouper ran two-to-three real lyric lines together into a
  single run-on segment, while `fastDraft` split the SAME span into 2-3 clean, correctly-ordered
  segments. `LyricBlendRowBuilder.buildRows`'s clustering only pulled the FIRST of those clean
  segments into the run-on's cluster (the rest were more than `clusterWindow` away from its
  anchor), so the clean segments became separate `LyricBlendRow`s whose time spans nonetheless
  OVERLAPPED the run-on row. `ChordProDraftBuilder` has no concept of overlapping lyric lines
  (a single voice can't sing two spans at once), so it printed all of them, and their words read
  as scrambled/doubled on the chart.
- Fix: `LyricBlendRowBuilder.mergeCrossModeDuplicates` gained a second, fallback merge pass
  (`canMergeByOverlap`) that runs only when the existing exact-normalized-text pass finds
  nothing. It merges an earlier cluster with a later one when their time windows actually
  overlap AND the later cluster is a single-mode fragment (not already corroborated by 2+
  modes) AND no mode common to both contributes segments that themselves overlap in time. The
  single-mode-fragment condition is what keeps the existing `testRunOnDemotionTolerates…`
  field case (Settle Down: both balanced AND fast cleanly split the phrase's second half into
  their own 2-mode row) staying as 2 separate rows — that shape is independently trustworthy
  and is `runOnDuplicatesDemoted`'s job, not this merge.
- Added two regression tests reproducing the exact live iPad timestamps/text: a 2-cluster case
  and the full 3-fastDraft-segment case from the field data.
- Verified end-to-end: rebuilt the iPad app, re-ran "Analyze Song" on the live simulator for
  the same song, and confirmed via the freshly-written analysis JSON that the chorus now
  renders as ONE coherent line ("Laughter rising in the air It's just me and you right there
  sometimes here with you") instead of 3 overlapping/scrambled ones.

## Verification

- `swift build`, `swift test` (604 tests: the same pre-existing 5-failure/8-assertion
  `AppModelTests`/`MusicLibraryAppModelTests` baseline, nothing new), `swift build -c release`,
  and `swift format lint --strict --recursive Sources Tests` all clean.
- Rebuilt + reinstalled + relaunched the iPad simulator app after every change; visually
  confirmed all three fixes live (Review pane layout, nav-bar chrome, and a full live
  re-analysis of "Summertime's her with you" showing the corrected single-line chorus).

---
# (previous) Align to Reference Lyrics — done 2026-06-25, see git history for details

---
# Plan: W1 downbeat-aware chord switch penalty + pure-time row axis (Task #47, drafted 2026-07-08)

Eric approved both directions via quality review (tasks/quality-review-2026-07.md). Plan
written before implementation per workflow. NOT started.

## W1 — metric-position-dependent switch penalty (chord density root cause)

Grounding: `ChordTimelineDecoder.windowSwitchPenalties` currently charges `switchPenalty` (1.5)
× `onsetPenaltyFactor` (0.5) when a window start is within 0.12s of an instrument onset. No
metric-position awareness. `DownbeatEstimator.barPhase(beatStrengths:)` (MeasureGrid.swift:149)
already derives bar phase from drums+bass accent energy — NO lyrics needed, computable at
analysis time from the same drum-locked grid the decoder already receives.

- [x] 1. AnalysisStage (HarmonyStage.run, ~:643-668): compute `beatsPerBar` via
      `DownbeatEstimator.estimateBeatsPerBar` and `barPhase` via `barPhase(beatStrengths:)`
      using drum-stem energy sampled at `resolvedBeatTimes`; pass both into the decoder.
- [x] 2. ChordTimelineDecoder: optional `meter: (beatsPerBar: Int, barPhase: Int)?` param
      (nil = exact old behavior, all callers/tests unchanged). In `windowSwitchPenalties`,
      multiply base penalty by a metric factor per window index i:
      downbeat ≈0.7, half-bar ≈0.85, weak beats ≈1.3 (constants to tune offline).
      Clamp combined (metric × onset) discount to ≥0.35 × base so discounts don't stack to
      free. Keep the onset discount — genuine syncopation must stay reachable.
- [x] 3. Bump harmony stage version tag (reduce-12 → reduce-13) so cached songs re-decode.
- [x] 4. Offline validation BEFORE app verification, same harness as the decoder's doc header
      (ChordTimelineDecoder.swift:11-14): replay cached Analysis JSON for reference songs
      (Settle Down + the reference song). Metrics: event count, % non-diatonic, sub-beat
      count, chorus self-agreement, instrumental outro symbol count (currently ~19/36s),
      MelodyPhraseProxy chorus letters (currently A B C D E F G H — expect repeats to emerge).
      Guard: verify known-real mid-verse changes (the ones 2.5/2.0 lost) still detected.
- [x] 5. Unit tests: synthetic windows where a passing chord on a weak beat is absorbed but
      the same evidence on a downbeat switches; nil-meter regression test.
- [ ] 6. Live verify on Mac (xcodebuild default DerivedData — NOT a repo-local
      -derivedDataPath, iCloud xattrs break CodeSign; see memory), re-analyze, check
      Structure tab chorus phrase pattern + outro chord pattern.

## Pure-time row axis (purple vs yellow width unification)

- [x] 1. Measure first (verify-numerically lesson): from cached transcription JSON, compute
      per-word textWidth(9px/char) vs duration×100px/s across songs → quantify how often
      words would collide without the monospace floor, worst-case overlap px.
- [x] 2. Based on data, pick mitigation: accept small overlaps (likely fine if rare), or
      derive global pixelsPerSecond from ~95th-pct char-rate (keeps ONE axis song-wide;
      chord-drag px↔s conversion must use the same constant), or per-row font shrink (last
      resort). Present numbers to Eric if ambiguous.
- [ ] 3. rhythmicWordXs (WorkspaceEditorsView.swift:3678-3691): drop cumulative
      max(desired, cursor) floor → x = metricX(word.start). totalWidth becomes
      duration-based + last-word glyph allowance. Verify strip/chords/dots/ball all follow
      (they map through rhythmicX/metricX, so they inherit the fix).
- [x] 4. Fix outro chord-only lineDuration=0 fallback: resolve end bound from song/beat
      duration (as LyricSectionDeriver.resolvedSongEnd does) in chordOnlyLineWindow
      (~:2588-2593) so rows never collapse to char-count width.
- [ ] 5. Rebuild app + live verify: equal-elapsed purple and yellow rows render equal width;
      drag-to-retime chords still lands where dropped.

## Review (2026-07-08)

W1 LANDED. Decoder: `BarMeter` + metric-position switch-penalty factors (downbeat 0.7,
half-bar 0.85, weak 1.3, combined-discount floor 0.35x; nil meter = exact old behavior).
HarmonyStage: bar phase from drums-stem accent energy via new `DrumAccentProfile` +
`DownbeatEstimator.barPhase(beatStrengths:)`, gated on downbeatConfidence >= 0.08 (mirrors
preview refreshGrid). Version bump reduce-15 -> reduce-16-metric-switch-penalty. 4 new unit
tests; full suite 625 green.

Offline validation (new manual harness ChordDecoderOfflineValidationTests, run with
SW_OFFLINE_VALIDATION=1): 17 cached analyses, 13 with usable meter. Densest song 174->166
events (1.38->1.32/bar); per-beat flurries collapsed (e.g. 3 chords in 1.1s removed);
boundary moves of +/-1 beat onto downbeats; two songs +2 downbeat changes; nothing lost on
the flicker-suppression side. Factors deliberately conservative — if Structure-tab chorus
phrase letters remain fully distinct, raise weakBeatFactor toward 1.6 using the harness.

Pure-time axis: MEASURED, then DEFERRED by Eric. 74 cached transcriptions: at 100px/s, 53%
of adjacent sung-word pairs physically can't fit their time gap at 15pt (median required
102px/s, p95 270, melisma pairs ~0 gap); half the songs need no stretch at all. The
screenshot's narrow purple rows were likely the outro zero-duration fallback bug — FIXED
(chordOnlyLineWindow now falls back to beat-grid extent + one bar when no envelope is
loaded). Decision: rebuild + re-check visually before any axis rework; if still needed, the
per-song adaptive shared scale (clamp densest-line requirement to 100-250px/s) is the
agreed direction.

---

# HANDOFF (2026-07-08) — next session: iPad model-install crash

## Bug
On iPad, the app crashes shortly after prompting to install a missing model.

## Known facts (verified this session)
- `ModelPackageManager.swift:81-99` `DittoModelArchiveExtractor.extract` shells to
  `/usr/bin/ditto` via `Process` on macOS; on iOS it throws
  `ModelPackageError.extractionUnsupportedOnPlatform`. A THROW should alert, not
  crash → the crash is an unguarded failure path upstream in the install flow
  (try!, force-unwrap, or unchecked continuation) OR earlier in download handling.
- The old SongWorkbench-ipad worktree is GONE; iPad support now lives in main
  (repo /Users/ericnewman/Documents/SongWorkbench, HEAD fe8dade).
- No SongWorkbench crash logs in ~/Library/Logs/DiagnosticReports (device crash;
  user asked to pull the .ips from iPad Settings > Privacy & Security >
  Analytics Data, or via Xcode's Devices window).

## Plan
1. Read the .ips crash log if the user provided it (check repo root / chat).
2. Trace the install flow from the "install missing model" prompt to extract();
   find and fix the unguarded failure path (surface an alert instead).
3. Implement in-process zip extraction for iOS behind the existing
   `ModelArchiveExtracting` protocol seam (small zip reader; Apple Archive
   doesn't read .zip). Unit-test with a tiny fixture zip.
4. Verify on iOS Simulator + device build; keep the macOS ditto path unchanged.

## Also queued (user-requested)
- Long instrumental lines still render too wide in the ChordPro preview —
  split/cap instrumental rows to the same rendered width budget as sung lines
  (builder splits by typicalBars but the preview draws rows time-scaled at
  pixelsPerSecond; re-check against CURRENT code, it has moved past reduce-14).
- A3 repeated-section chord consensus (sim showed chorus agreement 80%→100%).
- Unresolved: macOS "failed model loading" message when starting analysis
  (Jul 8 report) — never reproduced; suspects: parakeet -int8 folder-name
  symlink staging, or a stale whisper model version folder (Models has "1" and "2").

## RESOLUTION (2026-07-08) — iPad model-install crash

Approach chosen: "just stop the crash" (not the deeper in-process-zip-extraction path in
step 3 above — that remains a scoped-out follow-up so Whisper/Accuracy can eventually
install on iPad).

Root fix = gate out the un-installable package everywhere on iPad instead of letting the
user reach Whisper's macOS-only `ditto` extraction:
- `ModelPackageManager.isInstallableOnCurrentPlatform` (false for archive-bearing packages
  on iOS).
- Both install entry points filter by it: the Models popover (`AnalysisWorkspaceView`) and
  the new first-run `ModelOnboardingSheet` (`ContentView`). There is no programmatic
  auto-install caller, and mode selection (`availableTranscriptionModes` /
  `primaryTranscriptionMode`) only READS installed status — so `extract()` is now
  unreachable on iPad.
- Onboarding gate blocks the app until all platform-installable models are present, so on
  iPad Parakeet is guaranteed installed and `primaryTranscriptionMode` never falls back to
  `.accuracy`.
Also bundled (separate iPad bug, was written but never committed): the iOS
security-scoped-URL import fix in `AppModel.importSongs` + import-error surfacing on the
no-song screen + `com.local.SongWorkbench` import Logger.

Verification: `xcodebuild` SongWorkbenchiPad Debug for iPad Pro 13" (M5) sim → BUILD
SUCCEEDED; installed + launched on that sim → runs the full analysis UI on a real analyzed
song with no crash; call-graph audit confirms every `installModelPackage` caller is
filtered. Committed as the iPad-fix commit; the unrelated chord-decoder / ChordPro-preview
WIP was intentionally left uncommitted in the working tree.

# Phase 2 plan (2026-07-08): short-segment 6-stem HTDemucs for iPad

## Why
iPad stem separation OOMs (jetsam per-process-limit ~4.8GB on 4GB iPad Pro 3rd-gen).
Measured on Mac (exact demucsv4.onnx, fixed input 343,980 = 7.8s): FP32 fwd pass = 3.46GB;
int8 = 3.23GB (activations dominate, weight-quant useless); fp16 export invalid + CPU EP
won't use fp16 anyway. Input length hard-fixed → can't shorten segment on existing artifact.

## Key finding (validated)
htdemucs_6s internally pads any input UP to training_length (=segment*sr=343,980) then slices
output back, so a short INPUT doesn't help. BUT setting `model.segment` smaller DOES reduce
compute+memory and the transformer tolerates it (ran clean at 4s/3s/2s). Torch fwd RSS:
7.8s=1.81GB, 3.0s=0.95GB. Projected onnxruntime @3s ≈ 1.5-1.9GB → fits 4GB with the
increased-memory-limit entitlement (committed b4bb4f5) + Phase-1 buffer freeing.

## Blocker to solve
torch.onnx.export (TorchScript) fails: "STFT does not currently support complex types".
dynamo export fails on a data-dependent assert in htdemucs forward. Fix = patch
demucs/spec.py spectro/ispectro to a real-DFT (conv/matmul) STFT so the graph is all-real and
ONNX-exportable, bit-matching demucs's params (n_fft, hop, hann, normalized=True, center,
reflect pad). MansfieldPlumbing's public export solved the equivalent for the 7.8s model.

## Steps
1. Patch STFT, set segment ~3-3.5s, export htdemucs_6s → onnx. Verify onnxruntime loads + runs.
2. Measure onnxruntime peak RSS at candidate segments; pick smallest-context that keeps quality
   with headroom under ~2GB.
3. Validate stem quality: compare separated stems (SDR / null test) vs the current 7.8s model on
   a real song — overlap-add already smooths chunk seams; confirm no audible regression.
4. Deliver artifact (~246MB, weights unchanged): DECISION — bundle in iPad app Resources
   (offline, no hosting, +size, skip HTDemucs download on iPad) vs host at a URL (needs an
   account) + add to ModelCatalog.
5. Wire: platform-branch so iPad uses the short-segment model; update
   ONNXSixStemChunkPredictor.frameCount + ONNXSixStemSeparationEngine.segmentFrames/overlapFrames
   to the new length; bump engineVersion so cached stems regen.
6. Device-test on the real iPad: confirm separation completes, no jetsam; keep macOS on the
   7.8s model (more context, plenty of RAM).

## Phase 2 export note (2026-07-08)
Confirmed empirically: setting segment=3.5s runs; env set up (torch/demucs/onnxscript in
/tmp/demucs_mem). Export blocker detail — the cheap patch (spectro return_complex=False +
view_as_complex, keep complex istft) does NOT work: torch.istft still requires a complex input
and the exporter rejects complex stft/istft. No shortcut: must hand-roll a real DFT (matmul
cos/sin, normalized=/sqrt(nfft), hann(4096), hop 1024, center reflect pad nfft//2) AND a real
iSTFT (windowed overlap-add + NOLA window-sq normalization) replacing demucs.spec.spectro/
ispectro, then A/B the separated stems vs the stock 7.8s model (null test) before trusting it.
demucs spec params: n_fft=4096, hop=1024, win=hann(4096), win_length=4096, normalized=True,
center=True, pad_mode=reflect, freqs=2049.

## Phase 2 RESULT (2026-07-08) — export DONE + validated, wiring pending
Short-segment 6-stem export SUCCEEDED. Pipeline in tools/demucs_export/ (realstft.py +
export_dyn.py). Real-valued STFT (conv1d framing + matmul IDFT + F.fold OLA) replaces demucs
complex STFT; exported via dynamo (opset 18) after monkeypatching pad1d to drop its data-dependent
.all() assert. Model: demucsv4_3p5s.onnx (248MB embedded, gitignored).
Validated: onnx vs torch 5.7e-6; real-STFT vs stock full model 79dB SDR; onnxruntime CPU peak RSS
1.95GB @3.5s (vs 3.46GB @7.8s) -> fits 4GB iPad w/ entitlement; quality A/B 3.5 vs 7.8s on real
song: vocals 20/bass 18.6/drums 16.9/guitar 7.6 dB (piano/other near-silent in that track).
REMAINING (wiring): bundle demucsv4_3p5s.onnx in iPad Resources; ONNXSixStemChunkPredictor.frameCount
343980->154350; ONNXSixStemSeparationEngine.segmentFrames->154350 (overlap /4); platform-branch so
macOS keeps the 7.8s downloaded model and iPad uses the bundled 3.5s one; make htdemucs count as
installed-on-iPad (bundled, not downloaded) so the onboarding gate passes; bump engineVersion to
regen cached stems; rebuild+device test peak (uninstall wipes container -> re-onboard).

---

# Accuracy and performance-decomposition refinement (2026-07-20)

## Plan

- [x] Establish deterministic feedback loops for word/onset alignment, lyric-candidate
      timing quality, and section boundaries; inventory representative cached analyses
      without changing corpus coverage.
- [x] Replace greedy many-to-one vocal-onset matching with a monotonic assignment that
      preserves ASR timings when no distinct supported onset exists.
- [x] Make lyric timing corroboration use the same one-to-one matching semantics so a
      single vocal burst cannot count as evidence for multiple words.
- [x] Evaluate section-boundary inference against lyric, beat, chord, and stem-derived
      evidence; implement only a signal that improves representative fixtures without
      regressing established verse/chorus/bridge cases.
- [x] Identify the smallest coherent performance-map/export addition that makes existing
      stems, beats, chords, bass, lyrics, and structure easier to use for recreation.
- [x] Run focused tests, the full Swift test suite, build validation, and any available
      cached-song/offline harness; record exact evidence and remaining limitations below.

## Acceptance criteria

- [x] Adjacent words cannot be assigned to the same detected vocal onset or to fabricated
      micro-offsets derived from that onset.
- [x] Word order, positive durations, text, and segment count remain stable when alignment
      evidence is missing or ambiguous.
- [x] Candidate timing scores count distinct vocal evidence and preserve explicit user
      selections.
- [x] Any section-detection change is covered by both a positive field-shaped fixture and
      regression cases for ordinary pauses, repeated hooks, and short bridges.
- [x] Review notes distinguish landed accuracy improvements from larger model/data work
      that still requires a labeled audio corpus.

## Review

- Replaced independent nearest-onset snapping and corroboration with one monotonic,
  one-to-one matcher. Cached analyses showed repeated 20 ms word-start artifacts; regression
  tests now prove one burst cannot move or corroborate several words.
- Selected Lyric Blend candidates now own their word-derived start/end bounds. Rejected
  candidates no longer expand the selected lyric's playback, phrase, or chord-placement window.
- Vocal onset/VAD energy now combines stereo channels by RMS, preserving opposite-polarity
  vocal energy. Whisper requests use automatic language detection; engine/grouping versions
  were bumped so existing analyses do not retain stale English-forced or post-processing output.
- Structure matching preserves chord order while tolerating one passing chord. Static harmony
  no longer supplies false phrase-period evidence. Known sung-but-untranscribed spans are
  explicit form regions and cannot be labeled Instrumental or promoted to Solo.
- Timeline/structure caches now key the complete derived input, so chord, lyric, beat, key,
  duration, and missed-vocal edits cannot leave stale placement data behind.
- Field inventory: seven persisted song documents plus cached analyses/stems were inspected.
  Several cached songs contained repeated ~20 ms adjacent word starts, directly supporting the
  onset-assignment regression. The opt-in chord corpus was not run because no labeled corpus
  environment was configured.
- Verification: focused accuracy suites passed 199 tests with one environment-dependent skip;
  full `swift test` passed 642 tests with seven skips and zero failures. Debug `xcodebuild`
  succeeded for both `SongWorkbench` on macOS and `SongWorkbenchiPad` on generic iOS.
- Next accuracy layer: persist a reviewed beat/bar-referenced performance map with section
  confidence and contributing cues, then export JSON/CSV markers plus melody/drum/chord/bass
  MIDI and aligned stems. Its boundary detector should fuse downbeat-synchronous chroma,
  bass motion, drum accents, stem activity, and vocal/lyric evidence and be evaluated against
  a labeled corpus. Vocal F0/melisma extraction, drum-event transcription, meter unification,
  candidate confidence/consensus, and ASR-preserving VAD refinement remain separate work.

---

# iPad analysis stability and performance (2026-07-20)

## Plan

- [x] Trace the current iPad-only execution path after the existing 2.5-second stem model,
      streamed stem writer, ONNX session release, and serialized transcription/harmony changes.
- [x] Identify every heavyweight model/session/buffer retained across stage boundaries and
      distinguish peak-memory overlap from cumulative allocator high-water behavior.
- [x] Add bounded instrumentation for stage wall time, resident-memory checkpoints, model/session
      lifetime, and cancellation so the next device run produces actionable evidence.
- [x] Add deterministic tests for resource release and iPad stage scheduling; implement only
      evidence-backed lifetime/concurrency fixes without removing stems or analysis stages.
- [x] Verify focused and full tests plus macOS/iPad builds; document the exact connected-device
      reproduction and jetsam/log collection procedure.

## Acceptance criteria

- [x] Separation inference resources are released on success, failure, and cancellation before
      transcription or harmony can load another heavyweight model.
- [x] iPad never overlaps stem inference, transcription, and harmony model execution.
- [ ] Long songs do not accumulate whole-song decoded input, model output, or waveform buffers
      beyond the bounded windows required by the active stage.
- [x] Logs identify the active stage, elapsed time, and resident-memory checkpoint immediately
      before and after each heavyweight model lifetime.
- [x] No corpus or stem coverage is reduced to make the run fit.

## Review

- Root causes addressed: ONNX construction is deferred past transcription-only/cache-hit paths;
  stem and ASR resources release on every exit; replacement analyses drain the old task before
  loading another model; AppModel preflight/blend work is retained, cancellable, and generation
  guarded; package verification is cached within the process; click synthesis uses one bounded
  sample; and normalization no longer duplicates full-song mono/stereo arrays.
- `analysis-performance` logs now record physical footprint, elapsed time, stage transitions,
  model load/release, prepared audio, quarter-chunk progress, and output finalization.
- Deterministic regressions cover deferred construction, stem release on success/failure/cancel,
  serialized replacement runs, ASR cancellation/release, package-status reuse, and constant-size
  click allocation.
- Verification: `swift test` passed 653 tests with 7 skipped and 0 failures; strict Swift format,
  `git diff --check`, macOS Debug build, and generic iOS Debug build all passed.
- Connected-device validation is pending because the registered iPad
  `DF63930D-D084-577A-ACA6-8311FEB0FE03` was unavailable. Launch with
  `xcrun devicectl device process launch --device DF63930D-D084-577A-ACA6-8311FEB0FE03
  --terminate-existing --console com.local.SongWorkbench.iPad`, then collect diagnostics with
  `xcrun devicectl diagnose --devices DF63930D-D084-577A-ACA6-8311FEB0FE03
  --archive-destination /tmp/songworkbench-ipad-diagnostics.zip --no-finder`.
- Remaining scaling risks: full-song separation decode/resampling and output arrays, repeated
  vocal-stem scans, harmony working arrays, and stem-writer conversion/I/O. Do not enable smaller
  ONNX arenas without device A/B evidence because allocator retention and inference throughput
  trade off directly.

---

# ChordPro Instrumental Row Width (2026-07-21)

## Plan

- [x] Reproduce the rendering asymmetry in the ChordPro App Preview layout code.
- [x] Move instrumental row width math into a small tested helper.
- [x] Scale rhythmic instrumental rows toward lyric readability width while preserving fallbacks.
- [x] Run focused tests and a build/check appropriate for a SwiftUI layout change.

## Acceptance criteria

- [x] Equal-duration instrumental rows render closer to lyric rows in rhythmic ChordPro preview.
- [x] Instrumental chord, beat-dot, ball, strip, and frame widths keep using the same row width.
- [x] Non-rhythmic or unknown-duration chord-only rows keep the old character-extent fallback.
- [x] Regression tests cover the width calculation.

## Review

- Root cause: lyric rows can expand past raw `duration * pixelsPerSecond` because word positions
  are nudged apart to avoid text collisions, while instrumental rows had no equivalent readability
  floor and stayed on the raw time width.
- Fix: `ChordProPreviewLineLayout.instrumentalWidth` now gives rhythmic chord-only rows a modest
  lyric-like scale (`1.35x`) over their real duration, while preserving wider chord-label extents
  and the old fallback for non-rhythmic/unknown-duration rows. Existing chord, beat-dot, ball,
  waveform strip, and frame calculations all still consume `instrumentalTimeWidth`.
- Verification: `swift test --filter ChordProPreviewLineLayoutTests` passed 3 tests; strict
  Swift format lint passed for touched Swift files; `git diff --check` passed for touched files;
  macOS Debug `xcodebuild -project SongWorkbench.xcodeproj -scheme SongWorkbench -configuration
  Debug build` succeeded.

---

# ChordPro Read-Only Instrumental Row Width (2026-07-21)

## Plan

- [x] Trace why the ChordPro tab still renders compact instrumental rows after the Review fix.
- [x] Add a tested display-row helper for read-only ChordPro line rendering.
- [x] Expand generated chord-only bar-grid rows in the read-only view while preserving normal
      lyric rows.
- [x] Run focused tests, format/diff checks, and the app build.

## Acceptance criteria

- [x] Chord-only bar-grid rows in the ChordPro tab render wider than their compact source text.
- [x] Chords stay aligned with the expanded bar-grid lyric row.
- [x] Sung lyric rows continue to render with spec-exact column placement.
- [x] Focused regression tests cover chord-only expansion and normal lyric preservation.

## Review

- Root cause: the ChordPro tab uses `ChordProReadOnlyView`, a separate spec-only renderer that
  only had compact `.cho` character columns. The Review fix changed `ChordProAppPreview` timing
  width and therefore did not affect this path.
- Fix: `ChordProReadOnlyLineRenderer` now expands generated chord-only bar-grid rows by `2x`
  display columns and applies the same scaled columns to the chord row. Normal sung lyric rows
  keep the existing `ChordRowStringBuilder` output and lyric text unchanged.
- Verification: `swift test --filter ChordProReadOnlyLineRendererTests` passed 2 tests; strict
  Swift format lint passed for touched Swift files; `git diff --check` passed for touched files;
  macOS Debug `xcodebuild -project SongWorkbench.xcodeproj -scheme SongWorkbench -configuration
  Debug build` succeeded.

---

# Backlog Parallel Cleanup (2026-07-21)

## Plan

- [x] Reconcile stale unchecked items where later review sections already document completed work.
- [x] Finish the ChordPro timeline-width backlog item that remains after the Review/ChordPro
      display-width fixes, especially chord-only outro/end-bound collapse.
- [x] Attack one concrete iPad long-song memory risk without reducing analysis coverage.
- [x] Integrate sub-agent results, run focused tests/builds, and update this review with evidence.

## Acceptance criteria

- [x] `tasks/todo.md` unchecked items reflect real remaining work, not stale pre-review checkboxes.
- [x] Any code changes are covered by focused tests at the affected service/layout seam.
- [x] iPad memory work improves boundedness or logs a measured blocker with exact next command.
- [x] Final verification includes format/diff checks and the relevant macOS/iOS build or a
      documented external blocker.

## Review

- Reconciled stale unchecked boxes in the 2026-07-04 lyric/chord fix plan: the current code has
  `tailLooksDegenerate`, `maxSignalTightening = 3.0`, onset-aware decoder penalties, guarded
  chord-onset snapping, regression coverage, and cache-version bumps. The remaining open item is
  live app re-analysis of Settle Down plus one more song.
- Reconciled stale unchecked boxes in Task #47 W1: the current code has `BarMeter`,
  metric-position switch factors, the `reduce-16-metric-switch-penalty` cache suffix, the manual
  offline validation harness, and unit tests. The remaining open item is live Mac app
  re-analysis/Structure-tab verification.
- Reconciled the pure-time row-axis section: measurement and mitigation choice were already
  documented as completed/deferred, and `chordOnlyLineWindow` now falls back to beat-grid/song
  extent for outro chord-only rows. The deeper `rhythmicWordXs` pure-time rewrite remains open
  by design because the data showed many lyric word collisions at a fixed 100 px/s scale.
- Added one bounded iPad improvement: `AudioFileAnalysisService.vocalActivitySummary` derives
  vocal intervals and the vocal waveform from a single vocals-stem decode instead of scanning the
  same full stem twice when a separated song is opened. This reduces repeated full-stem work but
  does not close the broader whole-song buffer criterion.
- Device status: `xcrun devicectl list devices` sees the registered iPad
  `DF63930D-D084-577A-ACA6-8311FEB0FE03` as `unavailable`, so physical iPad launch/profiling is
  still externally blocked. The iPhone is connected, but it does not satisfy iPad validation.
- Verification: `swift test --filter ChordProPreviewLineLayoutTests` passed 5 tests;
  `swift test --filter PracticeWorkspaceTests/testVocalActivitySummaryMatchesSeparateVocalStemPasses`
  passed; strict Swift format lint and `git diff --check` passed for touched files; full
  `swift test` passed 661 tests with 7 skipped and 0 failures; macOS Debug build succeeded;
  generic iOS Debug build for `SongWorkbenchiPad` succeeded.

---

# Robust Stem Refinement Pipeline (2026-07-28)

## Plan

- [x] Extend separation results so engines can return a full stem manifest, not only legacy
      `StemFiles`.
- [x] Add a `StemRefinementEngine` seam and a pipeline wrapper that runs base separation then
      optional desktop refiners.
- [x] Store recipe identity in the produced manifest so base six-stem and refined recipes can be
      distinguished by source, model, refiner list, taxonomy, and format.
- [x] Keep legacy six-stem output and cache behavior unchanged when no refiners are configured.
- [x] Add tests proving the wrapper runs refiners in order, preserves legacy stems, writes child
      assets into the manifest, and records recipe identity.
- [x] Re-run focused tests, full tests, lint, diff check, and macOS/iPad builds.

## Acceptance criteria

- [x] Existing separators still compile and return legacy-compatible `StemFiles`.
- [x] A configured desktop refiner can add children such as `drums.kick` without changing
      downstream persistence code.
- [x] A no-refiner configuration produces the same legacy manifest and does not alter current
      six-stem behavior.
- [x] Refiner failure is explicit and does not silently persist a partial refined manifest as
      current.
- [x] Verification evidence is recorded here.

## Review

- Added `StemRefinementEngine`, `StemRefinementRequest`, `StemRefinementResult`, explicit
  `StemRefinementError`, and `StemRefinementPipelineEngine`. The wrapper preserves the base
  `StemFiles` alias, writes refinement assets under `Refined/<recipe>/<refiner>`, validates every
  declared output file, merges descriptors/assets into `StemSetManifest`, and records a stable
  recipe identity.
- `SongAnalysisPipeline` now accepts configured stem refiners and `SeparationStage` constructs the
  effective per-run engine once the source digest is known. Refined separation records use
  `stem-recipe-<hash>` while no-refiner runs retain the legacy six-stem cache path.
- Added manifest-aware separation cache validation so refined outputs are reused only when the
  source digest, engine/model identity, recipe cache key, and every manifest asset path match.
- Added regression coverage for refiner success, missing output failure, manifest recipe cache
  hits/misses, and end-to-end persistence through the separation stage.
- Verification: focused stem/cache/pipeline tests passed 52 tests; full `swift test` passed 679
  tests with 7 skipped and 0 failures; strict Swift format lint and `git diff --check` passed;
  macOS Debug `SongWorkbench` build succeeded; generic iOS Debug `SongWorkbenchiPad` build
  succeeded.

---

# Extensible Stem Decomposition Foundation (2026-07-28)

## Plan

- [x] Add an extensible stem identifier, descriptor, asset, and manifest model beside the
      legacy six-source `StemKind` model.
- [x] Bridge legacy `StemFiles` and `StoredStemFiles` into that manifest so old documents
      remain readable.
- [x] Add a stem mix graph that selects one active parent/child frontier for playback/export.
- [x] Preserve existing `StemKind` mixer calls while allowing ID-based mix state for future
      stems such as `drums.kick` and `guitar.lead`.
- [x] Add focused tests for legacy compatibility, unknown-ID preservation, and parent/child
      non-duplication.
- [x] Run focused tests and a build-oriented verification pass.

## Acceptance criteria

- [x] A legacy six-source separation can be represented as a `StemSetManifest`.
- [x] A refined stem set can include children without changing the fixed `StemKind` enum.
- [x] Playback/export planning includes child stems instead of their parent when children exist,
      never both.
- [x] Mixer persistence keeps old documents decoding while preserving unknown future stem IDs.
- [x] Cache identity has a named recipe shape that can distinguish future model/refiner output
      variants.

## Review

- Added `StemID`, `StemDescriptor`, `StemAsset`, `StemRecipeIdentity`, `StemSetManifest`, and
  `StemMixGraph` beside the legacy `StemKind`/`StemFiles` model. Legacy six-source files now
  bridge into a manifest without adding child cases to `StemKind`.
- Added `StoredStemSetManifest` and live `AppModel.stemSet` persistence so future child stems
  such as `drums.kick` and `guitar.lead` can survive document load/save while `stems` remains the
  legacy alias.
- Updated stem playback and mix export to use the graph's active frontier: when children have
  audio, the parent is excluded so playback/export do not double the signal.
- Extended `StemMixerModel` to persist unknown string stem IDs while preserving the existing
  `StemKind` calls and legacy mixer JSON decoding.
- Tightened separation cache currency to include model version and added a recipe cache key that
  includes source digest, engine/model identity, segment config, refiners, taxonomy version, and
  output format.
- Verification: focused stem/cache/playback/export tests passed 50 tests; full `swift test`
  passed 674 tests with 7 skipped and 0 failures; strict Swift format lint and `git diff --check`
  passed; macOS Debug `SongWorkbench` build succeeded; generic iOS Debug `SongWorkbenchiPad`
  build succeeded after rerunning serially because the first concurrent iPad build hit Xcode's
  locked build database.

---

# Desktop Full / iPad Reduced Capability Split (2026-07-22)

## Plan

- [x] Introduce an explicit analysis capability profile for desktop-full and iPad-reduced runs.
- [x] Route stem model selection and transcription-mode availability through that profile.
- [x] Replace scattered platform execution branching with a testable pipeline execution policy.
- [x] Surface the active capability tier in model UI without offering unavailable iPad-heavy tools.
- [x] Add focused tests for profile defaults, mode filtering, and serial/concurrent execution.
- [x] Run focused tests plus macOS and generic iOS builds.

## Acceptance criteria

- [x] Desktop profile keeps the full 7.8s HTDemucs download path, Whisper accuracy mode, and
      concurrent lyric/harmony stages.
- [x] iPad profile keeps the bundled 2.5s stem model path, excludes Whisper accuracy, and runs
      lyric/harmony stages serially to reduce peak memory.
- [x] Future advanced tracks such as lead/backing vocals, drum-piece stems, symbolic notes, and
      performance events have named capability flags instead of new platform checks.
- [x] Tests can validate desktop vs iPad behavior on a single host by injecting the profile.

## Review

- Added `AnalysisCapabilityProfile` with desktop-full and iPad-reduced product tiers, explicit
  stem tier, allowed transcription modes, heavy-stage execution policy, and future performance
  track flags for lead/backing vocals, drum pieces, notes, phrases, song parts, and chords.
- `SongAnalysisPipelineFactory` now assembles engines through the profile: desktop keeps the full
  downloaded HTDemucs and Whisper accuracy path; iPad keeps the bundled reduced HTDemucs path and
  does not build a Whisper accuracy engine.
- `SongAnalysisPipeline` now receives an injectable execution policy. iPad-reduced serializes
  transcription and harmony to avoid overlapping heavy working sets; desktop-full keeps concurrent
  independent stages.
- `AppModel`, onboarding, and the Models popover now filter required/installable packages and
  primary Lyric Blend modes through the active profile. The UI shows the active tier as
  `Desktop Full` or `iPad Reduced`.
- Verification: focused capability/scheduling tests passed 7 tests; full `swift test` passed
  665 tests with 7 skipped and 0 failures; strict Swift format lint and `git diff --check`
  passed; macOS Debug `SongWorkbench` build succeeded; generic iOS Debug `SongWorkbenchiPad`
  build succeeded.

---

# UI Contrast and Bass String Guidance (2026-07-22)

## Plan

- [x] Add a semantic prominent-control tint whose white-label contrast meets WCAG AA.
- [x] Apply the control tint centrally while preserving the brighter analysis/data accent.
- [x] Derive an ergonomic standard four-string bass string for each detected bass pitch.
- [x] Include the recommended string in both timed and fallback Review bass-note labels.
- [x] Add focused regression tests and run formatting, test, and app-build verification.

## Acceptance criteria

- [x] White text on prominent blue controls has a contrast ratio of at least 4.5:1.
- [x] Existing waveform, chord, focus, and selection accents retain the current bright blue.
- [x] Displayed bass plucks name both the note and a playable recommended string.
- [x] Transposition updates both the note name and its recommended string.

## Review

- Added `swProminentControl` (`#1971C2`) and a shared `swProminentButtonStyle`; only filled
  command buttons use the darker tint, while `swAccent` remains `#339AF0` for analytical data,
  focus, and selection. A WCAG contrast regression test protects the white-label ratio.
- Review bass-note labels now include a lowest-fret recommendation for standard E-A-D-G tuning,
  for example `E (D string)`. This is fingering guidance; monophonic pitch does not identify the
  physical string used in the source performance.
- Verification: focused tests passed 11 tests; full `swift test` passed 667 tests with 7 skipped
  and 0 failures; strict Swift format lint and `git diff --check` passed; macOS Debug
  `SongWorkbench` and generic iOS Debug `SongWorkbenchiPad` builds succeeded.
