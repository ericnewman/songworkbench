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
