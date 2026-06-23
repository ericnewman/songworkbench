# SongWorkbench Requirements

Version: 1.0-draft

Source: Complete Song Analysis PRD

Status: Implementation baseline

## Requirement language

`MUST` is required for completion. `SHOULD` is required unless a documented
tradeoff is accepted. `MAY` is optional. Requirement IDs are stable; revise the
text or mark an ID superseded instead of renumbering unrelated requirements.

## Product foundation

- **FOUND-001** The application MUST run on macOS 14 or later and remain
  Apple Silicon-first.
- **FOUND-002** The application MUST import MP3, M4A, WAV, AIFF, and FLAC recordings.
- **FOUND-003** Analysis MUST NOT modify the source recording.
- **FOUND-004** Existing playback, seek, loop, pitch, tempo, waveform, adjusted
  audio export, manual lyrics/chords, ChordPro import/transposition/export, and
  manual stem-folder import workflows MUST remain functional.
- **FOUND-005** Manual editing MUST remain available when no optional model is installed.
- **FOUND-006** Installed model artifacts MUST support offline analysis without
  uploading recording or analysis content.

## Analyze Song workflow

- **RUN-001** A selected song MUST expose one primary Analyze Song action.
- **RUN-002** The user MUST be able to run a recommended complete preset or
  select separation, transcription, harmony, and ChordPro stages individually.
- **RUN-003** The user MUST be able to choose fast-draft or accuracy transcription mode.
- **RUN-004** A run MUST publish aggregate and per-stage state and progress.
- **RUN-005** Visible progress MUST begin during planning or model preparation,
  before the first expensive engine call.
- **RUN-006** Progress MUST be monotonic within a run.
- **RUN-007** A running analysis MUST be cancellable.
- **RUN-008** Cancellation MUST stop new stages, forward cancellation to the
  active engine, remove temporary output, and preserve already validated results.
- **RUN-009** Independent selected stages SHOULD continue after another stage fails.
- **RUN-010** The user MUST be able to retry only failed or stale stages.
- **RUN-011** A run MUST report whether each result was computed or loaded from cache.
- **RUN-012** Stage errors MUST identify a recovery action when one exists.
- **RUN-013** Memory-heavy ML stages MUST run serially by default.
- **RUN-014** Changing the selected song MUST NOT publish late results into the
  newly selected song.

## Model artifacts

- **MODEL-001** Optional model metadata MUST include stable ID, version, URL,
  expected bytes, SHA-256, minimum platform, license, and attribution.
- **MODEL-002** The UI MUST show model size, version, license, attribution, and
  installed/available state before installation or use.
- **MODEL-003** Model installation MUST be user initiated.
- **MODEL-004** Downloads MUST report progress and support cancellation.
- **MODEL-005** Installation MUST use a temporary location, verify expected size
  and SHA-256, and publish atomically into a versioned application-support directory.
- **MODEL-006** Partial, missing, or digest-mismatched artifacts MUST NOT be
  reported as installed.
- **MODEL-007** The user MUST be able to verify and remove an installed model.
- **MODEL-008** The UI MUST report per-model and total model storage.
- **MODEL-009** Removal MUST NOT delete persisted analysis documents or manually
  imported assets.
- **MODEL-010** The initial catalog MUST support HTDemucs Core ML FP16,
  FluidAudio/Parakeet, and a quantized whisper.cpp accuracy model.

## Stem separation

- **STEM-001** The production separation engine MUST implement the shared
  `StemSeparationEngine` behavior.
- **STEM-002** A successful result MUST contain vocals, drums, bass, and other.
- **STEM-003** Outputs MUST be 44.1 kHz stereo and aligned to source duration
  within the release-quality tolerance.
- **STEM-004** The engine MUST handle the model's ten-second chunk shape,
  overlap reconstruction, FP16/runtime output types, reported strides, and
  per-prediction memory release.
- **STEM-005** Output validation MUST reject missing files, non-finite samples,
  unsupported layout, implausible duration, and incomplete writes.
- **STEM-006** The four-stem set MUST be published atomically.
- **STEM-007** Separation MUST report preparation, model loading, processing,
  validation, and writing progress.
- **STEM-008** Generated stems MUST load into the existing stem mixer and export workflow.

## Lyric transcription

- **LYRIC-001** Fast-draft and accuracy engines MUST normalize into the shared
  `TranscriptionEngine` result model.
- **LYRIC-002** Results MUST include timed segments, text, confidence when
  available, language, completion time, engine/model identity, and license metadata.
- **LYRIC-003** Transcription MUST prefer a current validated vocals stem and
  MUST fall back to the source mix.
- **LYRIC-004** Provenance MUST record whether vocals or full mix was transcribed.
- **LYRIC-005** Accuracy mode MUST disable previous-text conditioning for song decoding.
- **LYRIC-006** Request-scoped cancellation MUST reach the active transcription engine.
- **LYRIC-007** Low-confidence fast-draft regions SHOULD be retryable with the
  accuracy engine without rerunning accepted regions.
- **LYRIC-008** Machine transcription MUST populate editable timed lyrics as draft.
- **LYRIC-009** Machine transcription MUST NOT automatically mark lyrics reviewed.
- **LYRIC-010** Manual add, remove, edit, and retime operations MUST remain available.

## Tempo and chord timeline

- **CHORD-001** Native full-mix beat/chroma analysis MUST remain available as a fallback.
- **CHORD-002** Current bass/accompaniment stems SHOULD be used as additional
  harmonic evidence when available.
- **CHORD-003** Results MUST include estimated tempo and editable timestamped
  chord events with confidence when available.
- **CHORD-004** Machine chord results MUST be draft until explicitly reviewed.
- **CHORD-005** Manual add, remove, edit, and retime operations MUST remain available.
- **CHORD-006** The UI MUST identify stale chord results when source, engine,
  model, or relevant configuration identity changes.

## ChordPro generation

- **CHORDPRO-001** The application MUST generate an editable ChordPro draft from
  the latest selected timed lyrics and chord timeline.
- **CHORDPRO-002** Equivalent normalized inputs and options MUST produce byte-stable output.
- **CHORDPRO-003** Generation MUST preserve metadata and explicitly represent
  uncertain lyric/chord evidence.
- **CHORDPRO-004** Multiple chord changes within one lyric segment MUST be representable.
- **CHORDPRO-005** Lyrics-only and chords-only inputs MUST produce valid useful drafts.
- **CHORDPRO-006** Imported or manually edited ChordPro MUST NOT be overwritten
  by a rerun without explicit user confirmation.
- **CHORDPRO-007** The user MUST explicitly regenerate after upstream edits.
- **CHORDPRO-008** Existing transpose and export behavior MUST work with generated drafts.

## Persistence, provenance, and review

- **PERSIST-001** The analysis document MUST persist lyrics, chords, ChordPro,
  tempo, stem references, mixer state, per-stage state, provenance, confidence
  summaries, review state, and completion timestamps.
- **PERSIST-002** Every result MUST identify source content, source kind,
  engine/model version, configuration, and result schema.
- **PERSIST-003** The cache key MUST include all identities in PERSIST-002.
- **PERSIST-004** Cache writes MUST be atomic; corrupt entries MUST become misses.
- **PERSIST-005** Existing project schema versions MUST decode with defaults and
  migrate without losing manual content.
- **PERSIST-006** Machine output MUST set affected content to draft.
- **PERSIST-007** Only an explicit user action MAY set content reviewed.
- **PERSIST-008** Editing reviewed content MUST return it to draft unless review
  is explicitly reaffirmed.
- **PERSIST-009** Rerunning a stage MUST NOT silently overwrite conflicting
  reviewed or manually edited downstream content.
- **PERSIST-010** Valid previous results MUST survive a later stage failure.
- **PERSIST-011** Results and review state MUST restore after application relaunch.

## User interface and accessibility

- **UI-001** The analysis workspace MUST show selected mode/stages and model readiness.
- **UI-002** Missing model state MUST offer an actionable installation path.
- **UI-003** Running state MUST show aggregate/per-stage progress and Cancel.
- **UI-004** Completed, failed, cancelled, cached, partial, stale, draft, and
  reviewed states MUST be visually distinguishable without relying only on color.
- **UI-005** Failed/stale stages MUST expose targeted retry.
- **UI-006** Provenance and completion time MUST be inspectable per stage.
- **UI-007** Lyrics and chords MUST expose explicit Mark Reviewed actions.
- **UI-008** ChordPro generation MUST expose conflict confirmation when replacing
  manually edited or reviewed content.
- **UI-009** Model settings MUST support install, verify, remove, and storage totals.
- **UI-010** Analysis controls and status MUST have useful keyboard focus order,
  labels, values, and VoiceOver descriptions.

## Reliability, privacy, and resource requirements

- **NFR-001** Recording, stem, lyric, chord, and analysis content MUST NOT be uploaded.
- **NFR-002** Network use MUST be limited to explicit model download requests.
- **NFR-003** Temporary analysis and download files MUST be cleaned after success,
  cancellation, and recoverable failure.
- **NFR-004** Insufficient disk or memory MUST fail without corrupting existing
  project state or installed artifacts.
- **NFR-005** User-visible failures MUST remain recoverable without restarting
  the application where technically possible.
- **NFR-006** The base app MUST NOT require a Python or PyTorch runtime.
- **NFR-007** Normal CI MUST run without downloading model artifacts.
- **NFR-008** Release validation MUST record runtime and peak memory on the fixed corpus.

## Verification and release gates

- **GATE-001** Model-free CI MUST pass the repository verification command.
- **GATE-002** Unit/contract tests MUST cover all seven confirmed modules.
- **GATE-003** Pipeline integration tests MUST cover every stage subset,
  dependency, cancellation point, partial failure, retry, cache, and conflict policy.
- **GATE-004** Every historical project schema fixture MUST migrate without data loss.
- **GATE-005** Stem fixed-corpus validation MUST produce four finite, aligned,
  unclipped outputs and remain within documented reconstruction/correlation tolerances.
- **GATE-006** Transcription fixed-corpus validation MUST enforce WER and
  repetition-loop regression thresholds separately for draft and accuracy modes.
- **GATE-007** Chord validation MUST enforce tempo and timeline-coverage tolerances
  while retaining editable confidence-bearing output.
- **GATE-008** Representative UI verification MUST demonstrate model install,
  full analysis, stage-only analysis, cancellation, retry, review, relaunch
  restoration, ChordPro regeneration, and export.
- **GATE-009** Completion MUST be demonstrated with production engines and a
  representative recording; protocol fakes alone are insufficient.
