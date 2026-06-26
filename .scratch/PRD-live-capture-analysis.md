# Design: Live Capture → Saved Chart

Status: Design / scope only. No code in this pass.
Author: design session (parallel to two other SongWorkbench sessions —
Apple Music library loading; ChordPro ball-offset slider). Does not touch their files.
Schema baseline: `SongAnalysisDocument.currentSchemaVersion == 5` (would migrate to 6).

---

## 1. Summary

Add a **Live Capture** analysis mode. The user plays a song from any source the OS
can legitimately capture (local file in another app, an unprotected streaming app,
the room/mic, or — where the OS permits — Apple Music). SongWorkbench taps that audio
**in real time**, runs it through the *existing* harmony (Accelerate/vDSP) and lyric
(FluidAudio / whisper.cpp) engines, and saves the **derived chart** (chord timeline +
timestamped lyrics + ChordPro draft) into the song's `SongAnalysisDocument`.

The captured audio is **transient analysis input only**. No audio is persisted into the
project, written to the library, or exported. We save analysis — a chart — exactly as if
the user had written the chords down by ear. This is the load-bearing product constraint
and every architectural decision below honors it.

This mode does **not** attempt to defeat, weaken, or work around FairPlay or any DRM. On
protected paths the OS may deliver silence; we detect that and tell the user, never
producing a silent/blank chart.

---

## 2. Architecture

### 2.1 Where the tap sits

A new capture layer feeds the **same** analysis primitives the offline file path already
uses. Today's offline entry point is:

```
AudioFileAnalysisService.analyze(url:)            // Sources/SongWorkbench/AudioFileAnalysisService.swift
  → loadMonoSamples(url:)  -> ([Float], sampleRate)
  → ChordAnalysisPipeline(configuration:).analyze(samples: [Float])   // ChordClassification.swift
  → BeatTracker().analyze(samples:sampleRate:)                        // BeatTracking.swift
  → MusicalKeyEstimator().estimate(from: chords)                      // MusicalKey.swift
```

The harmony path consumes a flat `[Float]` mono sample array, framed by `MonoSampleFramer`
(frame 8192 / hop 4096) → `MagnitudeSpectrumAnalyzer` → `ChromaAnalyzer` → `ChordClassifier`.
**This is incrementally feedable**: a rolling buffer of captured samples can be framed and
classified live. We reuse `MonoSampleFramer`, `MagnitudeSpectrumAnalyzer`, `ChromaAnalyzer`,
`ChordClassifier`, `ChordAnalysisPipeline`, `BeatTracker`, `MusicalKeyEstimator`,
`ChordEventReducer`, and `BassInformedChordRefiner` **unchanged**.

The lyric path is different: `TranscriptionEngine.transcribe(request:)` takes a
`TranscriptionRequest(audioURL:)` — it is **whole-file / offline** (FluidAudio Parakeet and
whisper.cpp both want a finished file). It cannot consume a live stream as-is. The design
reconciles this below (§2.4) without reimplementing the engines and without persisting audio.

### 2.2 New components (all new files — no edits to other sessions' files)

| New type | Role | Mirrors / plugs into |
| --- | --- | --- |
| `AudioCaptureSource` (protocol) | Vends a live mono `[Float]` stream + sample rate + level/silence telemetry; `start()/stop()/cancel()`. | Same shape of narrow-protocol boundary as `StemSeparationEngine` / `TranscriptionEngine`. |
| `ProcessTapCaptureSource` | Core Audio process tap / ScreenCaptureKit audio for capturing another app's output. | Implements `AudioCaptureSource`. |
| `LoopbackDeviceCaptureSource` | Captures from a user-installed virtual device (BlackHole/Loopback) via `AVAudioEngine.inputNode`. | Implements `AudioCaptureSource`. |
| `MicrophoneCaptureSource` | Room capture via the mic input node. | Implements `AudioCaptureSource`. |
| `TransientCaptureBuffer` | Bounded in-memory ring of mono `Float` PCM. Never touches disk for chords. Caps memory; drops oldest. | Feeds `MonoSampleFramer`. |
| `LiveHarmonyAnalyzer` | Pumps the ring through framer→chroma→classifier on a cadence, emitting `[ChordObservation]` with wall-clock-relative timestamps. | Wraps existing `ChordAnalysisPipeline` parts; output identical type to offline. |
| `CaptureMuteDetector` | Tracks RMS/peak over a sliding window; raises `mutedOrSilent` when capture stays below a floor past a grace period. | Drives the muted-capture UX (§4). |
| `LiveCaptureSession` (`@MainActor`, `ObservableObject`) | Orchestrates source + buffer + analyzer + mute detector; publishes live state; on stop, assembles results and hands them to `AppModel` for persistence. | New session object analogous to `SongAnalysisCoordinator`. |
| `LiveCaptureStage` *(optional, Phase 3)* | An `AnalysisStageRunning` adapter so live capture can also run inside `SongAnalysisPipeline`. | Implements existing `AnalysisStageRunning`. |

### 2.3 Harmony (chords): true real-time, in-memory only

`LiveHarmonyAnalyzer` consumes the `TransientCaptureBuffer` on a timer/async cadence
(e.g. every ~0.5–1 s), frames the newly available samples with `MonoSampleFramer`, and runs
the same chroma→`ChordClassifier` path. Observations accumulate as `[ChordObservation]`
keyed to capture-relative time. On stop, the accumulated observations are reduced exactly
like the offline path: `BassInformedChordRefiner` (only if a stem/bass source is available —
not in live mode by default) and `ChordEventReducer.events(from:)` → `[EditableChordEvent]`,
with `BeatTracker`/`MusicalKeyEstimator` run once over the retained buffer window for tempo
and key. **No file is written for chords at any point.**

### 2.4 Lyrics: honoring "no audio is stored" against a whole-file engine

The existing engines need a `URL`. Two honest options; the design recommends (A) for the
first lyric-capable phase and flags (B) as the principled end state.

- **(A) Transient shred-on-read scratch (recommended for Phase 2).** Capture into the
  in-memory ring; when the session stops, render the retained window to a **single transient
  scratch file inside the sandbox temp container** (`NSTemporaryDirectory()` / an
  app-temp subdir), call the existing `TranscriptionEngine.transcribe(request:)` on it, then
  **securely delete (shred) the scratch immediately** in a `defer`, on cancel, and on crash
  cleanup. This temp is never added to the project, never referenced by
  `SongAnalysisDocument`, never exported, and never surfaced in the UI. It satisfies
  NFR-003 (temp cleanup) and NFR-001 (no upload). It is the smallest reuse of the existing
  engines. **Caveat to state plainly:** a transient file does briefly exist on disk during
  the transcription pass — "no *persisted/exported* audio" is fully honored; "literally zero
  bytes ever hit disk" is not, for lyrics, under engine reuse.

- **(B) True streaming ASR (future / principled).** A streaming transcription engine (e.g. a
  chunked FluidAudio session that accepts PCM windows) would keep lyrics fully in-memory like
  chords. This is a **new engine behind the existing `TranscriptionEngine`-style boundary**,
  not a reimplementation of harmony. It is larger work and out of scope for Phase 1–2; noted
  as the path to "zero audio bytes on disk, ever."

Either way, transcription output normalizes into the existing `TimedTranscriptionSegment` →
shared `TimedLyricSegmentGrouper` → `[TimedLyricSegment]` (draft) exactly as the offline
pipeline does. No lyric-specific persistence is added.

### 2.5 Persistence: reuse `SongAnalysisDocument` + `ProjectStore`

Derived results are written through the **existing** persistence with no new store:

- Chords → `SongAnalysisDocument.chords` (`[EditableChordEvent]`, `chordReviewState = .draft`).
- Lyrics → `SongAnalysisDocument.lyrics` (`[TimedLyricSegment]`, `lyricReviewState = .draft`).
- Tempo/key/beats → `estimatedBPM`, `estimatedKey`, `beatTimes`.
- ChordPro → reuse `ChordProDraftBuilder` to produce `chordProSource` (draft), governed by the
  existing `ChordProReplacementPolicy` so reviewed/imported charts are never silently replaced.
- Provenance → `AnalysisProvenance` with a **new `AnalysisSourceKind.liveCapture`** case
  (today: `recording`, `vocalsStem`, `stemSet`, `accompanimentStem`). `sourceDigest` cannot be
  a file content hash (no file) — use a session identity digest (source type + sample rate +
  start time + duration) so cache/staleness rules still have a stable key per
  PERSIST-002/003. `loadedFromCache` is always `false` for a live run.
- Stage state → `stageRecords` for the harmony / transcription / chordpro stages, marked
  computed (never cached), `draft`.
- Schema bumps `currentSchemaVersion` 5 → 6; older docs decode with defaults (PERSIST-005).

`AppModel` (`@MainActor`) gains a `LiveCaptureSession` handle and a save path that funnels the
assembled document through the same `saveProjects()` / `JSONProjectStore` route used by
`analyzeSelectedSong`. **No audio reference (`StoredAudioReference`) is ever created for a live
capture** — the song keeps whatever recording it already had (or none).

### 2.6 Data flow (text)

```
[OS audio]                                  (chords: never leaves memory)
   │
AudioCaptureSource ─► TransientCaptureBuffer (in-memory ring, bounded)
   │                        │
   │                        ├─► LiveHarmonyAnalyzer ─► [ChordObservation] ─► ChordEventReducer ─► [EditableChordEvent]
   │                        │        (MonoSampleFramer/Chroma/ChordClassifier, reused)
   │                        │
   │                        └─(stop)─► [transient scratch in sandbox temp]  (lyrics path A)
   │                                        │  shredded in defer/cancel/crash-clean
CaptureMuteDetector ─► muted?              ▼
                                   TranscriptionEngine.transcribe(request:) ─► TimedLyricSegment[]
                                                                        │
                       ChordProDraftBuilder ◄── chords + lyrics ────────┘
                                   │
                            SongAnalysisDocument (draft) ─► AppModel ─► JSONProjectStore (ProjectStore)
```

---

## 3. Per-source capability matrix

Reliability is qualitative: ✅ good, ⚠️ conditional, ❌ not viable.

| Source | Capture mechanism | Real-time chords | Lyrics | Reliability | Key limitations |
| --- | --- | --- | --- | --- | --- |
| **Local file played in another app** (or our own playback) | Process tap / ScreenCaptureKit audio, or loopback device | ✅ | ✅ (Phase 2) | ✅ High | Real-time only (no faster-than-playback); for our *own* file, offline `analyze(url:)` is strictly better — steer the user there. |
| **Unprotected streaming app** (browser/desktop player, non-DRM) | Process tap / ScreenCaptureKit audio, or loopback | ✅ | ⚠️ | ⚠️ Medium | Quality depends on stream bitrate, ads/crossfade, UI sounds bleeding in; capture-quality dependent. |
| **Apple Music / FairPlay-protected** | Same mechanisms; OS may mute protected output | ⚠️→❌ | ⚠️→❌ | ❌ Low / fragile | OS frequently delivers **silence** on protected tap paths; behavior varies by macOS version. We **detect mute and tell the user** (§4); we do **not** bypass DRM. Treat as best-effort, often unavailable. |
| **Microphone / room** | `AVAudioEngine.inputNode` (mic) | ⚠️ | ⚠️ | ⚠️ Medium-Low | Room noise, reverb, speaker EQ, bleed degrade both chroma and ASR; usable for sketching, not clean charts. Needs mic permission. |

Cross-cutting limitations for **all** sources: (1) **real-time only** — accuracy is bounded by
single-pass, low-latency analysis and cannot match offline multi-pass file analysis;
(2) **capture-quality dependent** — garbage in, garbage out; (3) **no audio retained** — the
user cannot re-run a better pass later without re-capturing; (4) lyrics are **draft** and for
**personal practice use only**.

**Recommendation baked into UX:** when the chosen source is a local file the app could open
directly, surface "Analyze the file directly for best accuracy" — live capture is for sources
we *can't* open as a file.

---

## 4. UX

### 4.1 Entry & session

- New **Live Capture** action in the analysis workspace (sits beside the existing
  *Analyze Song* / `analyzeSelectedSong`). Opens a capture sheet.
- **Source picker:** Local-app/other-app audio (process tap), Loopback device (lists installed
  virtual devices; links to setup if none), Microphone. Apple Music shown with an explicit
  "may be muted by macOS — best effort" note.
- **Arm → Start:** user starts playback in the source app, then presses Record-Analyze.
  A countdown/level meter confirms signal before committing (prevents blank charts).

### 4.2 Live monitoring

- **Live level meter + signal/mute indicator** (driven by `CaptureMuteDetector`).
- **Rolling chord readout:** the most recent detected chords scroll live, reusing the existing
  editable chord-timeline view in a read-while-capturing state.
- **Lyrics:** "captured, transcribed on stop" status in Phase 2 (whole-file engine); a live
  partial transcript only if/when streaming ASR (option B) lands.
- Elapsed time, captured-window length, and a clear "audio is not being saved" affordance.

### 4.3 Review, edit, fine-tune, save

- On **Stop**, results populate the **existing editable chord timeline** and **timed-lyric
  editor** as **draft** — fully editable with the existing add/remove/edit/retime operations.
- **Fine-tuning offset:** integrate the **new ChordPro ball-offset slider** (owned by the other
  session) as the global timing nudge for the captured chart — capture introduces a roughly
  constant latency (tap + buffer + OS), so a single offset correction is high-value. *We depend
  on that slider's published offset; we do not modify its files.* Coordinate on the read API.
- User reviews, edits, then **Mark Reviewed** (existing `markChordsReviewed` /
  `markLyricsReviewed`) and **Save** → persisted via `ProjectStore`.
- ChordPro draft generated via existing builder; existing transpose/export works on it.
  **Chords export normally. Lyrics have no new sharing/export affordance** (§6).

### 4.4 Muted / empty capture messaging

When `CaptureMuteDetector` reports sustained silence past the grace window:
- **Halt** before producing a chart; never save a blank/silent result.
- Message names the likely cause and remedy, e.g.: *"No audio is reaching SongWorkbench. If
  you're capturing Apple Music, macOS may be muting protected playback — this is expected and
  can't be bypassed. Try an unprotected source, a loopback device, or the microphone."*
- Offer: switch source, open loopback setup help, or cancel.

---

## 5. Entitlements, permissions, user setup

Current `SongWorkbench.entitlements`: app-sandbox, user-selected read-write, network-client,
`assets.music.read-only`. Info.plist already has `NSMicrophoneUsageDescription` and
`NSAppleMusicUsageDescription`.

Additions / setup required:

| Need | Mechanism | Notes |
| --- | --- | --- |
| **Microphone & input-device capture** (mic + loopback devices appear as input devices) | `com.apple.security.device.audio-input` entitlement + existing `NSMicrophoneUsageDescription`; runtime `AVCaptureDevice` authorization prompt. | Required for `MicrophoneCaptureSource` and `LoopbackDeviceCaptureSource`. |
| **Capture another app's audio** (process tap / ScreenCaptureKit audio) | ScreenCaptureKit audio capture → Screen & System Audio Recording permission (TCC), prompted at first use; or Core Audio process-tap API (macOS 14.4+). | Sandbox + ScreenCaptureKit audio interaction must be validated per macOS version; gate by availability. Add `NSAudioCaptureUsageDescription`-style purpose string as required by the chosen API. |
| **Loopback device path** | User installs BlackHole (free) or Loopback; routes source app → virtual device; SongWorkbench selects it as input. | Zero special entitlement beyond audio-input. Provide in-app setup guide + device picker. Most reliable path for unprotected app audio under sandbox. |
| **No new file persistence** | Reuse user-selected RW only for the project doc; transient lyric scratch lives in the app temp container (no entitlement change). | Confirms NFR-001/003 posture. |

Sandbox reality check (a Phase-0 verification item): confirm ScreenCaptureKit-audio / process
tap actually function under the current App Sandbox + Hardened Runtime config on the target
macOS versions. If a process tap is not viable in-sandbox, the **loopback device** path becomes
the primary "other app" mechanism and process-tap becomes best-effort.

---

## 6. Honest risks

- **Accuracy expectations.** Real-time single-pass analysis is materially worse than the
  offline file pipeline. Chords from a clean digital tap are usable as a draft; mic/room and
  streaming-with-bleed are rough. Lyrics from live capture are draft-quality and worse than
  isolating vocals then transcribing (the documented offline best practice). Set expectations in
  UI; everything lands as `draft`.
- **FairPlay capture fragility.** Protected Apple Music output is commonly muted by the OS on
  tap/loopback paths, and this behavior changes across macOS releases. The feature must degrade
  gracefully (detect + explain), and we must be clear it **may simply not work** for Apple Music
  and that we will not attempt to defeat DRM. Do not market Apple Music as a supported live
  source — list it as best-effort, often-unavailable.
- **Sandbox / entitlement fragility.** Audio-capture entitlements and ScreenCaptureKit-audio
  behavior under sandbox vary by macOS version; Phase 0 must de-risk this before UI build.
- **Personal-use lyric boundary.** Captured lyrics are copyrighted text saved **only for the
  user's personal practice**. The design adds **no lyric sharing, redistribution, or
  lyric-export affordance**. Chords/tempo/key are factual analysis and export normally as a
  chart. This boundary is a product invariant, not a toggle.
- **"No file written" nuance.** Fully honored for the saved project and for chords. For lyrics
  under engine reuse (option A), a transient sandbox-temp scratch briefly exists and is shredded;
  only option B (streaming ASR) achieves literally-zero-bytes-on-disk. Stated openly so the
  constraint isn't quietly violated.
- **Latency/timing drift.** Capture adds near-constant latency plus possible clock drift between
  source app and capture; the ball-offset slider corrects the constant part, but long captures
  may drift. Mitigation: periodic re-anchoring and bounded session length.

---

## 7. Phased implementation plan & rough effort

**Phase 0 — Capture feasibility spike (de-risk first).** *~3–5 days.*
Prove, on the target macOS versions, that we can get a clean mono `[Float]` stream under the
current sandbox/hardened-runtime config from: (a) a loopback device, (b) a process tap /
ScreenCaptureKit audio, (c) the mic. Confirm FairPlay-muted behavior on Apple Music and verify
`CaptureMuteDetector` fires. Output: a tiny harness + a go/no-go note per mechanism. **No UI.**
*This phase decides whether process-tap or loopback is the primary "other app" path.*

**Phase 1 — Live chords (recommended first shippable).** *~1–1.5 weeks.*
`AudioCaptureSource` protocol + the best capture impl from Phase 0 + `TransientCaptureBuffer` +
`LiveHarmonyAnalyzer` reusing the vDSP chord path + `CaptureMuteDetector` + minimal
`LiveCaptureSession`. Live chord readout, mute detection/messaging, review in the existing chord
timeline, ball-offset nudge, save chords+tempo+key+ChordPro draft via `ProjectStore`. New
`AnalysisSourceKind.liveCapture`, schema 5→6 migration, provenance/staleness, tests
(framer/feeding, mute detection, no-audio-persisted assertion, migration). **Lyrics excluded.**
Fully in-memory → strongest "no audio written" story.

**Phase 2 — Live-captured lyrics.** *~1–1.5 weeks.*
Transient shred-on-read scratch (option A) into the existing `TranscriptionEngine`; normalize via
existing grouper into draft `TimedLyricSegment`s; enforce personal-use boundary (no lyric export
/ sharing). Tests for shred-on-stop/cancel/crash, draft state, and "no audio reference created."

**Phase 3 — Polish / integration (optional).** *~1 week.*
`LiveCaptureStage : AnalysisStageRunning` so live capture composes with `SongAnalysisPipeline`;
loopback-device setup guide; accessibility (VoiceOver labels per UI-010); evaluate streaming ASR
(option B) for fully in-memory lyrics.

**Recommended first phase: Phase 0 then Phase 1.** Phase 0 because the entire feature hinges on
whether legitimate capture works under sandbox across macOS versions — cheap to prove, expensive
to assume. Phase 1 because live **chords** are the high-value, low-risk core: it reuses the
Accelerate/vDSP engine unchanged, is genuinely real-time, and keeps audio entirely in memory so
the "save the analysis, never the recording" promise is airtight before lyrics introduce the
transient-scratch nuance.
```
