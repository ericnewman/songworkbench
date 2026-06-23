# Key West Bar ChordPro

- [x] Inspect the MP3 and available local audio-analysis runtimes.
- [x] Produce a timestamped lyric transcription.
- [x] Determine the song key, meter, form, and chord changes.
- [x] Align chords with lyrics and create a valid ChordPro file.
- [x] Review uncertain lyrics/chords and verify ChordPro syntax.

## Review

- Local vocal-separation and targeted transcription passes resolved the opening
  lyric and ambiguous phrases such as "steal the show" and "island time."
- Harmonic analysis found concert Eb major at approximately 92 BPM. The chart
  uses capo 1 with D-major guitar shapes.
- Verified 89 chord placements, balanced standard section directives, required
  metadata, valid chord brackets, and a clean `git diff --check`.

# One Night on Broadway ChordPro

- [x] Inspect the MP3 and produce a timestamped lyric transcription.
- [x] Separate vocals from the accompaniment.
- [x] Determine the song key, tempo, meter, form, and chord changes.
- [x] Resolve uncertain lyrics with targeted transcription passes.
- [x] Align chords with lyrics and create a valid ChordPro file.
- [x] Verify ChordPro syntax and review the finished chart.

## Review

- Isolated-vocal and targeted transcription passes resolved the principal lyric
  ambiguities, including "setlists scattered in the rain," "curtains rise and
  hearts collide," and "marquee signs glowing in the dark."
- Harmonic analysis found concert Eb major at approximately 161 BPM. The chart
  uses capo 1 with D-major-family guitar shapes.
- Verified 102 chord placements, balanced standard section directives, ASCII
  content, required metadata, valid chord brackets, and a clean
  `git diff --check`.

# Summer on the Lake ChordPro

- [x] Inspect the MP3 and produce a timestamped lyric transcription.
- [x] Separate vocals from the accompaniment.
- [x] Determine the song key, tempo, meter, form, and chord changes.
- [x] Resolve uncertain lyrics with targeted transcription passes.
- [x] Align chords with lyrics and create a valid ChordPro file.
- [x] Verify ChordPro syntax and review the finished chart.

## Review

- Isolated-vocal and targeted transcription passes resolved the principal lyric
  ambiguities, including "everything we ain't," "bonfire nights," "midnight
  swims," and "sunny days and a little kiss."
- Harmonic analysis found concert Eb major at approximately 83 BPM. The chart
  uses capo 1 with D-major-family guitar shapes.
- Verified 85 chord placements, balanced standard section directives, ASCII
  content, required metadata, valid chord brackets, and a clean
  `git diff --check`.

# Somertime's Here with You ChordPro

- [x] Inspect the MP3 and produce an initial timestamped transcription.
- [x] Separate vocals using two independent Demucs models.
- [x] Determine the song key, tempo, meter, form, and chord changes.
- [x] Attempt lyric recovery with Whisper Large V3, Whisper Large V3 Turbo,
  Parakeet TDT, isolated stems, original-mix sections, and targeted passes.
- [x] Create a chord-accurate ChordPro file with unresolved lyrics marked.
- [x] Verify ChordPro syntax and review the finished chart.

## Review

- Harmonic analysis found concert Db major at approximately 117 BPM. The chart
  uses capo 1 with C-major-family guitar shapes.
- The lead vocal is heavily processed and remained low-confidence after two
  Demucs models, two Whisper variants, Parakeet TDT, isolated-stem passes, and
  original-mix section passes. Unresolved lyrics are explicitly marked rather
  than fabricated.
- Verified 71 chord placements, balanced standard section directives, ASCII
  content, required metadata, valid chord brackets, and a clean
  `git diff --check`.

# Full MP3 Catalog Batch

- [x] Inventory all supplied MP3s by hash, duration, and embedded title.
- [x] Deduplicate identical or alternate-export recordings.
- [x] Create a dedicated ChordPro output folder and preserve existing charts.
- [x] Process every remaining unique recording.
- [x] Validate every generated ChordPro file.
- [x] Generate a manifest covering source files, duplicates, confidence, and output.
- [x] Review low-confidence results and document the completed batch.

## Review

- Processed 33 supplied paths representing 32 unique audio hashes. The two
  encoded/unencoded timestamp copies of "Another day above ground" are
  byte-identical and share one chart.
- Produced 28 new ChordPro files in `ChordPro Catalog`. The four charts
  completed before the batch request remain in the workspace root and are
  recorded as skipped existing work in the manifest.
- The alternate "Summertime's here with you" recording produced a
  high-confidence transcript. The earlier processed-vocal "Somertime's Here
  with You" chart remains explicitly low-confidence.
- Validated 1,736 chord placements across all charts: ASCII content, required
  metadata, balanced brackets, valid chord names, and clean
  `git diff --check`. No processing failures remained.

# Guitar Tone Analysis

- [x] Analyze all 32 unique recordings, including the four previously charted songs.
- [x] Extract spectral, dynamics, and semantic audio features.
- [x] Classify clean, edge-of-breakup, overdrive, distortion, fuzz, and acoustic tones.
- [x] Describe likely guitar/amp/effect characteristics and practical approximations.
- [x] Export a Markdown table and sortable CSV.
- [x] Verify all 32 recordings are represented exactly once.

## Review

- Analyzed five distributed eight-second excerpts from each of 32 unique audio
  hashes using catalog-calibrated semantic similarity plus spectral and
  dynamics measurements.
- Exported the rehearsal-oriented table to `ChordPro Catalog/GUITAR_TONES.md`
  and `ChordPro Catalog/guitar-tone-table.csv`; retained measurements and model
  scores in `ChordPro Catalog/guitar-tone-analysis.json`.
- Verified 32 rows, 32 unique source files, 32 unique hashes, no blank fields,
  distinct labels for alternate versions, and a clean `git diff --check`.

# Reusable Transcription Tone Skill

- [x] Initialize a personal Codex skill for guitar-tone analysis.
- [x] Generalize the analyzer to accept arbitrary audio files and directories.
- [x] Add idempotent guitar-tone comment blocks for ChordPro charts.
- [x] Document tone analysis as a required transcription stage.
- [x] Validate the skill structure and smoke-test ChordPro embedding.

## Review

- Installed `analyze-guitar-tones` under `~/.codex/skills` with a portable
  analyzer, dependency list, conservative review guidance, and Codex UI
  metadata.
- The skill directs transcription work to analyze the source recording and add
  a marked five-line tone block near the ChordPro metadata header.
- Validated the skill with `quick_validate.py`, compiled the analyzer, checked
  the CLI, and proved that two insertions leave exactly one tone block.

# Those Were the Days / One More Moment in Time

- [x] Inventory both recordings by hash and confirm they are unique.
- [x] Transcribe vocals and determine key, tempo, meter, form, and chords.
- [x] Review uncertain lyrics and harmonic changes against the recordings.
- [x] Create two validated ChordPro charts with embedded guitar-tone blocks.
- [x] Update the catalog manifest, README, and tone-analysis exports.
- [x] Verify chart syntax, catalog consistency, and repository diffs.

## Review

- Demucs vocal separation plus Whisper Large V3 Turbo, Whisper Large V3, and
  Parakeet cross-checks resolved ambiguous phrases including "still wore them
  all," "call out your name," and "the hurt will fade."
- Both songs are in concert Eb and use capo-1 D-family guitar shapes. `Those
  Were the Days` is charted at 144 BPM; `One More Moment in Time` uses the
  81-BPM half-time pulse rather than the beat tracker's doubled 161-BPM result.
- Embedded mix-level tone blocks retain low confidence and describe layered
  sounds rather than forcing the analyzer's near-tied single-tone labels.
- Verified 98 chord placements, ASCII content, required metadata, balanced and
  valid chord brackets, exactly one tone block per chart, source hashes, 34-row
  tone exports, 34 unique manifest hashes, and a clean `git diff --check`.

# Lyrics-Only Catalog

- [x] Map all 34 unique recordings to their preferred reviewed ChordPro charts.
- [x] Generate one lyrics-only text file per recording.
- [x] Remove metadata, chords, section labels, and instrumental cues.
- [x] Preserve lyric line breaks with one blank line between sections.
- [x] Verify file count, duplicate-version naming, and text cleanliness.

## Review

- Generated 33 text files in `Lyrics Only`, excluding the continuous `Cross
  Cut Saw Live` recording. Alternate recordings retain their version suffixes.
- Used the reviewed concert arrangements for `Another Day Above Ground`, `Down
  South in Mexico`, and `Summer on the Lake`.
- Removed ChordPro metadata, chord symbols, section labels, instrumental cues,
  live-stage banter, and placeholder `Song title` transcript lines.
- Verified ASCII text, non-empty content, no residual ChordPro syntax or bar
  notation, no repeated blank lines, and a clean `git diff --check`.

# Summer on the Lake Chord Reanalysis

- [x] Reproduce missed changes with a beat-synchronized audio/chart comparison.
- [x] Determine beat, downbeat, key, and stable measure-level chord boundaries.
- [x] Test line quantization, inversions, downbeat offset, and chromatic-chord hypotheses.
- [x] Align the measured harmony to each lyric and instrumental section.
- [x] Revise the concert ChordPro chart without changing reviewed lyrics.
- [x] Validate chord syntax, section balance, and audio/chart change coverage.
- [x] Regenerate and verify the lyrics-only export.

## Review

- The supplied MP3 matches the previously processed source hash. Whisper word
  timestamps and a center-cancelled, beat-synchronized chroma pass aligned the
  first vocal downbeat at 24.06 seconds and confirmed 83 BPM in concert Eb.
- Root cause: the simple chart omitted the first two verse measures and reduced
  accompaniment changes to one chord per lyric line. The older concert chart
  contained many of the right passing chords but represented half-measure
  intro/outro changes as full measures.
- Rebuilt both charts from one arrangement: capo-1 D-family shapes in `Summer
  on the Lake.cho` and concert Eb chords in `Summer on the Lake - Concert
  Chords.cho`. Each now has 135 chord placements.
- Verified exact semitone transposition between charts, balanced ChordPro
  sections, valid chord syntax, one tone block per chart, measured-change
  regression assertions, refreshed lyrics-only output, and `git diff --check`.

# Summertime's Here with You Chord Reanalysis

- [x] Baseline the current chart's chord placements and missing instrumental coverage.
- [x] Align timestamped vocals to the beat/downbeat grid.
- [x] Compare original and center-cancelled half-measure harmony.
- [x] Test line quantization, shifted changes, passing chords, and tempo hypotheses.
- [x] Rebuild the preferred ChordPro chart with measured changes.
- [x] Validate ChordPro syntax and audio/chart change coverage.
- [x] Regenerate and verify the lyrics-only export.

## Review

- Confirmed the supplied MP3 matches the catalog's high-confidence alternate
  recording, not the earlier processed-vocal `Somertime` version.
- Timestamped Whisper vocals, a 99 BPM drum grid, and separated bass and
  accompaniment stems showed that most lyric lines span two measures while the
  old chart retained only one chord. It also omitted all instrumental bars.
- Rebuilt `ChordPro Catalog/Summertime's here with you.cho` with measured
  two-measure changes, passing/inversion chords, an eight-bar intro, twelve-bar
  solo, and twelve-bar outro. Coverage increased from 37 to 92 placements.
- Verified 34 instrumental measures, valid chord syntax, balanced section
  directives, exactly one mix-level tone block, synchronized manifest/README
  metadata, refreshed lyrics-only output, compiled helper scripts, no debug
  instrumentation, and `git diff --check`.

# SongWorkbench macOS App

- [x] Define the native Swift architecture and dependency evaluation plan.
- [x] Scaffold a standalone SwiftUI macOS package.
- [x] Implement the first vertical slice: import, select, play, seek, and pitch shift.
- [x] Add focused tests and verify a clean Swift build.
- [x] Benchmark candidate stem-separation and transcription libraries.

## Review

- Created a dependency-free macOS 14 SwiftUI package.
  The first vertical slice imports local audio, manages song selection, loads
  audio through AVFoundation, plays, pauses, seeks, and shifts pitch by integer
  semitones through `AVAudioUnitTimePitch`.
- Added tests for supported imports, duplicate filtering, pitch normalization,
  cents conversion, and real WAV loading/duration. All five tests pass, the
  optimized release build succeeds, and `git diff --check` is clean.
- Detailed architecture and acceptance criteria live in `PLAN.md`; the
  remaining backlog lives in `TODO.md`.

## Stem Separation Spike

- [x] Define a fixed benchmark input, measurements, and acceptance criteria.
- [x] Run the existing Python HTDemucs baseline on the fixed excerpt.
- [x] Review published Core ML model shape, size, platform, compute, and license data.
- [x] Add and test a model-independent Swift stem-separation contract.
- [x] Download and execute the Core ML model on the fixed excerpt.
- [x] Complete objective leakage/artifact comparisons against Python HTDemucs.

### Review

- The fixed input is a 60-second, 44.1 kHz stereo excerpt with SHA-256
  `47881ae99990322285269ca727ea39f66750d84b84a6171afe8c37a5273f3803`.
  Python `htdemucs` produced all four stems in 18.38 seconds.
- The published FP16 Core ML model is 144 MB compressed and 222 MB expanded,
  targets macOS 14, and requires CPU+GPU rather than the Neural Engine. The
  project is one commit with no established adoption history, so documentation
  alone is insufficient for adoption.
- Core ML processed the full excerpt in 1.95 seconds cold and 1.79 seconds warm
  after a 6.90-second compile/load. The process peaked at about 2.00 GB.
- Stem correlations against Python were 0.981...0.993; summed reconstruction
  measured 31.00 dB SNR versus Python's 30.84 dB. All four outputs were finite,
  stereo, 44.1 kHz, full duration, and below full scale.
- The model emits padded FP16 output despite Float32 documentation. The checked-in
  harness handles runtime data type/strides and releases each Core ML prediction
  in an autorelease pool. The decision is optional adoption, not default bundling.
- Added `StemSeparationEngine`, fixed four-stem output types, structured
  progress, and focused tests. Human listening remains a production-release
  gate because objective correlation does not measure perceptual artifacts.

# SongWorkbench Completion

## Phase 1: Practice Workspace

- [x] Persist projects and imported-song settings as versioned JSON.
- [x] Restore file access using security-scoped bookmarks with path fallback.
- [x] Generate and cache waveform envelopes.
- [x] Add editable loop regions and looped playback.
- [x] Add tempo control independent of pitch.
- [x] Export pitch/tempo-adjusted audio offline.
- [x] Add keyboard shortcuts and recent-project restoration.
- [x] Verify persistence, waveform, loop, tempo, and export behavior.

## Phase 2: Analysis Engines

- [x] Complete HTDemucs Core ML execution and objective quality comparison.
- [x] Benchmark Signalsmith Stretch against AVAudioUnitTimePitch.
- [x] Benchmark FluidAudio against the Whisper model path on CCS vocals and
  document the Swift runtime limitation.
- [x] Port beat/chroma/chord analysis to Accelerate/vDSP.
- [x] Record dependency licenses, sizes, platforms, and adoption decisions.

## Phase 3: Editing Workflow

- [x] Add four-stem mixer controls and mixed/stem export.
- [x] Add timestamped lyric editing.
- [x] Add editable chord timeline.
- [x] Add ChordPro import, transposition, and export.
- [x] Integrate analysis and editing into the selected-song workspace.

## Phase 4: Operations And Verification

- [x] Add cancellable background jobs with visible progress.
- [x] Cache expensive analysis results by source hash and engine version.
- [x] Add focused unit and integration tests for every service boundary.
- [x] Exercise the macOS UI with representative CCS recordings.
- [x] Run debug tests, optimized build, formatting checks, and final review.

## Final Review

- Imported and selected `Where the sun shines warm.mp3` from the SSD catalog;
  the app loaded its 3:20 duration and waveform without an error.
- Verified playback advances, seeking reaches 1:42, pitch changes to +2
  semitones, tempo changes to 110%, reset restores the original key and 100%,
  and Lyrics, Chords, ChordPro, and Stems tabs all render their expected state.
- A clean serial debug build executed 59 tests with zero failures. The release
  build also succeeded, and `git diff --check` found no whitespace errors.
- `swift format lint` completed and exposed an existing baseline of 4,319
  warnings: 4,142 are the package's four-space indentation conflicting with
  the tool's unconfigured two-space default; the remaining warnings are
  primarily line-length and line-break style. No broad formatting rewrite was
  made during verification.

# SongWorkbench Complete Analysis Feature Set

- [x] Configure the local project issue tracker, triage labels, and domain docs.
- [x] Reverse-engineer and publish a PRD from the implemented product,
  benchmarks, missing extraction workflows, and user-visible expectations.
- [x] Confirm deep-module boundaries and test scope before implementation.
- [x] Add managed, optional model installation with size, license, version,
  storage, integrity, and removal controls.
- [x] Implement the production HTDemucs Core ML stem-separation engine.
- [x] Implement fast-draft and accuracy lyric-transcription engines.
- [x] Add a single cancellable Analyze Song pipeline for stems, lyrics, tempo,
  chords, confidence, caching, partial results, retry, and error recovery.
- [x] Generate an editable ChordPro draft from timed lyrics and chord events.
- [x] Integrate analysis status, review state, model settings, and exports into
  the macOS UI without removing the existing manual editing workflows.
- [ ] Verify unit and integration contracts, model quality on the fixed corpus,
  cancellation/restart behavior, persistence migration, and representative UI.

### Production Validation Follow-up

- [x] Reproduce the FluidAudio offline model-loading failure.
- [x] Adapt the verified package layout to FluidAudio's local cache convention.
- [x] Verify Parakeet and Whisper against a representative imported recording.
- [x] Run the complete deterministic repository verification command.
- [x] Record final production and UI evidence below.

### Production Validation Review

- FluidAudio loaded the managed Parakeet package fully offline through a
  temporary compatibility symlink and transcribed the persisted 3:20 HTDemucs
  vocals stem in 21.7 seconds with non-empty timed output.
- Whisper Large V3 Turbo Q5_0 transcribed the same stem through its production
  CPU/BLAS path in 38.8 seconds with non-empty timed output; special/timestamp
  tokens and rapid phrase repetition are filtered at the engine boundary. CPU
  is the default because Metal buffer allocation can terminate the process
  before an in-process fallback is possible.
- The release UI recovered the persisted FluidAudio model-layout failure via
  Retry, reached `Finished transcription`, displayed `FluidAudio 2`, and
  populated editable timestamped lyrics. SentencePiece fragments are merged
  into words before lyric grouping, fixing visible splits such as `Tak e` and
  `sh ines`; the engine-version bump invalidates malformed cached results.
- `make verify` passed on the final source state: strict formatting,
  deterministic 33-file lyrics export, 89 tests with 2 opt-in production tests
  skipped, zero failures, and a serialized release build. The gate uses an
  isolated temporary SwiftPM scratch directory so interactive builds cannot
  mutate objects during verification linking.
- Full fixed-corpus transcription quality review remains part of the unchecked
  parent verification item; this follow-up proves both production engines and
  the representative UI recovery path on one imported recording.

## Audit Notes

- Current native beat/chroma analysis is executable from the Chords tab.
- Transcription and stem separation currently stop at protocol/domain types;
  no production engine is constructed or invoked by `AppModel`.
- The Stems tab imports pre-separated files, and the Lyrics tab only supports
  manual timestamped entry.
- Benchmarks support optional HTDemucs Core ML, Whisper accuracy mode with
  previous-text conditioning disabled, and FluidAudio as a fast draft mode.

# Git Repository Baseline

- [x] Define tracked source/catalog boundaries and ignore generated runtimes,
  source audio, downloaded models, caches, and editor state.
- [x] Add line-ending, editor, and Swift formatter policies.
- [x] Add repository documentation, local issue conventions, and agent guidance.
- [x] Add a single deterministic verification command and tracked pre-commit gate.
- [x] Add GitHub Actions CI, dependency updates, and a pull-request template.
- [x] Audit staged files for large binaries and credential patterns.
- [x] Verify the canonical 33-file lyrics export, 59 tests, and release build.

## Review

- The intended baseline contains only text source and catalog artifacts; its
  largest blob is approximately 65 KB. Audio, model packages, `.venv`, Swift
  build output, Finder metadata, editor swap files, and Python caches are ignored.
- `make verify` enforces strict Swift formatting, Python compilation, JSON
  validity, deterministic lyrics export, the complete Swift suite, and a release
  build. CI runs the same command on the current `macos-26` GitHub runner.
- The exporter removed 33 stale Finder/iCloud duplicate lyric files before the
  baseline was committed, leaving the intended 33-song export.

# Xcode Project

- [x] Inventory SwiftPM targets and pinned package/binary dependencies.
- [x] Add a reproducible macOS Xcode project manifest.
- [x] Generate a shared app-and-tests Xcode scheme.
- [x] Verify dependency resolution, debug build, and tests with `xcodebuild`.
- [x] Document Xcode generation and usage.

## Review

- `Project.swift` is the source of truth for the checked-in
  `SongWorkbench.xcodeproj`; `Dependencies/WhisperFramework/Package.swift`
  wraps the pinned remote XCFramework without vendoring its binary.
- Xcode resolved FluidAudio 0.15.4 and the local Whisper wrapper, then listed
  the app and test targets plus the shared `SongWorkbench` scheme.
- A clean arm64 macOS Debug build succeeded and produced a native `.app`.
  `xcodebuild test` executed 89 tests with 2 opt-in production tests skipped and
  zero failures.
- Command-line Xcode verification used an exact copy under `/tmp` because
  `NSFileCoordinator` blocked project reads from the iCloud-backed Documents
  path. The project content itself parsed and built without changes.

# ChordPro Retry Dependency

- [x] Reproduce a failed-transcription run followed by Lyrics-only Retry.
- [x] Make generated draft ChordPro depend on successful lyric/chord changes.
- [x] Preserve reviewed or manually imported ChordPro without silent overwrite.
- [x] Verify the regression test, full suite, and generated Xcode project.

## Review

- Root cause: Retry selected only the failed stage. After an initial
  transcription failure, ChordPro succeeded with a chord-only grid; retrying
  Lyrics updated timed lyrics but never rebuilt that downstream draft.
- The pipeline now expands Lyrics or Harmony retries to include ChordPro only
  when the existing chart is an unreviewed `chordpro-draft-builder` result.
  Reviewed and imported charts remain unchanged.
- The two-run regression first creates `{start_of_grid}`, retries only Lyrics,
  then verifies the result contains `[C]Hello world` and no grid. A companion
  test verifies a reviewed generated chart remains byte-for-byte unchanged.
- The generated Xcode scheme executed 91 tests with 2 opt-in production tests
  skipped and zero failures. The SwiftPM release build also succeeded.
- The complete repository gate could not run the unrelated catalog exporter:
  `Down South in Mexico - Concert Chords.cho` is currently blocked in a kernel
  read as an unavailable iCloud placeholder.

# Expanded Stem Separation

- [x] Audit the current stem model, output mapping, persistence, mixer, and tests.
- [x] Verify available expanded-model stem taxonomies and quality constraints.
- [x] Confirm whether piano and synth/organ keys may share one stem.
- [x] Add a versioned stem profile that supports legacy four-stem projects and
  expanded six-stem projects without requiring globally complete stem sets.
- [x] Integrate an expanded separation model producing vocals, drums, bass,
  guitar, piano/keys, and other.
- [x] Update persistence, import, playback, mixer, export, UI, and pipeline cache
  validation to use the stems present in the selected profile.
- [x] Add migration and output-mapping regression tests, then verify the SwiftPM
  and generated Xcode builds and test suites.

## Diagnosis

- The installed Core ML HTDemucs package has exactly four outputs: vocals,
  drums, bass, and other. Guitar and piano/keys are therefore intentionally
  combined in other; adding UI tracks cannot separate them.
- Bass already has a dedicated model output and is mapped to `bass.wav`. Audible
  bass in other may be source leakage, but the code does not deliberately merge
  bass with other.
- Official Demucs provides an experimental six-source profile adding guitar and
  piano. It does not provide a separate synth/organ keys class, and its piano
  output is documented as having substantial bleed and artifacts.

# ChordPro App Preview

- [x] Add a parser-backed preview presentation model with testable lyric anchor
  positions and common metadata/section directive handling.
- [x] Add an Edit/Preview segmented control without changing editor behavior or
  persisting view-only state.
- [x] Render colorized chord symbols above their anchored lyric positions in a
  horizontally and vertically scrollable lead-sheet view.
- [x] Keep malformed source editable and surface its parse error in Preview.
- [x] Add focused presentation tests and verify the full SwiftPM and generated
  Xcode build/test paths.

## Review

- The ChordPro tab now has a local Edit/App Preview segmented control. Edit
  retains the existing `TextEditor`; App Preview does not mutate or persist the
  source or selected mode.
- The parser-backed presentation model preserves lyric character columns,
  removes display-only bracket escapes, and presents title, artist/subtitle,
  key, capo, tempo, comments, common section directives, and unknown directives.
- The lead-sheet renderer uses monospaced lyric metrics to anchor blue chord
  symbols above the exact lyric positions and supports two-axis scrolling.
  Malformed ChordPro produces a located preview error while Edit remains usable.
- Three focused presentation tests passed. Full SwiftPM and generated Xcode
  suites each executed 94 tests with 2 opt-in production tests skipped and zero
  failures. A built-app UI check confirmed mode switching and chord-over-lyric
  alignment on `Jessie-Was-a-Dead-Man`.

# Shared Practice Transport

- [x] Add a persisted detected musical key with deterministic transposition and
  backward-compatible analysis-document decoding.
- [x] Upgrade stem playback with duration, current time, seek, pitch, and speed
  while preserving synchronized stems and mixer gain/mute/solo behavior.
- [x] Add explicit active playback-source coordination so recording and stem mix
  cannot play simultaneously and shared transport actions target the right source.
- [x] Move progress, pitch, speed, and reset controls into the four-tab workspace
  card and make waveform/playback commands follow the active source.
- [x] Show detected key at original pitch and the resulting transposed key after
  semitone adjustments, with a clear unavailable state before analysis.
- [x] Add key, stem transport, source-coordination, and migration regression tests.
- [x] Regenerate the Xcode project and verify SwiftPM, Xcode, and representative UI.

## Review

- The four-tab workspace card now owns one stable playback surface containing
  active-source progress, seek, pitch, speed, and reset controls. The old
  duplicate progress and adjustment controls were removed from the page header.
- `PlaybackSource` coordinates recording and stem-mix playback. Switching sources
  transfers the current source time, pauses the previous engine, and routes play,
  pause, skip, seek, waveform progress, and add-at-playhead actions consistently.
- Stem playback now routes all players through one time-pitch unit and publishes
  duration/current time while retaining per-stem gain, mute, and solo controls.
- Harmony analysis persists a major/minor `MusicalKey`; older documents infer one
  from stored chord events. The pitch control displays the original key and, when
  shifted, the resulting key, such as `A minor → Bb minor`.
- SwiftPM and generated Xcode suites each executed 101 tests with 2 opt-in
  production tests skipped and zero failures. Built-app verification confirmed
  relocated controls, adjusted-key updates, Stem Mix source selection, moving
  progress/time, waveform tracking, and pause behavior.

# Six-Source Stem Separation

- [x] Replace the four-source model package with managed `htdemucs_6s` ONNX artifacts and runtime.
- [x] Expand the stem domain and persistence to vocals, drums, bass, guitar, piano, and other with four-stem backward compatibility.
- [x] Make chunked separation map, normalize, persist, and recover all six model outputs.
- [x] Update playback, export, import, mixer, and harmony accompaniment selection for six stems.
- [x] Add migration and six-source regression coverage before implementation is considered complete.
- [x] Verify focused tests, full SwiftPM/Xcode suites, model installation, and representative six-stem inference.

## Review

- Production separation now uses a managed full-graph `htdemucs_6s` ONNX model
  through ONNX Runtime with Core ML partitioning, whole-song normalization,
  343,980-frame chunks, 25% overlap, and explicit model order mapping.
- The six persisted/mixed outputs are vocals, drums, bass, guitar, piano, and
  other. Legacy four-stem documents still decode and play; rerunning Stems
  detects old model provenance and regenerates six outputs. Synth/organ keys
  remain in `other` because the model has no keys class.
- Harmony analyzes a generated guitar+piano+other accompaniment composite, not
  vocals or only the residual `other` output.
- The verified 235 MB model was installed under the app's managed model store.
  A real model chunk produced six finite stereo tensors in 27.193 seconds; an
  end-to-end 12-second song excerpt wrote six readable WAV stems plus the
  accompaniment composite in 38.032 seconds.
- SwiftPM: 109 total, 4 environment-gated skips, 0 failed. Generated Xcode/macOS:
  109 total, 105 passed, 4 skipped, 0 failed. Strict formatting and
  `git diff --check` pass.

# Stem Audio Quality Regression

- [x] Reproduce the reported poor stem quality with a representative saved six-stem song.
- [x] Measure objective stem quality signals: reconstruction error, clipping/headroom, per-stem levels, and source mapping plausibility.
- [x] Identify whether the regression is preprocessing/postprocessing, output mapping, runtime backend, or model choice.
- [x] Implement the smallest root-cause fix and add a regression test at the stem-engine seam.
- [x] Verify with focused tests, full SwiftPM tests, formatting, and representative audio metrics.

## Review

- Root cause: ONNX Runtime Core ML execution-provider partitioning degraded the
  full-graph `htdemucs_6s` output. On a 12-second `Where the sun shines warm`
  excerpt, Core ML output failed reconstruction with residual RMS `0.1797`
  against source RMS `0.3021`, and the vocal stem was near-empty at `-41.22 dB`
  RMS.
- Fix: production `ONNXSixStemSeparationEngine` now defaults to ONNX Runtime CPU
  execution and records engine identity as `onnxruntime-cpu-htdemucs-6s` version
  `2`. Core ML remains explicit test opt-in only.
- Existing bad six-stem cache entries are invalidated by requiring separation
  cache hits to match engine identifier, engine version, model identifier, six
  source availability, and existing output files.
- Restored projects with stale/mismatched stem provenance now keep the file
  references but mark the Stems stage stale, unload stem playback, and show a
  Stems-tab warning instead of allowing corrupted saved stems to play.
- Added a real-model reconstruction regression gate. CPU ONNX on the same
  excerpt passed with residual RMS `0.0323` (`-30.45 dB`) against source RMS
  `0.3021`, and summed stems matched source level (`-10.55 dB` vs `-10.40 dB`).
- Verification: CPU real-model focused test passed; Core ML negative-control
  failed the new reconstruction assertion; separation cache invalidation and
  stale-restored-stem focused tests passed; `swift test --jobs 1` passed 111
  tests with 4 environment-gated skips; generated Xcode/macOS suite exited 0;
  strict Swift format, `git diff --check`, and debug-log grep were clean.

# Main Window Playback Layout

- [x] Center the selected song title across the main detail window instead of inside the left control column.
- [x] Move play/pause and skip controls into the main card Playback section, centered on the Playback title row above the time/seek indicator.
- [x] Keep waveform zoom usable by making zoomed waveform content horizontally scrollable.
- [x] Add an obvious loop-clear action in the waveform panel.
- [x] Verify SwiftPM tests, generated Xcode/macOS tests, formatting, and diff hygiene.

## Review

- The selected song title and filename now sit in a full-width centered header
  above the left analysis column and right workspace card.
- The duplicate left-column transport buttons were removed. Back 10, Play/Pause,
  and Forward 10 now live in the main card's Playback header row, centered
  above the source/time indicator and seek slider.
- The waveform panel keeps the zoom slider and wraps the waveform in an explicit
  horizontal scroll view with visible scroll indicators. A Clear Loop button is
  always available in that panel and disabled when no loop is selected.
- Verification: focused playback source test passed; `swift test --jobs 1`
  passed 111 tests with 4 environment-gated skips; generated Xcode/macOS suite
  exited 0; strict Swift format, `git diff --check`, and debug-log grep were
  clean.

# Waveform Header Layout

- [x] Reproduce the narrow-column waveform header compression from the current view code.
- [x] Split title/actions and zoom controls into stable horizontal rows.
- [x] Verify build, formatting, warning output, and diff hygiene.

## Review

- Root cause: the waveform panel used a single `HStack` for the title, Clear
  Loop button, Zoom label, slider, and value inside the fixed 330-point left
  column. SwiftUI compressed the title label vertically before preserving the
  slider width.
- The waveform header now uses two rows: title plus Clear Loop on the first
  row, and Zoom plus a flexible slider and fixed-width value on the second row.
  The title is single-line with a small scale fallback, so it no longer wraps
  into stacked letters.
- Verification: strict Swift format on `ContentView.swift` passed; generated
  Xcode Debug build succeeded; build warning/error grep was clean; `git diff
  --check` passed.

# Incremental Transcription Accuracy

- [x] Add a middle transcription quality profile between Fast Draft and Accuracy.
- [x] Keep Fast Draft behavior/cache compatibility unchanged.
- [x] Route the new profile through distinct engine configuration and provenance.
- [x] Verify focused tests, build behavior, formatting, and diff hygiene.

## Review

- Added `Balanced Draft` as a third transcription mode between Fast Draft and
  Accuracy.
- Fast Draft remains the existing Parakeet profile with
  `melChunkContext = false`, preserving prior cache behavior and speed.
- Balanced Draft uses the same installed Parakeet model but enables
  `melChunkContext = true`, FluidAudio's boundary-continuity path, without
  switching to the slower Whisper Accuracy engine.
- The pipeline constructs distinct Fast and Balanced Parakeet engines, routes
  `TranscriptionMode.balancedDraft` separately, and records
  `balancedDraft` in transcription provenance/cache configuration.
- Verification: focused profile/routing tests passed; `swift test --jobs 1`
  passed 118 tests with 4 environment-gated skips; generated Xcode Debug build
  succeeded; strict Swift format, build warning/error grep, `git diff --check`,
  and debug-log grep were clean.

# Global App Rename to SongWorkbench

- [x] Rename app/product/scheme/module-facing identifiers to `SongWorkbench`.
- [x] Update user-visible app name, default bundle IDs, storage paths, tests, and docs.
- [x] Regenerate Xcode project and verify SwiftPM/Xcode build behavior.
- [x] Update durable project notes and release checklist.

## Review

- Renamed the app directory, SwiftPM package/product/target/module, test target,
  Tuist project, generated Xcode project/workspace, app target, scheme,
  executable, display name, default bundle identifiers, entitlements file, and
  source/test module directories to `SongWorkbench`.
- Updated docs, release commands, Makefile, repository verification script,
  `.gitignore`, and domain context paths/names.
- Added compatibility migration for existing local
  `Application Support/CCSSongWorkbench` and `Caches/CCSSongWorkbench`
  directories so an existing local library/cache can move to `SongWorkbench`
  when the new directories do not already exist.
- Regenerated `SongWorkbench.xcodeproj` and `SongWorkbench.xcworkspace` with
  Tuist.
- Verification: strict Swift format passed; `swift test --jobs 1` passed 118
  tests with 4 environment-gated skips; generated Xcode/macOS tests passed 118
  tests with 4 skips; unsigned Release archive succeeded at
  `/tmp/SongWorkbench-Rename.xcarchive` with `SongWorkbench.app`,
  `CFBundleExecutable = SongWorkbench`, `CFBundleIdentifier =
  com.local.SongWorkbench`, and `AppIcon`; root `make verify` completed; `git
  diff --check` and debug-log grep were clean.

# Standalone Repository Root

- [x] Initialize `/Users/ericnewman/Documents/SongWorkbench` as a Git repo.
- [x] Carry over repository guidance, task notes, docs, GitHub templates, hooks,
  and verification entry points.
- [x] Remove old nested `SongWorkbench/` and catalog-export assumptions from
  repo verification.
- [x] Fix moved-workspace Xcode package resolution.

## Review

- Initialized Git at the app root and set up `Makefile`, `.githooks`,
  `.github`, `docs/agents`, `tasks`, `CONTEXT.md`, and `memory.md`.
- `make verify` now runs from the app root and covers whitespace, Python syntax
  checks for repo scripts/benchmark tools, strict Swift format, SwiftPM tests,
  and a release build.
- Verification: `make setup && make verify` passed from
  `/Users/ericnewman/Documents/SongWorkbench`; SwiftPM executed 118 tests with
  4 environment-gated skips and 0 failures, then completed the release build.
- Xcode compile fix: `SongWorkbench.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  had been a broken absolute symlink to the pre-move folder. Replaced it with a
  real checked-in lockfile matching the project lockfile. Verification:
  workspace Debug build passed; workspace Xcode tests passed 118 tests with 4
  environment-gated skips and 0 failures; `make verify` passed.

# Song List Deletion

- [x] Add an obvious delete action for songs in the sidebar file list.
- [x] Remove the selected song's saved settings, analysis, recency, waveform/playback state, and selection when deleting.
- [x] Preserve the source audio file on disk; deletion removes the app library entry only.
- [x] Add regression coverage for deleting the selected song and persisting the removal.
- [x] Verify focused tests, full SwiftPM tests, generated Xcode/macOS tests, formatting, and diff hygiene.

## Review

- Added visible trash buttons to each song row, a destructive context-menu
  Remove Song action, and a toolbar trash button for the selected song.
- `AppModel.removeSong(_:)` removes the library entry plus persisted settings,
  analysis, and recency. It preserves the source file, selects a neighboring
  song when available, and clears playback/waveform/editor state when no songs
  remain.
- Added `AudioPlaybackService.unload()` so deleting the last selected song leaves
  no stale loaded recording.
- Verification: focused deletion tests passed; `swift test --jobs 1` passed 113
  tests with 4 environment-gated skips; generated Xcode/macOS suite exited 0;
  strict Swift format, `git diff --check`, and debug-log grep were clean.

# Accuracy Transcription Truncation

- [x] Reproduce the Accuracy-mode cutoff at the transcription post-processing seam.
- [x] Prevent repetition cleanup from discarding most of a song after an early repeated phrase.
- [x] Invalidate cached short Accuracy transcripts by bumping the whisper.cpp engine version.
- [x] Add regression coverage for repeated early lyrics followed by later valid content.
- [x] Verify focused tests, full SwiftPM tests, generated Xcode/macOS tests, formatting, and diff hygiene.

## Review

- Root cause: whisper.cpp was returning a full timed transcript, but the
  post-transcription repetition filter could treat an early repeated lyric
  phrase as a hallucination loop and discard the rest of the song.
- The Accuracy engine now rejects repetition-filter output when it would retain
  less than half of the original song timeline. Clear trailing-loop cleanup can
  still apply; early song truncation is ignored.
- Bumped whisper.cpp transcription metadata to engine version 3 so cached short
  Accuracy transcripts from version 2 are not reused.
- Added `testAccuracyEngineRejectsOverAggressiveEarlyRepetitionCutoff`, which
  preserves later lyrics after an early repeated phrase.
- Verification: focused whisper.cpp tests passed; `swift test --jobs 1` passed
  114 tests with 4 environment-gated skips; generated Xcode/macOS suite passed
  114 tests with 4 skips; strict Swift format, `git diff --check`, and debug-log
  grep were clean.

# Xcode Warning Cleanup

- [x] Capture the current Xcode warning list from a clean app/test build.
- [x] Classify warnings as project-owned vs dependency/toolchain noise.
- [x] Fix project-owned warnings with minimal source/build-setting changes.
- [x] Rerun the Xcode warning capture and verify the project-owned warning list is clean.
- [x] Run focused/full tests and standard formatting/diff hygiene checks.

## Review

- Root cause: Xcode scheduled App Intents metadata extraction for the app and
  test bundle even though neither target linked `AppIntents`, producing two
  `No AppIntents.framework dependency found` warnings.
- `EXTRACT_APP_INTENTS_METADATA=NO` and `APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING=NO`
  were not honored by Xcode's generated extraction phase when persisted in the
  project, so they were removed.
- Added an optional `AppIntents` SDK dependency to both generated Xcode targets
  through `Project.swift`. This satisfies Xcode's metadata processor without
  importing AppIntents or requiring runtime app-intent features.
- Regenerated `SongWorkbench.xcodeproj` with Tuist. Final Xcode warning
  capture had zero `warning:` lines and `xcodebuild test` passed 114 tests with
  4 environment-gated skips.
- Verification: `swift test --jobs 1` passed 114 tests with 4 skips; strict Swift
  format, `git diff --check`, and debug-log grep were clean.

# Lyrics Edit ChordPro Propagation

- [x] Reproduce that editing Lyrics leaves an unreviewed generated ChordPro draft stale.
- [x] Rebuild generated unreviewed ChordPro when lyrics change from the editor.
- [x] Preserve reviewed or manually imported ChordPro when lyrics change.
- [x] Add AppModel regression coverage for both propagation and preservation.
- [x] Verify focused tests, full SwiftPM/Xcode tests, formatting, and diff hygiene.

## Review

- Root cause: `lyricSegments.didSet` marked Lyrics as draft and persisted the
  analysis, but did not call the ChordPro draft rebuild path.
- Reused the existing generated-draft guard: ChordPro is rebuilt only when the
  current ChordPro stage succeeded via `chordpro-draft-builder` and the ChordPro
  has not been reviewed. Reviewed or imported ChordPro remains unchanged.
- Renamed the rebuild helper to `rebuildGeneratedChordProDraft()` and share it
  between lyric edits and confidence-threshold changes.
- Added `testEditingLyricsRebuildsOnlyUnreviewedGeneratedChordPro`, which first
  failed against the stale behavior, then passed after the fix.
- Verification: focused propagation and confidence tests passed; `swift test
  --jobs 1` passed 115 tests with 4 environment-gated skips; generated
  Xcode/macOS suite passed 115 tests with 4 skips; Xcode warning grep, strict
  Swift format, `git diff --check`, and debug-log grep were clean.

# TestFlight Release Preparation

- [x] Audit current project against macOS TestFlight/App Store requirements.
- [x] Add release entitlements and sandbox-compatible capabilities.
- [x] Make signing/bundle/version settings release-ready without breaking local builds.
- [x] Add a repeatable archive/export verification path and release checklist.
- [x] Verify tests, Xcode archive/build behavior, warning output, formatting, and diff hygiene.

## Review

- Added `SongWorkbench.entitlements` with App Sandbox, user-selected
  read/write file access, and network-client access for model downloads.
- Changed the Tuist app target to use configurable bundle/version/signing
  release settings: `SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER`,
  `SONGWORKBENCH_DEVELOPMENT_TEAM`, `MARKETING_VERSION`, and
  `CURRENT_PROJECT_VERSION`.
- Added `RELEASE.md` with local verification, unsigned archive, signed archive,
  App Store Connect/TestFlight upload, and post-signing sandbox smoke-test
  steps.
- Release archive initially failed only for the generic macOS/x86_64 slice
  because Swift `Float16` numeric conversion was unavailable there. Replaced the
  CoreML output path with raw IEEE-754 half-float decoding and added
  `testHalfPrecisionFloatValueDecodesCommonModelOutputs`.
- Verification: focused half-float test passed; `swift test --jobs 1` passed
  116 tests with 4 environment-gated skips; generated Xcode/macOS suite passed
  116 tests with 4 skips; unsigned Release archive succeeded at
  `/tmp/SongWorkbench-TestFlightPrep.xcarchive`; root `make verify`
  completed; strict Swift format, `git diff --check`, compiler-warning grep,
  and debug-log grep were clean.
- Remaining upload blockers are external configuration: registered production
  bundle ID, Apple Developer Team ID, final app icon asset catalog, App Store
  Connect app record/privacy answers, and a signed sandbox runtime smoke test.

# App Icon Family

- [x] Generate a macOS app icon family from the supplied source image.
- [x] Add the icon asset catalog to the Tuist/Xcode app target.
- [x] Verify generated project settings, build/archive behavior, and diff hygiene.

## Review

- Created `Resources/Assets.xcassets/AppIcon.appiconset` with the complete
  macOS icon family from the supplied 512 x 512 PNG, including the 1024 px
  512@2x slot.
- Added an `AccentColor` asset derived from the icon's cyan/teal waveform color
  so adding the asset catalog does not introduce the default missing-accent
  warning.
- Wired `Resources/**` into the Tuist app target and set
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`; regenerated the Xcode project.
- Verification: generated build settings report `AppIcon`; Debug app build and
  unsigned Release archive both contain `Contents/Resources/AppIcon.icns` and
  `Assets.car`; warning/error grep was clean after adding `AccentColor`; `git
  diff --check` passed.

# ChordPro Preview Leading Alignment

- [x] Pin two-axis preview content to the viewport's top-leading edge.
- [x] Preserve horizontal scrolling for genuinely wide chord/lyric lines.
- [x] Verify focused build, full tests, formatting, and runtime layout where available.

## Review

- Root cause: the two-axis scroll view did not constrain or anchor the lazy
  stack to the viewport, so wide intrinsic lyric rows could open at a centered
  horizontal position.
- The preview now gives its content the viewport's minimum width, aligns it
  top-leading, sets the initial scroll anchor to top-leading, and reduces inset
  padding from 24 to 12 points. Wide lines remain horizontally scrollable.
- Focused preview tests: 3 passed. SwiftPM: 106 total, 2 skipped, 0 failed.
  Xcode/macOS: 106 total, 104 passed, 2 skipped, 0 failed. Strict formatting
  and `git diff --check` pass.
- The preview is a private SwiftUI view and this repository has no UI snapshot
  test seam; behavior is covered by container code inspection, compilation, and
  existing parser/alignment tests.

# Two-Column Workspace and Chord Confidence Threshold

- [x] Persist a per-song ChordPro chord-confidence threshold with backward-compatible decoding.
- [x] Filter generated ChordPro events by threshold while retaining manually entered chords.
- [x] Rebuild only unreviewed generated drafts when the threshold changes.
- [x] Add threshold controls and clear included/excluded feedback to the Chords tab.
- [x] Refactor the player into a narrow scrolling control column and a wide, top-aligned editor column.
- [x] Verify focused behavior, full SwiftPM/Xcode suites, formatting, and app launch.

## Review

- Each song persists a 0...100% ChordPro confidence threshold; legacy documents
  decode at 50%. Detected chords below it are omitted, while manual chords with
  no confidence value remain included.
- Slider changes rebuild only generated, unreviewed ChordPro drafts. Reviewed or
  imported source remains unchanged. Rows show included/excluded state and a
  live included-event count.
- The detail screen now uses a 330-point independently scrolling control column
  and a flexible, top-aligned editor column. The four-tab card fills the right
  side and the minimum window size is 1100 x 650.
- Focused threshold/document/model tests: 7 passed. SwiftPM: 106 total, 2
  skipped, 0 failed. Xcode/macOS: 106 total, 104 passed, 2 skipped, 0 failed.
  Strict formatting and `git diff --check` pass.
- The built app launched successfully. The desktop inspection bridge listed it
  as frontmost but could not attach to its window, so no screenshot evidence was
  captured in this run.

# Accompaniment-Only Chord Detection

- [x] Trace and verify the harmony-analysis audio source and event-reduction path.
- [x] Add a pipeline regression proving harmony receives the accompaniment stem,
  never the vocal stem or full recording when a stem set is available.
- [x] Replace frame-change emission with two-beat confidence voting.
- [x] Record accompaniment provenance and make missing-stem fallback explicit.
- [x] Verify focused regressions, full SwiftPM/Xcode suites, and deterministic
  high-churn chord-event reduction.

## Diagnosis

- Harmony currently receives the full recording through `request.sourceURL`.
  It does not receive `vocals.wav` directly, but vocal content remains in the mix.
- The production four-stem model has no dedicated guitar or piano outputs;
  guitar, piano, and keys are represented by the accompaniment `other.wav` stem.
- The song-analysis pipeline emits every confident frame-level label change,
  unlike the separate manual-analysis path, which already votes per measure.

## Review

- Harmony now selects `other.wav` from the four-stem set and records
  `accompanimentStem` provenance. It never selects `vocals.wav`.
- Standalone chord analysis requires the accompaniment stem. The full pipeline
  may use the recording only when separation is unavailable, records
  `full-mix-fallback`, and exposes that provenance in the Chords tab.
- Shared reduction filters observations below 0.45 confidence and votes in
  two-beat windows with a 0.55 winning-share threshold. The high-churn fixture
  reduces 16 alternating frame labels to one stable chord event.
- SwiftPM: 104 tests, 2 skipped, 0 failures. Xcode/macOS: 104 tests, 2 skipped,
  0 failures. Strict Swift format lint and `git diff --check` pass.
- Existing persisted chord results were not overwritten during verification;
  rerun Harmony or Analyze Accompaniment to regenerate them.
