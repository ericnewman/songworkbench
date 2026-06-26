# Phase 0 — Live-capture feasibility spike: GO/NO-GO

Status: Done (headless). Branch: `live-capture-phase0`. Baseline: `main` @ e4e58e0.
Scope: prove a clean real-time PCM stream is reachable under App Sandbox + Hardened
Runtime, and that muted/empty (FairPlay) capture is detectable. No real feature, no UI,
no persistence. See `.scratch/PRD-live-capture-analysis.md` §2, §5, §7.

## Verdict per capture path

| Path | Verdict | Basis |
| --- | --- | --- |
| **Loopback device** (BlackHole/Loopback as an input) | ✅ **GO** | `AVAudioEngine.inputNode` + `com.apple.security.device.audio-input`. A loopback is an ordinary input device — no special API, no screen-recording TCC. Recommended primary "other app" path. *Runtime-unverified headless.* |
| **Microphone / room** | ✅ **GO** | Same `AVAudioEngine` path, default input. Mic TCC prompt + existing `NSMicrophoneUsageDescription`. *Runtime-unverified headless.* |
| **System audio / "another app"** (ScreenCaptureKit audio or Core Audio process tap) | ⚠️ **CONDITIONAL — needs on-device validation** | Both APIs exist (SCK macOS 13+, process tap 14.4+) but require Screen & System Audio Recording TCC and have sandbox behavior that varies by macOS version. Probe-gated, not built. `CaptureSourceCatalog.makeSource(.systemAudio)` throws `requiresOnDeviceValidation`. |
| **Apple Music / FairPlay** | ❌ **NO-GO as a supported source** (best-effort only) | OS commonly delivers digital silence on protected tap/loopback paths. We **detect** it (mute monitor) and tell the user; we never bypass DRM. |

**Path decision for Phase 1:** lead with the **loopback device** for "other app" audio
(most reliable under sandbox, cheapest entitlement). Treat system-audio (SCK/process-tap)
as a second, on-device-validated path; promote it to primary only if validation shows it
works reliably in-sandbox on the target macOS versions.

## What was built (all new files; no other sessions' files touched)

- `Sources/SongWorkbench/AudioCapture.swift` — pure, headless-testable core:
  - `AudioCaptureSource` protocol (narrow boundary, mirrors `TranscriptionEngine` shape).
  - `CaptureSourceKind`, `CaptureBuffer`, `CaptureError`.
  - `captureRMS(_:)` (pure) + `CaptureMuteDetector.classify` (pure level → live/silent).
  - `CaptureMuteMonitor` (stateful: silence past a grace window → `silent`/blocked; any
    live buffer re-arms grace; pre-signal → `pending`).
  - `SyntheticCaptureSource` (test injection: start/stop-gated `feed`).
  - `CaptureFeasibilityProbe` (drives a source → `CaptureProbeResult` verdict).
- `Sources/SongWorkbench/AudioCaptureSources.swift` — real device-backed code (compiles;
  runtime-unverified headless):
  - `AVAudioEngineCaptureSource` — mic + loopback via `inputNode`, mono downmix, optional
    `AudioDeviceID` selection.
  - `AudioInputAuthorization` — TCC status/request helpers.
  - `SystemAudioCaptureProbe` / `SystemAudioFeasibility` — read-only check of SCK/process-tap
    availability + screen-recording permission (no capture started).
  - `CaptureSourceCatalog` — source selection; gates `.systemAudio`.
- `Tests/SongWorkbenchTests/AudioCaptureTests.swift` — 11 tests (below).
- `SongWorkbench.entitlements` — added `com.apple.security.device.audio-input`.

## Entitlements / permissions

- **Added entitlement:** `com.apple.security.device.audio-input` (mic + input/loopback
  devices). Already present and reused: app-sandbox, user-selected RW, network-client,
  `assets.music.read-only`.
- **Info.plist:** existing `NSMicrophoneUsageDescription` covers audio-input; no new key
  added. The system-audio path uses the **Screen & System Audio Recording** TCC permission,
  which has **no Info.plist usage string** — it is a system prompt (`CGRequestScreenCaptureAccess()`),
  preflighted with `CGPreflightScreenCaptureAccess()`. No new Info.plist string is required
  for it.
- **Runtime approvals the user must grant:**
  1. Microphone (mic + most loopback inputs) — TCC prompt on first capture.
  2. Screen & System Audio Recording — only if/when the system-audio path is enabled.
  3. Loopback path additionally needs the user to **install BlackHole/Loopback** and route
     the source app to it (no app entitlement beyond audio-input).
- Not changed: no schema bump, no new `AnalysisSourceKind.liveCapture`, no persistence —
  those are Phase 1 per the PRD.

## Muted-capture detection — how reliable

- FairPlay-muted output is **digital silence** → RMS exactly 0 → classified `silent`.
  Detection of true muting is essentially perfect because it is exact-zero, well below the
  `0.001` (~-60 dBFS) floor.
- The grace window (default 2 s) prevents false "muted" on slow starts / brief gaps; any
  live buffer re-arms it. The floor is the one real-world tuning knob (very quiet passages
  or a hot noise floor could need adjustment) — left configurable, flagged `ponytail:`.
- Verified headless via synthetic tone vs. silence buffers (see tests). The *classifier* is
  proven; what cannot be proven headless is that the OS actually delivers silence (vs. an
  error or nothing) on a real FairPlay tap — that is part of the on-device validation.

## Tests added (11, all green; full suite 258 pass)

RMS of tone/silence; tone→live, silence→silent (pure); monitor pending→silent past grace;
live re-arms grace; synthetic source delivers only while started; probe→live for tone;
probe→silent for muted source; catalog excludes synthetic; catalog builds device sources
and gates system-audio. (`testCatalogMakesDeviceSourcesAndGatesSystemAudio` also constructs
`AVAudioEngine` headlessly without crashing.)

## Honest blockers (headless env)

- No audio devices, no Music playback, no TCC prompts → the **real** sources
  (`AVAudioEngineCaptureSource`, system-audio) compile and are exercised only at the
  constructor level. **End-to-end capture, device selection, and actual FairPlay-mute
  behavior can only be confirmed on a real Mac.**
- System-audio sandbox viability across macOS versions is the single biggest unknown and is
  deliberately not implemented — it is the first on-device validation task for Phase 1.

## Recommended path into Phase 1 (live chords)

1. On a real Mac: validate `AVAudioEngineCaptureSource` end-to-end via a loopback device and
   the mic; confirm the mute monitor fires on a FairPlay source.
2. Validate the system-audio path (SCK audio first; process tap as fallback) in-sandbox;
   decide primary vs. best-effort.
3. Then build Phase 1 per PRD §7: `TransientCaptureBuffer` + `LiveHarmonyAnalyzer` reusing
   the existing vDSP chord path, wire `CaptureMuteMonitor` into the session, add
   `AnalysisSourceKind.liveCapture` + schema 5→6, persist chords/tempo/key/ChordPro draft.
   Lyrics stay out (Phase 2).
