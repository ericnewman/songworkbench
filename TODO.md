# SongWorkbench TODO

## M1: Native Playback Slice

- [x] Create the Swift package and source layout.
- [x] Implement song import and sidebar selection.
- [x] Implement AVAudioEngine playback and seeking.
- [x] Implement -12...+12 semitone pitch shifting.
- [x] Add playback status and error presentation.
- [x] Add focused unit tests.
- [x] Run `swift test` and a release build.

## M2: Practice Workspace

- [x] Choose project persistence format.
- [x] Add waveform rendering and loop regions.
- [x] Add tempo control independent of pitch.
- [x] Add offline audio export.
- [x] Add keyboard shortcuts and recent projects.

## M3: Technical Spikes

- [x] Benchmark HTDemucs Core ML separation quality and runtime.
  - [x] Define representative input and acceptance criteria.
  - [x] Review repository, upstream code licenses, and attribution terms.
  - [x] Confirm pretrained-weight redistribution terms explicitly.
  - [x] Record published model download and installed binary sizes.
  - [x] Generate the fixed excerpt and run the Python Demucs baseline.
  - [x] Run the Core ML candidate on the fixed excerpt.
  - [x] Record cold/warm runtime and peak memory where practical.
  - [x] Compare vocals, drums, bass, and other stems for leakage/artifacts.
  - [x] Record the benchmark-backed optional-adoption decision.
- [x] Compare Signalsmith Stretch with AVAudioUnitTimePitch.
- [x] Compare FluidAudio with the Whisper model path on CCS vocals; record the
  MLX-versus-Swift runtime limitation.
- [x] Port and validate beat/chroma analysis using Accelerate/vDSP.
- [x] Record dependency licenses, binary sizes, and minimum OS requirements.

## M4: Integrated Analysis

- [x] Define a model-independent async `StemSeparationEngine` contract.
- [x] Add stem mixer and stem export.
- [x] Add timestamped lyric editor.
- [x] Add editable chord timeline.
- [x] Add ChordPro import, transposition, and export.
- [x] Add cancellable background processing and result caching.

## M5: Final Verification

- [x] Exercise import, selection, playback, seeking, pitch, tempo, reset, and
  editor tabs with a representative CCS recording.
- [x] Run the complete debug suite: 59 tests, zero failures.
- [x] Run an optimized release build and whitespace checks.
- [x] Record the existing unconfigured `swift format lint` baseline.
