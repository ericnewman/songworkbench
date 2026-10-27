# SongWorkbench: App Store Connect metadata (draft)

Status 2026-10-25: draft for Eric's review. Nothing has been entered in App Store Connect. Technical steps are in `RELEASE.md`.

## App record

| Field | Value |
|---|---|
| Platform | macOS |
| Name | SongWorkbench |
| Bundle ID | `com.endogenllc.songworkbench` (Release; Debug is `com.endogenllc.songworkbench.debug`) |
| SKU | `SONGWORKBENCH-MAC-1` |
| Primary language | English (U.S.) |
| Primary category | Music |
| Secondary category | Education |
| Version / build | 1.0 (1); increase the build on every upload |
| Copyright | 2026 Endogen LLC |
| Support URL | https://endogenllc.com |
| Privacy policy URL | https://endogenllc.com/privacy/ (draft page; not deployed yet) |

## Subtitle (30 characters max)

Stems, chords, beats, lyrics

## Description (draft, verify each feature claim before submitting)

SongWorkbench takes a song apart so you can learn it. Open an audio file or a track from your Music library and SongWorkbench separates the stems, finds the beat and the chords, and aligns the lyrics, all on your Mac.

- Separate vocals, drums, bass, guitar, piano, and other parts
- Detect beats, bars, and chords and lay them out as a chart
- Transcribe and align lyrics
- Analyze live input from a microphone or audio interface
- Everything runs on device; your music never leaves your Mac

## Keywords

stems,chords,separation,transcribe,lyrics,beat,practice,musician,guitar,vocals,karaoke

## App Privacy (nutrition label)

"Data Not Collected". Model downloads go to Hugging Face and GitHub and carry no user data.

## Age rating

4+ (all "None" / "No"). Confirm: if lyrics display arbitrary user content, the answer is still "No" for user-generated content shared with others.

## Review notes (draft)

Open any audio file (File ▸ Open) and choose Analyze. Bundled Core ML models ship in the app; optional larger models download on demand. Microphone access is used only for live analysis when the user chooses a live input.

## Open questions for Eric

- App size: bundled models are about 172 MB. Fine for the Mac App Store, but confirm the optional downloaded models' licenses allow redistribution (UVR, Demucs, Whisper, Qwen3-ASR, DrumSep).
- Screenshots: 16:10 Mac screenshots still needed.
