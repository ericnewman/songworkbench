# SongWorkbench

Native macOS 14 SwiftUI application for practicing with and analyzing local
recordings. The shipping target has no third-party runtime dependencies.

## Features

- Import MP3, M4A, WAV, AIFF, and FLAC recordings.
- Play, seek, loop, pitch-shift by -12...+12 semitones, and adjust tempo.
- Render zoomable cached waveforms and export adjusted audio offline.
- Analyze tempo and an editable chord timeline with Accelerate/vDSP.
- Edit timestamped lyrics and import, transpose, or export ChordPro text.
- Generate or import six separated stems (vocals, drums, bass, guitar, piano,
  and other), audition them, mix with gain/mute/solo controls,
  and export the mix.
- Persist songs, settings, analysis, lyrics, chords, and stem references as
  versioned JSON with security-scoped bookmarks.
- Run analysis as cancellable jobs with source/version-keyed disk caching.

Stem separation and transcription use protocol boundaries. Evaluated model
engines are optional downloads and are not bundled with the app.

## Build And Test

```sh
swift run SongWorkbench
swift test
swift build -c release
```

In restricted automation environments, set writable module-cache paths:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/ccs-song-workbench-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ccs-song-workbench-swift-cache \
  swift test
```

The optimized executable is `.build/release/SongWorkbench`.

## Project Layout

- `Sources/SongWorkbench/`: application, audio services, analysis, and UI.
- `Tests/SongWorkbenchTests/`: focused service and integration tests.
- `Resources/Assets.xcassets/`: macOS app icon and accent color assets.
- `Benchmarks/`: dependency decisions, fixed-corpus results, and tools.
- `PLAN.md`: architecture and acceptance criteria.
- `REQUIREMENTS.md`: authoritative complete-analysis requirements and release gates.
- `RELEASE.md`: TestFlight/App Store Connect archive checklist.
- `TODO.md`: milestone status and remaining model-validation work.
