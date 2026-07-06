# iPad (iPadOS) Port — Feasibility Audit & Plan

Branch: `ipad-support` (worktree). Date: 2026-07-05.

## Verdict up front

Feasible, with no dependency-level hard blockers: **all three heavyweight dependencies
ship iOS support**, and after a thin shim layer the entire shared source tree compiles
for iOS. Current state:

| Check | Result |
| --- | --- |
| `swift build --jobs 1` (macOS regression) | passes |
| `tuist generate` (mac + iPad targets) | passes (Tuist 4.195.17) |
| `xcodebuild -scheme SongWorkbenchiPad -destination 'generic/platform=iOS Simulator'` | **BUILD SUCCEEDED** |

Compiling is not shipping: the app *runs* as a macOS three-pane desktop squeezed onto a
tablet, with export/import/stem-folder flows stubbed out. The ranked work below is what
turns "compiles" into "usable".

## 1. Audit — macOS-only dependencies found

### 1.1 AppKit usage (all now shimmed or guarded)

| Location (pre-port line numbers) | macOS-only API | iPadOS replacement / disposition |
| --- | --- | --- |
| `ContentView.swift:216` | `NSScreen.main?.visibleFrame` | `PlatformScreen.visibleHeight(fallback:)` (UIKit apps don't own the screen — Split View/Stage Manager) |
| `ContentView.swift:231` | `VSplitView` | `PlatformVSplit` — real `VSplitView` on macOS, `VStack` fallback on iPad (needs a proper adaptive layout later) |
| `SongWorkbenchApp.swift:17` | `NSApplication.willTerminateNotification` | `PlatformLifecycle.willTerminateNotification` → `UIApplication.willTerminateNotification` |
| `SongWorkbenchApp.swift:28–38` | `Window` scenes, `.defaultSize`, `.windowResizability` | `#if os(macOS)`; iPad gets the main `WindowGroup` only. About/Lyric Blend need sheet/navigation presentation on iPad |
| `SongWorkbenchApp.swift:39–99` | `.commands`, `CommandMenu` (menu bar) | `#if os(macOS)` for now. Note `.commands` *is* available on iPadOS (hardware-keyboard menu); porting them is easy follow-up work |
| `WorkspaceEditorsView.swift:1217,1230,3657,3671`; `ChordProReadOnlyView.swift:189` | `NSOpenPanel` / `NSSavePanel` (ChordPro import/export, stem folder, mix export) | Guarded with `#if os(macOS)`; iPad branch sets an explanatory `errorMessage`. Real fix: `.fileImporter` / `.fileExporter` (the main song-import flow already uses `.fileImporter` — cross-platform) |
| `WorkspaceEditorsView.swift:1263` | `NSWorkspace.shared.open` (JustChords hand-off) | Guarded; iPad equivalent would be `UIApplication.open` with a custom URL scheme or a share sheet |
| `WorkspaceEditorsView.swift:2738` | `NSFont.monospacedSystemFont` (ChordPro grid "M"-width metrics) | `PlatformFont` typealias (`NSFont`/`UIFont` — same API, and `NSString.size(withAttributes:)` is cross-platform) |
| `WorkspaceEditorsView.swift:2732` | `.onExitCommand` (Escape cancels lyric edit) | `.onExitCommandCompat` — no-op on iPad (wire `UIKeyCommand` later for hardware keyboards) |
| `WorkspaceEditorsView.swift:1180,2022`; `ChordProReadOnlyView.swift:24` | `Color(nsColor: .textBackgroundColor)` | `Color.swTextBackground` → `UIColor.systemBackground` on iPad |
| `ModelPackageManager.swift:62` | `Process()` + `/usr/bin/ditto` (model zip extraction) | **No iOS equivalent of `Process`.** Guarded; iPad throws `extractionUnsupportedOnPlatform`. Needs an in-process unzip (Apple Archive framework or a small zip reader) before model installs work on iPad |
| `AudioCaptureSources.swift:19,26,35,139` | `AudioDeviceID` (Core Audio HAL), `AUAudioUnit.setDeviceID` (BlackHole/loopback selection) | `PlatformAudioDeviceID` typealias + `#if os(macOS)` around device selection. iOS routes input via `AVAudioSession` ports; loopback-device capture has no iPad analogue |
| `AudioCaptureSources.swift:126` | `CGPreflightScreenCaptureAccess` (system-audio capture probe) | `PlatformCapture.screenRecordingPreflight()` → `false` on iPad. System-audio capture (ScreenCaptureKit / process taps) is macOS-only, period |
| `PracticeProject.swift:65,88`; `SongAnalysisDocument.swift:543,556` | `URL.bookmarkData(options: .withSecurityScope)` / `.withSecurityScope` resolution | `URL.appScopedBookmarkData()` / `URL(resolvingAppScopedBookmark:)` — on iOS, document-picker bookmarks are implicitly security-scoped and the macOS option doesn't exist |
| `MusicLibrary.swift:74–120` | `iTunesLibrary` / `ITLibrary` | Already `#if canImport(iTunesLibrary)`-guarded upstream (empty provider elsewhere). iPad replacement: `MediaPlayer`/MusicKit — but DRM'd (Apple Music) tracks can't be read as PCM, so analysis only works for local/purchased files |

Cross-platform-as-is (verified, no change needed): `startAccessingSecurityScopedResource`
call sites (~25, same API on iOS), `keyboardShortcut` (iOS 14+), `.onHover`
(`Theme.swift:123`, iPadOS 13.4+ pointer), `NSString`/`NSHomeDirectory` (Foundation),
`#available(macOS …, *)` checks, `AVCaptureDevice` mic authorization.

### 1.2 Frameworks / dependencies

| Dependency | iOS support | Evidence |
| --- | --- | --- |
| whisper.cpp v1.9.1 (`WhisperFramework` binary xcframework) | yes | xcframework ships `ios-arm64` and `ios-arm64_x86_64-simulator` slices (also tvOS/visionOS). Local package platforms updated to `[.macOS(.v14), .iOS(.v17)]` |
| FluidAudio 0.15.4 (Parakeet ASR) | yes | its `Package.swift` declares `.iOS(.v17)` |
| onnxruntime-swift-package-manager 1.24.2 (htdemucs 6-stem) | yes | its `Package.swift` declares `.iOS(.v15)`; CoreML execution provider available on iOS (`ORTIsCoreMLExecutionProviderAvailable` is already runtime-checked) |
| CoreML (stem separation), Accelerate, AVFoundation, CryptoKit | yes | system frameworks, same API on iOS |
| iTunesLibrary | mac-only | already isolated behind `canImport` |
| ScreenCaptureKit / Core Audio process taps (system-audio capture spike) | mac-only | probe now reports unsupported on iPad |

### 1.3 App lifecycle, sandbox, entitlements

- **Scenes**: mac keeps `WindowGroup` + two auxiliary `Window` scenes + menu-bar
  commands; iPad currently gets the main `WindowGroup` only.
- **Entitlements**: `SongWorkbench.entitlements` is macOS-specific (app-sandbox,
  app-scope bookmarks, music-library read). The iPad target intentionally has **no
  entitlements file**; iOS sandboxing is implicit. Usage-description keys
  (microphone, media library) are in the iPad Info.plist; `UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace` are set so songs can be dropped in via Files.
- **Container paths**: all storage goes through `FileManager` search paths, which map
  cleanly to the iOS sandbox; no absolute-path assumptions found outside the guarded
  JustChords lookup.
- **AVAudioSession**: macOS has none; iPadOS requires a category before
  `AVAudioEngine` starts. `PlatformAudioSession.configureForPlayback()` (`.playback`)
  is called at app startup — no-op on macOS. Capture flows will need
  `.playAndRecord` + route/interruption handling later.

## 2. What was scaffolded (this branch)

- **`Sources/SongWorkbench/PlatformShims.swift`** (new): `PlatformScreen`,
  `PlatformFont`, `PlatformLifecycle`, `PlatformAudioSession`,
  `PlatformAudioDeviceID`, `PlatformCapture`, `Color.swTextBackground`,
  `URL.appScopedBookmarkData()`/`URL(resolvingAppScopedBookmark:)`,
  `PlatformVSplit`, `View.onExitCommandCompat`.
- **Guards/shims applied** in: `ContentView`, `SongWorkbenchApp`,
  `WorkspaceEditorsView`, `ChordProReadOnlyView`, `ModelPackageManager`,
  `AudioCaptureSources`, `PracticeProject`, `SongAnalysisDocument` — all
  behavior-preserving on macOS (mac branches are the original code verbatim).
- **`Project.swift`**: new `SongWorkbenchiPad` target — `destinations: [.iPad]`,
  `deploymentTargets: .iOS("17.0")`, same sources/resources/package deps as mac,
  `TARGETED_DEVICE_FAMILY = 2`, `UILaunchScreen`, all orientations, file-sharing
  keys; plus a shared `SongWorkbenchiPad` scheme. **Mac target and its signing
  settings untouched** (team 65FBMF6CMD).
- **`Dependencies/WhisperFramework/Package.swift`**: platforms now include `.iOS(.v17)`.
- **`Resources/Assets.xcassets/AppIcon.appiconset`**: added a universal-iOS
  1024×1024 entry reusing `icon_512x512@2x.png`.

## 3. Ranked remaining work

1. **UI adaptation (largest)** — the layout assumes a >=1300pt window with three
   fixed columns. Needs: adaptive layout (NavigationSplitView / tabbed panes) for
   iPad sizes and Split View/Stage Manager; a real replacement for the
   `PlatformVSplit` VStack fallback; port menu-bar commands to iPad
   `.commands`/toolbar; touch-target and text-editing passes; present About/Lyric
   Blend without `Window` scenes.
2. **Document & file flows** — replace the stubbed panel flows with
   `.fileImporter`/`.fileExporter` (song import already works); decide iPad storage
   story (on-device Documents vs iCloud); re-test bookmark persistence with
   document-picker URLs.
3. **Model packaging & performance** — in-process unzip to replace `ditto`
   (currently **blocks model installs on iPad**); model download/storage UX;
   validate htdemucs (hundreds of MB, memory-hungry) + Whisper + Parakeet on real
   iPad hardware — memory limits and thermal throttling are the real risk, and the
   simulator proves nothing here (no ANE).
4. **Audio session & routing** — per-flow categories (`.playback` vs
   `.playAndRecord`), interruption/route-change handling, optional background-audio
   mode; mic capture works, but loopback-device and system-audio capture do not
   exist on iPadOS (feature should be hidden there).
5. **Music library access** — **DONE (reduced).** `MediaPlayerMusicLibrary`
   (`MusicLibrary.swift`) enumerates the on-device library via `MPMediaQuery` so the
   picker is populated instead of empty. Honest limitation: iOS never exposes a local
   file URL for library tracks (`MPMediaItem.assetURL` is an `ipod-library://` URL
   readable only via an async AVFoundation export, not the file-copy import path this
   app uses), so tracks are browsable but classify as `.platformUnavailable` and can't
   be handed to the analyzer directly — the Files-app import remains the primary path.
   Gated on `NSAppleMusicUsageDescription` (set on the iPad target). Not yet done:
   async export-to-temp-file so DRM-free tracks become analyzable.
6. **Test target for iOS** — `SongWorkbenchTests` is mac-only; decide which suites
   should run against the iPad destination.

## 4. Hard blockers

None at the dependency level — every third-party dependency ships iOS slices or
declares iOS platforms. The honest risks are practical:

- **htdemucs stem separation on iPad hardware** (memory + speed) is unproven; if it
  doesn't fit, stems need a lighter model or server-side separation.
- **Model zip extraction** is disabled on iPad until an in-process unzip lands
  (small, well-understood task).
- **System-audio/loopback capture is impossible on iPadOS** — that feature stays
  mac-only by platform policy, not by code.
