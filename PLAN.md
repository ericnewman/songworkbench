# SongWorkbench Plan

The implementation authority for the complete analysis feature set is
`REQUIREMENTS.md`, derived from the confirmed Complete Song Analysis PRD. This
historical plan records the original architecture and completed foundation.

## Product Goal

Build a native macOS practice and song-analysis application that can import
recordings, separate stems, change pitch and tempo, transcribe lyrics, estimate
chords, and export useful practice assets such as ChordPro charts.

## Technical Direction

- SwiftUI for the macOS interface.
- AVFoundation and AVAudioEngine for decoding, playback, mixing, seeking, and
  the initial real-time pitch shifter.
- Accelerate/vDSP for FFT, chroma, beat, and chord-analysis primitives.
- Core ML for on-device stem separation.
- Small Swift Package Manager dependencies only where they outperform native
  frameworks or remove substantial implementation risk.
- Processing engines isolated behind protocols so models and libraries can be
  benchmarked or replaced without changing the UI.

Minimum deployment target: macOS 14. The initial package has no third-party
runtime dependencies.

## Candidate Libraries

| Capability | Initial choice | Candidate to evaluate |
| --- | --- | --- |
| Playback and mixing | AVAudioEngine | AudioKit |
| Pitch shifting | AVAudioUnitTimePitch | Signalsmith Stretch |
| Waveform | Native placeholder | AudioKit Waveform |
| Music theory | Small local value types | AudioKit Tonic |
| Transcription | Protocol boundary | FluidAudio, SwiftWhisper |
| Stem separation | Protocol boundary | HTDemucs Core ML |
| Chord analysis | Accelerate/vDSP | Port existing Python algorithm |

Dependencies are adopted only after an accuracy, latency, binary-size, license,
and maintenance review.

## Architecture

```text
SwiftUI Features
    |
Application Model
    |
    +-- PlaybackEngine (AVAudioEngine)
    +-- StemSeparationEngine (optional Core ML implementation)
    +-- TranscriptionEngine (optional FluidAudio/Whisper implementation)
    +-- ChordAnalysisEngine (Accelerate/vDSP)
    +-- ProjectStore (versioned JSON and security-scoped bookmarks)
```

Audio processing services own no views. SwiftUI owns presentation state and
calls narrow service APIs. Long-running analysis uses structured concurrency,
cancellation, explicit progress values, and versioned disk caches.

## Milestones

### M1: Native Playback Slice

- Import one or more common audio files.
- Select a song from a sidebar.
- Play, pause, seek, and restart.
- Shift pitch from -12 to +12 semitones without changing tempo.
- Display duration, playback position, and errors.
- Build and test from the command line.

### M2: Practice Workspace

- Persist imported projects and settings.
- Waveform with zoom and loop-region selection.
- Independent tempo control and higher-quality offline export.
- Keyboard shortcuts and recent-file handling.

### M3: Analysis Spikes

- Benchmark HTDemucs Core ML on representative CCS recordings.
- Compare AVAudioUnitTimePitch with Signalsmith Stretch.
- Compare FluidAudio and SwiftWhisper word timing and lyric accuracy.
- Port the existing beat/chroma chord timeline to Accelerate and compare output.

### M4: Integrated Analysis

- Stem mixer with mute, solo, level, and export.
- Timestamped lyrics and editable chord timeline.
- ChordPro import/export and transposition.
- Background jobs with progress, cancellation, and cached results.

M1, M2, and M4 are implemented. M3 benchmark records live in `Benchmarks/`;
third-party ML engines remain optional until their fixed-corpus validation is
complete.

## M1 Acceptance Criteria

- `swift build` succeeds on the current Mac.
- Unit tests cover pitch-range normalization and song-import filtering.
- Imported MP3, M4A, WAV, AIFF, and FLAC URLs are accepted.
- Selecting a readable recording loads its duration.
- Pitch changes are expressed as integer semitones and applied immediately.
- Playback errors are visible and do not crash the app.
