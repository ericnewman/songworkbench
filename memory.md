# Project Memory

- This standalone app repository lives at
  `/Users/ericnewman/Documents/SongWorkbench`. Older catalog notes below refer
  to the previous wrapper workspace, not to files expected in this repo.
- ChordPro charts in this folder use concert-key metadata plus practical guitar
  shapes when a capo improves playability.
- For MP3 transcription, separate vocals with Demucs, transcribe the isolated
  vocal with Whisper, and use targeted section passes for uncertain lyrics.
- Verify generated charts for ASCII content, balanced section directives,
  bracket syntax, allowed chord names, required metadata, and
  `git diff --check`.
- The full catalog output lives in `ChordPro Catalog/`. Its `README.md` maps
  every supplied MP3 to an output chart, and `manifest.json` records hashes,
  exact duplicates, keys, capos, tempos, and transcription confidence.
- `scripts/batch_chordpro.py` is the resumable catalog generator. It caches
  transcription during processing, deduplicates by SHA-256, preserves manually
  reviewed charts, and validates each generated ChordPro file.
- Guitar-tone results for all 34 unique recordings live in
  `ChordPro Catalog/GUITAR_TONES.md` and `guitar-tone-table.csv`. The resumable
  analyzer is `scripts/analyze_guitar_tones.py`; its JSON output retains raw and
  catalog-calibrated model scores plus spectral/dynamics measurements.
- `Those Were the Days` and `One More Moment in Time` were added from Google
  Drive source paths. Both are in concert Eb with capo-1 D-family shapes; the
  charts and manifest live in `ChordPro Catalog/`.
- Lyrics-only exports for 33 recordings live in `Lyrics Only/`; `Cross Cut Saw
  Live` is intentionally excluded.
- `Summer on the Lake.cho` and `Summer on the Lake - Concert Chords.cho` were
  rebuilt after beat-synchronized reanalysis. The measured arrangement uses 83
  BPM, half-measure intro/outro changes, detailed pre-chorus passing chords, and
  135 placements in both capo-shape and concert versions. The lightweight
  NumPy/FFmpeg timeline tool is `scripts/analyze_chord_timeline.py`.
- `ChordPro Catalog/Summertime's here with you.cho` was rebuilt from the Apr 20
  alternate recording using timestamped vocals plus separated drum, bass, and
  accompaniment stems. The reviewed 99 BPM chart has 92 placements and 34
  instrumental measures; it is distinct from the older low-confidence
  `Somertime's Here with You.cho` recording.
  Regenerate them with `python3 scripts/export_lyrics.py`; the exporter prefers
  reviewed concert charts and removes chords, directives, instrumental cues,
  transcript placeholders, and live-stage banter.
- The native macOS app repo root is `/Users/ericnewman/Documents/SongWorkbench`.
  It is a macOS 14 SwiftUI package with a dependency-free AVAudioEngine playback slice: audio
  import, song selection, play/pause, seeking, and -12...+12 semitone pitch
  shifting. `PLAN.md` records the architecture and library evaluation plan;
  `TODO.md` tracks stem separation, transcription, waveform, and chord-analysis
  milestones.
- The stem-separation benchmark uses a fixed 60-second excerpt with SHA-256
  `47881ae99990322285269ca727ea39f66750d84b84a6171afe8c37a5273f3803`.
  Python `htdemucs` processes it in 18.38 seconds. Production now uses a managed
  full-graph `htdemucs_6s` ONNX model through ONNX Runtime CPU execution. Do
  not enable ONNX Runtime Core ML execution for this graph: it produced poor
  reconstruction and near-empty vocals on `Where the sun shines warm.mp3`. The
  app marks saved stems with older/mismatched separation provenance as stale and
  does not load them into stem playback. The model-independent async
  `StemSeparationEngine` contract exposes vocals, drums, bass, guitar, piano,
  and other with structured progress while decoding legacy four-stem projects.
- Final SongWorkbench verification used `Where the sun shines warm.mp3`:
  import, selection, 3:20 duration loading, playback, seeking, pitch, tempo,
  reset, and all editor tabs passed. The serial debug suite has 59 passing
  tests and the optimized build succeeds. Run SwiftPM verification with
  `--jobs 1` when another Swift build is active to avoid shared-object races.
- Production transcription validation uses the persisted HTDemucs `vocals.wav`
  for `Where the sun shines warm.mp3`. FluidAudio requires its managed
  `parakeet-tdt-0.6b-v3-coreml` package to appear under FluidAudio's expected
  `parakeet-tdt-0.6b-v3` folder name; stage a temporary symlink rather than
  copying the 483 MB package. Merge its SentencePiece fragments into timed
  words before shared lyric grouping and bump the engine version when that
  normalization changes so malformed cached transcripts are not reused.
- Transcription has three user-facing quality profiles. Fast Draft is Parakeet
  with `melChunkContext = false`; Balanced Draft uses the same installed
  Parakeet package with `melChunkContext = true` for better chunk-boundary
  continuity; Accuracy remains the whisper.cpp Large V3 Turbo path. Balanced
  Draft has distinct mode routing and provenance/cache configuration from Fast
  Draft.
- Whisper Large V3 Turbo Q5_0 defaults to CPU/BLAS in the app. Its Metal backend
  can terminate xctest during buffer allocation before Swift can catch an error;
  the CPU path transcribed the representative 3:20 vocals stem in 38.8 seconds.
- Accuracy-mode whisper.cpp transcripts pass through a repetition cleanup guard,
  but the engine must reject cleanup output that keeps less than half of the
  song timeline. Otherwise repeated early lyrics can make the app appear to
  analyze only the first small part of a song. Bump the whisper.cpp engine
  version when this post-processing changes so short cached transcripts are not
  reused.
- The checked-in Xcode project is `SongWorkbench.xcodeproj`; regenerate it
  from `Project.swift` with Tuist. The local
  `Dependencies/WhisperFramework` package wraps the pinned remote XCFramework,
  while FluidAudio remains pinned at 0.15.4. If command-line Xcode project reads
  hang in this iCloud-backed Documents path, verify an exact copy under `/tmp`.
  Xcode 26 may run App Intents metadata extraction for Swift app/test targets;
  this app intentionally links `AppIntents` as an optional SDK dependency in
  `Project.swift` so the processor has the expected framework and does not emit
  "No AppIntents.framework dependency found" warnings.
- The app was globally renamed from `CCSSongWorkbench` / `CCS Song Workbench`
  to `SongWorkbench`. Runtime storage now uses `Application Support/SongWorkbench`
  and `Caches/SongWorkbench`; on first launch/load, the app moves legacy
  `CCSSongWorkbench` support/cache directories to the new names when the new
  directories do not already exist.
- SIGNING / TUIST: `tuist generate` rewrites the pbxproj from `Project.swift` — any
  signing set in the Xcode UI is stomped on the next generate, so signing MUST live in
  `Project.swift`. Eric's real Team ID is `65FBMF6CMD` (the certificate's OU field);
  `94276EJ325` — the parenthetical in "Apple Development: Eric Newman (94276EJ325)" —
  is the CERT identifier, not the team. Debug signs with team 65FBMF6CMD (fixed
  2026-07-02); with the wrong ID there, every regenerate "lost" signing.
- TestFlight prep lives in `RELEASE.md`. The app target uses
  `SongWorkbench.entitlements` with App Sandbox, user-selected read/write
  file access, and network-client access. Release signing is automatic and
  driven by `SONGWORKBENCH_DEVELOPMENT_TEAM`; the bundle ID is overridden with
  `SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER`. The app icon family is
  `Resources/Assets.xcassets/AppIcon.appiconset`, generated
  from the supplied 512 px MP3/audio-workbench image, with `AccentColor` set to
  the cyan waveform color. Before upload, provide the registered bundle ID,
  Apple Developer Team ID, App Store Connect privacy answers, and a signed
  sandbox smoke test. The CoreML fp16 output path decodes raw UInt16 half-float
  bits directly because generic macOS archives can compile an x86_64 slice where
  Swift `Float16` numeric conversion is unavailable.
- ChordPro is a downstream generated artifact of timed lyrics and the chord
  timeline. A Lyrics- or Harmony-only retry automatically rebuilds an existing
  unreviewed `chordpro-draft-builder` chart; reviewed or imported charts remain
  protected from silent replacement. Manual edits to timed lyrics also rebuild
  only an existing unreviewed generated ChordPro draft so the ChordPro tab stays
  in sync while reviewed/imported charts remain protected.
- The ChordPro tab has a local Edit/App Preview switch. Preview is built from
  `ChordProPreviewDocument`: it renders metadata and section directives and
  positions accent-colored chord symbols above monospaced lyric character
  anchors. Its two-axis scroll container explicitly uses viewport-width,
  top-leading content alignment and a top-leading initial anchor so wide lines
  do not center or shift the chart offscreen. Invalid source reports its parse
  error without blocking Edit mode.
- The four-tab workspace card owns the shared practice transport. `PlaybackSource`
  selects recording or stem mix, transfers source time when switching, and routes
  progress, seek, skip, waveform, pitch, and speed to the active engine. Stem
  playback mixes through one `AVAudioUnitTimePitch` so all stems stay aligned.
- Harmony analysis persists a `MusicalKey` estimate. Legacy analysis documents
  infer it from stored chord events; pitch adjustments display both the detected
  and transposed major/minor key in the shared transport.
- Harmony analysis uses a generated guitar+piano+other accompaniment composite,
  never the vocal stem. Synth/organ keys remain in `other` because
  `htdemucs_6s` has no keys output; standalone chord analysis requires the
  composite, while the full pipeline records and displays an explicit
  full-recording fallback if separation fails.
  Chord events are confidence-filtered and selected by two-beat voting instead
  of persisting every frame-level label change.
- ChordPro confidence filtering is a per-song persisted threshold, defaulting to
  50% for legacy documents. Generated drafts omit detected chords below the
  threshold but always retain manual chords whose confidence is nil. Threshold
  changes regenerate only unreviewed generated drafts, preserving reviewed and
  imported ChordPro source.
- The player detail uses two top-aligned columns: a fixed 330-point scrolling
  control/analysis column on the left and the flexible four-tab workspace card
  on the right, with the selected song title centered above both columns. The
  main card's Playback section owns play/pause, skip, seek, pitch, and speed.
  The app window minimum is 1100 x 650.
- In the fixed-width left column, compact utility panels should avoid putting
  title, action buttons, labels, sliders, and values in one `HStack`; the
  waveform panel intentionally uses a title/action row plus a separate zoom
  control row so the title does not compress into vertical letters.
- The song sidebar has visible trash controls for removing songs from the app
  library. Removal preserves the source audio file on disk, deletes persisted
  per-song settings/analysis/recency, and clears playback/workspace state when
  the last selected song is removed.
- The workspace is a structured Git repository. Run `make setup` once per clone
  and `make verify` before handoff. Generated audio/model assets, `.venv`, Swift
  build products, and caches are intentionally excluded. PRDs and issues live
  under `.scratch/` until a remote issue tracker is configured.
- `.swift-format` establishes the package's four-space style;
  strict lint is clean after the initial mechanical formatting pass.
- `/Users/ericnewman/Documents/SongWorkbench` is now its own Git repository.
  Root verification is app-only: `make verify` runs diff whitespace checks,
  Python compile checks for `scripts` and `Benchmarks/Tools`, strict Swift
  format lint, SwiftPM tests, and a release build from the repo root.
- After the move, Xcode workspace package resolution failed because
  `SongWorkbench.xcworkspace/xcshareddata/swiftpm/Package.resolved` was a
  broken absolute symlink to the old wrapper path. Keep the workspace lockfile
  as a real file matching the project SwiftPM lockfile; validate both
  `xcodebuild ... -project SongWorkbench.xcodeproj` and
  `xcodebuild ... -workspace SongWorkbench.xcworkspace` after future moves.
- The reusable personal skill is
  `~/.codex/skills/analyze-guitar-tones`. For future song transcription, run
  tone analysis on the same source and embed the marked guitar-tone comment
  block in the ChordPro header; repeated runs replace the block idempotently.
- Chord timeline decoding (2026-07-01): `ChordTimelineDecoder` (Viterbi over
  per-beat windows, key prior via `KeyPriorChordRescorer` 1.0/0.75/0.5 with
  parallel-minor-of-tonic demoted, switch penalty 2.0, no-chord floor 0.5,
  empty windows uninformative) replaced independent per-window voting in the
  harmony stage; frame-level `BassInformedChordRefiner.refineObservations`
  (bass conf ≥0.35, candidates incl. maj7/dom7 for upper-structure confusions
  like C#-over-F# = F#maj7) runs BEFORE the vote because chroma can fully mask
  the true label (Ab read as Cm); `mergeSameRootExtensions` collapses F#/F#maj7
  neighbours; `ChordEventDurationFilter` merges sub-0.8-beat slivers after
  event-level bass refine + onset snap. Stage tag `reduce-9-seventh-reroot`
  re-reduces from cached chroma on re-analysis. Validated offline against
  Summertime's cached frames: 117 events/28% non-diatonic/26 sub-beat/31%
  chorus agreement → ~79/11%/8/80%; decoded verse matches the persisted BASS
  LINE (the ground truth for roots). Tune/verify offline by replaying cached
  frame JSON (Caches/SongWorkbench/Analysis, `value.chords` frames) in Python
  before changing Swift; the author's musical memory is the final arbiter.
- ChordPro preview meter: `DownbeatEstimator.estimateBeatsPerBar` picks the
  per-song bar length ({3,4,5,6}, conservative 4) from lyric-line spacing —
  Summertime phrases in 5 detected beats (real 112.35 tactus, drum-verified),
  and a hard-coded 4/4 grid made verse rows cascade rightward. The draft
  builder restates the active sustained chord at section starts; leading
  melody fill is suppressed when the pre-vocal gap ≥4 bars (intro rows
  already draw it).
- The reconstruction-accuracy audit + phased refinement plan (chord accuracy →
  ChordPro arrangement fidelity → reference-lyrics-first) lives in
  `tasks/todo.md` ("Reconstruction-accuracy audit"). ChordPro format gaps: no
  {key}/{time}, no bar-aligned chord-only lines, character-anchored chords.
- 2026-07-05 missed-chords + dropped-tail-lyrics fix: (1) `ChordTimelineDecoder`
  switchPenalty 2.0→1.5 with ONSET-AWARE discount (×0.5 for beat windows starting
  within 0.12s of an instrument onset, plumbed from AnalysisStage; stage tag
  `reduce-12-onset-viterbi`) — a one-window excursion previously needed ~e⁴
  evidence dominance, absorbing real passing chords (sweep on cached frames:
  pen 2.0→124 events vs 215 argmax). (2) `ChordOnsetAligner.snap` now takes
  beatTimes and refuses snaps that compress neighbours below 0.8 beat — the
  snap+clamp+duration-filter chain was deleting genuine A-B-A changes.
  (3) `TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail` was cutting
  the final line(s) of nearly EVERY song with a ≥3s outro (pure geometry; proof:
  Settle Down lost conf-0.98/1.00 closing lines). Now requires a DEGENERATE tail
  (every tail line ≤2 words or a normalized duplicate) and geometry may tighten
  the VAD cutoff by ≤3s, never override it (stage tag
  `grouping-42-degenerate-tail-prune`). Regression tests use real song shapes
  (Settle Down, Key West repeated-hook outro, Summertime blips).
- 2026-07-05 batch 2: bass notes now render positioned per-onset on the rhythmic
  time axis (`rowBassNotes` + `rhythmicBassXs`, own 18px row above chords; flush
  label only as monospace/override fallback). Duplicated preview lines were
  `LyricBlendRowBuilder` splitting one sung line into two rows when engines
  disagreed on timing beyond the 1.5s cluster window — fixed by merging adjacent
  clusters with DISJOINT mode sets + equal normalized text (real repeated hooks
  share a mode, never merge). `ReferenceLyricAligner` strips pasted "0:00"
  timestamps. Playback auto-scroll = 1.1s easeInOut glide to center
  (`ChordProAppPreview.autoScrollGlide`); ScrollView clamping defers scrolling
  until the active line can reach center. Eric's validation invariant to build
  next: vocal-stem onsets are ground truth — every burst ↔ a word; use for
  orphan/duplicate flagging and blend-candidate timing selection.
- 2026-07-05 batch 3: vocal-onset corroboration wired per Eric's invariant (stem
  waveform = ground truth for word placement). `LyricBlendRowBuilder
  .onsetCorroboration` scores a candidate's words against vocals-stem onsets;
  `onsetCorroborated(rows:)` auto-picks the clearly-corroborated candidate
  (margin 0.25) for rows without a user pick, in `runLyricBlendPasses` after
  reconcile (onsets detected off-main; no stem = no-op). NOTE: local `swift
  test` should pass `--skip AudioPlaybackServiceTests --skip
  StemPlaybackServiceTests` — those suites drive a real AVAudioEngine and emit
  an audible blip per run. Follow-ups: Review-UI orphan flag for ~zero-
  corroboration lines; validate auto-pick margin on real audio post-re-analysis.
- 2026-07-05 bass-vs-chord clash fix: measured 24-43% of displayed bass notes
  were non-chord-tones, dominated by ±1-semitone errors + low-confidence junk.
  `BassLineAnalyzer`: parabolic lag interpolation (integer lags = ~80-cent steps
  in the upper register) + global tuning-offset normalization using a clarity-
  weighted CIRCULAR mean of deviations (plain median splits at the ±0.5
  boundary — the detuned-recording case). `BassNoteRowFormatter` now hides
  notes below clarity 0.5. Re-measure clash % after next re-analysis; residual
  clashes may be real passing tones or chord-side errors. Blend-row merge also
  extended to NON-adjacent clusters within 8s (Grass-line regression).
- 2026-07-05 stem mixer pan+meters: StemMixState gains `pan` (−1…1, decodeIfPresent
  back-compat); constant-power law in `StemPlaybackService.panGains`; per-stem
  horizontal L/R meters (`stemStereoLevels`, post-fader post-pan, one file read
  feeds both meters) + `PanKnob` rotary (drag right/up = right, double-click
  centers) above each fader in the 360pt rail (strips widened 30→38).
  GOTCHA: AVAudioMixing volume/pan set before `enableManualRenderingMode` +
  engine.start() are silently dropped — set them AFTER the engine is running
  (exporter unit test testExporterAppliesPanToTheRenderedMix guards this; live
  path re-applies in play()). Export carries pan so bounces match the audible mix.
- 2026-07-05 run-on lines + Laughter chord: the blend pass OVERWRITES the correct
  primary reference-aligned lyrics seconds after analysis ("better, then
  refreshed to the wrong state") — a shifted mode's two segments cluster into
  one row and join into a run-on candidate that the accuracy-first default
  picks. `LyricBlendRowBuilder.runOnDuplicatesDemoted` (in runLyricBlendPasses
  after onsetCorroborated) demotes a candidate equal to neighbour-row text +
  another candidate's text. ChordProDraftBuilder now attaches short-gap chords
  closer to the NEXT line's start as that line's LEADING chords (anticipated
  changes, e.g. Bb 0.30s before "Laughter"). Decoder switch-discount cues now
  include confident (≥0.5) bass-note onsets alongside instrument attacks
  (stage tag reduce-13-bass-cues) — bass root movement marks plausible chord
  changes.
- 2026-07-05 late: BASS DISPLAY TRANSPOSE — the chart's Transpose stepper shifted
  chords but the bass row showed raw detected pitches (Eric: "half a step low,
  or perhaps not transposed" — the latter). BassNoteRowFormatter gains
  `transposedBy:`; Review preview passes its `transpose`. ALSO: the blend
  overwrite left the GENERATED ChordPro draft stale (chart kept pre-blend
  run-on lines after lyrics were fixed) — runLyricBlendPasses now rebuilds the
  draft with rebuildGeneratedChordProDraft's guards (never touches reviewed/
  imported charts). BassChordReconciler: borderline fractional pitches (±0.35
  of the boundary) snap to the concurrent chord's tone post-decode; obs schema
  gains optional `pitch` (fractional MIDI). Stage tag reduce-14-bass-snap.
  iPad worktree: /Users/ericnewman/Documents/SongWorkbench-ipad branch
  ipad-support, commit 318b0a9 — iOS Simulator build SUCCEEDS; plan in
  docs/ipad-port-plan.md; blockers = UI adaptation, htdemucs on-device
  viability, in-process unzip for model installs.
- 2026-07-05 background-activity status: the 30-60s post-analysis dark window is
  the blend passes. `AppModel.lyricBlendStatus` now feeds backgroundActivityStatus
  ("Preparing Lyric Blend — Balanced pass (1 of 2)…" → "matching lines to the
  vocal stem…" → "rebuilding chart…"), cleared via defer on every exit path.
  Note: stems are NOT re-separated post-analysis — the per-mode transcription
  passes are what users perceive as that; the status text now names them.
- 2026-07-05 Settle Down line-12 root cause (3rd layer): the run-on came from the
  PRIMARY Whisper pass (one 11.4s segment; IntraLinePauseSplitter blocked by
  voiced energy in the 1.7s gap — held note/bleed keeps voicedFraction > 0.5),
  and the exact-match run-on demotion missed it because engines word lines
  differently ("wanna"/"want to", "one horse"/"one-horse"). Demotion is now
  TOKEN-SIMILARITY based (LCS ratio ≥0.7 on both halves, any split boundary,
  either order, per neighbour candidate). Trade-off: demoting picks the split
  candidate's wording over the run-on's (split beats wording); synthesizing a
  SPLIT accuracy candidate would be the deeper fix if wording quality matters.
- 2026-07-20 timing/structure accuracy invariants: vocal attacks are assigned to
  words monotonically and one-to-one; unmatched words retain ASR timing rather
  than receiving fabricated 20 ms offsets. Lyric Blend effective bounds come
  from the selected candidate's words. Energy-only stereo analysis combines
  channels by RMS to avoid phase cancellation, and Whisper auto-detects language.
  Known sung-but-untranscribed spans are explicit form regions and can never be
  Instrumental/Solo. Chord-pattern matching preserves order while tolerating one
  passing chord; constant harmony supplies no phrase-period evidence. Derived
  timeline/structure caches must key the complete `ChordProDraftInput`.
- 2026-07-20 iPad analysis lifetime invariants: defer ONNX stem-engine construction
  until a separation cache miss actually needs inference; drain a prior analysis
  task before assembling its replacement; and generation-guard all AppModel
  callbacks and retained preflight/Lyric Blend tasks. Stem and ASR engines release
  heavyweight resources on success, failure, and cancellation, with iOS releasing
  ASR before harmony starts. Per-pass assembly may reuse process-local package
  verification, but explicit package status must still rehash for tamper detection.
  Click playback schedules one bounded sample at beat times instead of allocating
  song-duration PCM. Device profiling uses `analysis-performance` physical-footprint
  logs. Remaining measured-device work is fully streamed input/resampling, shared
  vocal feature extraction, harmony working-set reduction, stem-writer conversion,
  and an evidence-based ONNX arena policy.
## 2026-07-28 - Native inference direction

- Advanced production analysis is primarily a Swift/Xcode feature. Use
  in-process Core ML or ONNX Runtime Swift adapters for stem refinement and
  symbolic analysis. External command/Python refiners are optional macOS
  extensions and are not the iPad implementation path.
- Accuracy transcription detects a sparse time-zero opening followed by a long
  gap after vocal onset, transcribes a bounded onset window with the same native
  engine, and replaces only the sparse opening when the retry is richer.
  Near-onset alignment must not delete leading words from a straddling segment.
- Refined/imported stem manifests can contain arbitrary `StemID` children; mixer
  channels and metering derive from the active manifest frontier. Production
  still generates six stems until verified native refiner model artifacts are
  registered in the catalog and factory.
- The ChordPro and Review tabs share `ChordProTabEditor` and
  `ChordProAppPreview`. ChordPro uses the preview-only `chordProPlayback`
  configuration, so font, rhythmic spacing, lyric highlighting, bouncing ball,
  timing offset, and auto-scroll remain identical while Edit stays in Review.
- 2026-07-28 drum-piece refinement: `ModelCatalog.drumsep` registers Gridshift
  DrumSep ONNX (kick/snare/cymbals/toms, MIT). Advanced Desktop + installed
  package injects `drumsep-onnx-v1` via `StemRefinementEngineFactory.production`.
  Waveform lanes and Stem Mix strips both use the active `StemMixGraph` frontier
  (`StemWaveformLaneProjector` / `StemMixerChannelProjector`), so refined children
  replace their parent in both UIs. Guitar lead/rhythm IDs exist but have no
  registered model yet. Native DrumSep STFT mag packing still needs listening /
  PyTorch-parity validation before calling quality done.
