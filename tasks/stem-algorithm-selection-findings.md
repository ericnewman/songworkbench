# Per-instrument stem algorithm selection — investigation findings

Read-only code map, 2026-07-29. No code changed. Groundwork for a plan, not a plan.

---

## 1. What does stem splitting today

**One base model, one refiner.**

### Base: HTDemucs v4, 6-source, via ONNX Runtime

| | |
|---|---|
| Descriptor | `ModelCatalog.htdemucs` — `Sources/SongWorkbench/ModelCatalog.swift:4` |
| Package id / version | `htdemucs-6s-onnx` / `125b3e0` |
| Artifact | `demucsv4.onnx`, 246,148,867 bytes, sha256 `4bef152b…88b0d` |
| Source | `huggingface.co/MansfieldPlumbing/Demucs_v4_TRT` (full-graph ONNX export) |
| License | **CC-BY-NC-4.0** — "HTDemucs by Meta; full-graph ONNX export by MansfieldPlumbing" |
| Engine | `ONNXSixStemSeparationEngine` — `ONNXSixStemSeparationEngine.swift:4` |
| Runtime | onnxruntime, **CPU execution provider** |

Framing, overlap-add, validation and disk writing are *not* in the ONNX class — they live in
`CoreMLStemSeparationEngine` (`CoreMLStemSeparationEngine.swift:53`), which is misnamed: it is the
generic chunked separator. Any model that fits "stereo chunk in → N stereo sources out" plugs in as
a `StemChunkPredicting` (`CoreMLStemSeparationEngine.swift:20`). That is the real extension point.

**Parameters — all hardcoded**, in engine statics and the factory:

- `segmentFrames` = `343_980` (7.8 s) on macOS; `110_250` (2.5 s) on iPad, from a separate bundled
  re-export `demucsv4_2p5s` (`ONNXSixStemSeparationEngine.swift:7,15`)
- `overlapFrames` = `segmentFrames / 4`; `normalizesAudio: true` (`ONNXSixStemSeparationEngine.swift:60`)
- intra-op threads = cores−1 on macOS, capped at 4 on iPad for thermals (`:101-111`)
- CoreML execution provider is implemented but **deliberately off** — "reverted until it can be
  verified not to break separation output" (`SongAnalysisPipelineFactory.swift:77`)

Nothing here is user-reachable. The only variation is the coarse tier
(`AnalysisCapabilityProfile.stemSeparationTier`: `none` / `reducedSixStem` / `fullSixStem` /
`advancedDesktop`) plus one macOS-only `UserDefaults` toggle.

**Invoked from** exactly one place: `SeparationStage.run` (`AnalysisStage.swift:120`), which calls
`context.effectiveStemEngine.separate(…)`. Assembly is in `SongAnalysisPipelineFactory.makePipeline`
(`SongAnalysisPipelineFactory.swift:33-102`).

**Outputs.** Model source order is `[drums, bass, other, vocals, guitar, piano]`
(`ONNXSixStemSeparationEngine.swift:78`). Written as six 44.1 kHz stereo float32 WAVs named
`<kind>.wav`, plus a synthesized `accompaniment.wav` = `other + guitar + piano`
(`CoreMLStemSeparationEngine.swift:646-650`). Streamed to disk incrementally (`StreamingStemWriter`,
`:593`) so the whole song is never resident.

### Refiner: DrumSep (already a second, instrument-specific algorithm)

`ModelCatalog.drumsep` — `drumsep-onnx` v1.0.0, MIT, 335 MB, a Hybrid Demucs fine-tune. Splits the
**drums** stem into kick / snare / cymbals / toms (`ONNXDrumPieceSeparationEngine.swift:28-53`).
macOS + `advancedDesktop` tier + package installed, and optional — never blocks onboarding
(`ModelCatalog.optionalRefinementIDs`).

**This is the worked example for everything you're asking for.** The pattern exists and ships.

---

## 2. Pluggability — much better than expected

Coupling to the rest of the pipeline is **low**. The abstractions are already in place:

| Abstraction | File:line | What it gives you |
|---|---|---|
| `StemSeparationEngine` | `StemSeparation.swift:840` | base separator behind a protocol |
| `StemRefinementEngine` | `StemSeparation.swift:421` | per-instrument child separator |
| `NativeStemRefinementEngine` | `StemSeparation.swift:447` | in-process model, parent stem in → mapped child IDs out |
| `ExternalStemRefinementEngine` | `StemSeparation.swift:597` | subprocess + JSON manifest (macOS only) |
| `StemRefinementPipelineEngine` | `StemSeparation.swift:706` | composes base + ordered refiners |
| `StemRefinementEngineFactory` | `SongAnalysisPipelineFactory.swift:152` | registry of which refiners run |

**A stem taxonomy already exists.** `StemKind` (6 legacy kinds), and above it hierarchical `StemID`
strings with parent/child descriptors — `StemDescriptor`, `StemRole` (`source`/`refinement`/
`transcription`/`residual`), `StemAsset`, `StemSetManifest`, `StemMixGraph`
(`StemSeparation.swift:57-360`). **`StemID.guitarLead` and `.guitarRhythm` are already declared**
(`:91-92`) and unused — the intent is in the code, just unimplemented. The factory comment says so:
"guitar lead/rhythm remains unregistered until a verified model artifact exists"
(`SongAnalysisPipelineFactory.swift:164`).

**Cache identity already keys on the algorithm.** `StemRecipeIdentity`
(`StemSeparation.swift:138`) hashes `sourceDigest + base engine metadata + segment config +
refiner list + taxonomy version + output format` into a `cacheKey` / `stableStorageName`, validated
by `SeparationCachingPolicy.isStemSetCacheHit` (`SeparationCachingPolicy.swift:59`). Change the
algorithm and the key changes, so stems re-separate automatically and old ones never alias. **The
hardest correctness problem in this feature is already solved.**

**The one missing piece:** algorithm choice is resolved at *pipeline assembly* time from globals —
`AnalysisCapabilityProfile.current` (a computed static reading `UserDefaults`) — not from the
request. `SongAnalysisPipelineRequest` (`SongAnalysisPipeline.swift:169`) has no separation-config
field, and `SongAnalysisCoordinator.makePipeline` is a zero-argument closure
(`SongAnalysisCoordinator.swift:14`). The pipeline *is* rebuilt per run, so there is a natural seam
— it just takes no input today.

---

## 3. Downstream dependency — how stem quality reaches notes and chords

All of this is `HarmonyStage.run` (`AnalysisStage.swift:682-856`).

**Chord detection reads the GUITAR stem first — confirmed.**
`HarmonyAudioSourceSelector.select` (`HarmonyAudioSource.swift:35-40`) picks, in order:

```
guitar → piano → accompaniment → other → (full-mix fallback)
```

That single file goes to `AudioFileAnalysisService` (engine `native-vdsp-beat-chroma` v7,
`SongAnalysisPipeline.swift:162`) for chroma + beats. Native vDSP, no model.

**5-quality vocabulary — confirmed.** `ChordQuality` is exactly `major, minor, major7, minor7,
dominant7` (`ChordClassification.swift:4-10`). Nothing else is representable.

**0.8-beat filter — confirmed.** `ChordEventDurationFilter.merge(minimumBeatFraction: 0.8)` —
declared `KeyAwareChordFiltering.swift:104`, applied `AnalysisStage.swift:828`, same default at
`AudioFileAnalysisService.swift:729`.

**Note detection reads the BASS stem only.** `HarmonyStage.detectBassNotes`
(`AnalysisStage.swift:666-680`) runs `BassLineAnalyzer` (`BassLineAnalysis.swift:122`) on
`stems.bass`: decimate to 8 kHz, autocorrelation over 41–392 Hz, clarity gate 0.35, 5-frame median,
0.12 s minimum segment. Results are then reconciled against the final chord timeline
(`BassChordReconciler`, `AnalysisStage.swift:837`).

**Every stem feeds something.** The full propagation graph:

| Stem | Consumer | Effect of poor separation |
|---|---|---|
| guitar (→piano→accompaniment→other) | chroma → chord decode; `InstrumentOnsetDetector` onsets | wrong chords; missed/misplaced changes |
| bass | `BassLineAnalyzer` → bass notes; onsets → Viterbi switch cues (`AnalysisStage.swift:783`) | wrong notes, *and* degraded chord timing |
| drums | `DrumBeatGrid` beat lock (`:747`); `DrumAccentProfile` → downbeat/meter (`:793`) | the grid everything else quantizes to drifts |
| vocals | transcription, VAD, word-onset snapping (`AnalysisStage.swift:250,471`) | lyric timing and hallucination gating |

So stem quality is load-bearing well beyond the obvious path: a bad **drums** stem corrupts the beat
grid, which the 0.8-beat chord filter and every snap operate on.

**Internal evidence guitar is the weak stem already:** the iPad A/B note records "vocals/bass/drums
15-18 dB, guitar ~7 dB" (`ONNXSixStemSeparationEngine.swift:13`). Upstream also treats the 6-source
model's guitar/piano heads as experimental — worth confirming from the Demucs docs before planning
around it.

---

## 4. Data model & UI — where a selection would live

**Per-song persistence.** `StoredSongProject` (`PracticeProject.swift:51`) holds
`settings: PracticeSettings` + `analysis: SongAnalysisDocument?`, inside
`ProjectLibraryDocument` v3. Two candidate homes:

- `PracticeSettings` (`PracticeProject.swift:15`) — user *choices*. Already has a hand-written
  `init(from:)` that decodes-if-present with defaults, so adding a field is a solved, versionless
  migration. **This is the natural home.**
- `SongAnalysisDocument` (`SongAnalysisDocument.swift:347`, `currentSchemaVersion = 11`) — analysis
  *results*. Already records what produced the stems via
  `stemSet.recipeIdentity` (`StoredStemSetManifest`).

**Per-run plumbing.** `SongAnalysisPipelineRequest` (`SongAnalysisPipeline.swift:169`). The exact
precedent is `transcriptionMode` / `transcriptionDecodeRate`: set in `AppModel.runAnalysis`
(`AppModel.swift:1016`), read in the stage. A `separationRecipe` field would follow the same path —
except it must also reach `makePipeline`, which currently takes nothing.

**UI.** Model install/removal and the only existing separation control live in `ModelPackagesView`,
the "Models" popover — `AnalysisWorkspaceView.swift:409`, with the macOS-only *"Advanced stem
refinement"* toggle at `:433`. Per-song analysis actions are driven from `AppModel.runAnalysis`
(`AppModel.swift:1000`). First-run gate: `ModelOnboardingSheet` (`ContentView.swift:103`) blocks the
app until every `requiresModelPackage` model is installed.

⚠️ **A per-song picker re-introduces a pattern deliberately removed.** The per-song transcription
mode picker was dropped in backlog #11 in favor of "run every installed mode, let the blend UI be
the tuning" (`AppModel.swift:789-800, 824`). Worth deciding consciously whether per-song *algorithm*
choice is different in kind, or whether the same "run what's installed, pick after" shape applies.

---

## 5. Constraints that bound the option space

- **Local, offline, on-device.** No cloud path anywhere. macOS + iPadOS.
- **CPU only.** ORT CPU EP; CoreML/ANE provider written but disabled pending verification. Any
  candidate must be usable on CPU or come with the same verification burden.
- **Memory is the binding constraint, not speed.** macOS peaks ~2 GB. iPad has a hard ~3 GB
  per-process ceiling that forced the 2.5 s bundled re-export (7.8 s OOMs; 3.5 s tipped the cap —
  `ModelCatalog.swift:26`, `ONNXSixStemSeparationEngine.swift:9`). The last three commits are all
  memory work: free the ORT session after separation, stream stems to disk, serialize heavy stages.
  **Running several models per song on iPad is not free — it may not be possible at all.**
- **Timing is unmeasured for the current path.** The only recorded benchmark
  (`Benchmarks/STEM_SEPARATION.md`) is the *older 4-stem CoreML FP16* engine: 6.90 s model load,
  1.95 s cold for 60 s audio, vs 18.38 s for Python Demucs. There is **no recorded number for the
  6-stem ONNX CPU path in use today**, and iPad (2.5 s segments, 4 threads) is slower again. Get a
  real measurement before promising per-song algorithm switching.
- **Licensing: the base model is CC-BY-NC-4.0** (`ModelCatalog.swift:16`) — non-commercial. DrumSep
  is MIT. This constrains which alternatives are adoptable, and is worth a separate look regardless
  of this feature.
- **Model install.** `ModelPackageManager` downloads per component by URL with expected size +
  sha256 verification into per-version package directories; iPad's base model ships bundled instead
  (`bundledResourceNameiOS`). Adding an algorithm = a `ModelPackageDescriptor` + an engine + an
  entry in `ModelCatalog.all` + registration in the refiner factory. **Any new package must be
  listed in `optionalRefinementIDs` or it will block first-run onboarding for everyone.**

---

## Initial read: how hard is this?

**Adding one alternative instrument model: easy.** DrumSep proves the path end to end. A new ONNX
export that fits the chunked stereo-in/N-sources-out predictor needs a descriptor, a
`StemChunkPredicting`, and a `NativeStemRefinementEngine` registration. Half a day of code; the
work is sourcing and validating an artifact, not wiring.

**Making it selectable per song: medium.** Three concrete gaps:

1. `makePipeline` takes no arguments — needs to accept a per-run separation config
   (`SongAnalysisCoordinator.swift:14`, `SongAnalysisPipelineFactory.swift:22`).
2. Engine availability is entangled with `AnalysisCapabilityProfile` tiers *and* a macOS-only
   `UserDefaults` toggle *and* the onboarding gate. A per-song choice has to compose with tiers
   rather than fight them.
3. Downstream consumers read the **legacy flat `StemFiles`** (`stems.guitar`, `stems.bass`), not the
   hierarchical `StemSetManifest` — see `HarmonyAudioSource.swift:35`, `AnalysisStage.swift:673,767`.
   A guitar stem from a different model must still land at `guitar.wav`, or those selectors need
   reworking onto `StemID`. **This is the sharpest edge in the whole feature.**

Caching, provenance, staleness, and cache-key invalidation come **free** — `StemRecipeIdentity`
already covers them. That is the part that would normally sink this.

**Two things I'd want settled before building:**

- **Storage.** Every algorithm combination is a full extra stem set on disk (6 × stereo float32 WAV
  per song ≈ the source size × 6). Per-song, per-instrument choice multiplies that. There is no
  eviction policy today.
- **Is separation actually the bottleneck for chord accuracy?** The chord path also has a
  **5-quality vocabulary** (no sus, dim, aug, 6, 9, slash chords) and a mono chroma read of one
  stem. A song whose real chords are Asus4 or D/F♯ cannot be right no matter how clean the guitar
  stem is. A cheap A/B — same song, chords from `guitar` vs from `accompaniment` vs from the full
  mix — would tell you how much headroom separation quality actually has, for an afternoon's work
  and no new models. Worth doing first.
