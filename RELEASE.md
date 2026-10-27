# TestFlight Release Checklist

SongWorkbench is a macOS app target. TestFlight distribution goes through
App Store Connect from an Xcode archive.

## Values to set before upload

- Release is set in `Project.swift`: bundle ID `com.endogenllc.songworkbench`,
  team `65FBMF6CMD`, copyright Endogen LLC, `ITSAppUsesNonExemptEncryption = NO`,
  and `Resources/PrivacyInfo.xcprivacy`. Debug keeps `com.local.SongWorkbench` so
  the development sandbox container doesn't move.
- Register `com.endogenllc.songworkbench` in Apple Developer and create the
  App Store Connect record (metadata draft: `AppStore.md`).
- A Release build installed locally uses a new, empty sandbox container. Copy
  data from `~/Library/Containers/com.local.SongWorkbench` if needed.
- Complete App Store Connect privacy answers for local audio files, downloaded
  model packages, and any network requests used to install models.

## Local verification

Run the normal repository gate:

```sh
make verify
```

Run the Xcode test suite:

```sh
xcodebuild test \
  -project SongWorkbench.xcodeproj \
  -scheme SongWorkbench \
  -destination 'platform=macOS,arch=arm64'
```

Compile an unsigned archive locally to validate archive structure without Apple
account credentials:

```sh
xcodebuild archive \
  -project SongWorkbench.xcodeproj \
  -scheme SongWorkbench \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/SongWorkbench.xcarchive \
  CODE_SIGNING_ALLOWED=NO
```

## Signed TestFlight archive

Signing values come from `Project.swift`:

```sh
xcodebuild archive \
  -project SongWorkbench.xcodeproj \
  -scheme SongWorkbench \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/SongWorkbench.xcarchive
```

Open the archive in Xcode Organizer and use Distribute App for App Store
Connect/TestFlight.

## Post-signing smoke test

Before submitting to external testers, run the signed sandboxed app and verify:

- Import a user-selected audio file.
- Analyze using locally installed models and, separately, model download/install.
- Confirm model package extraction succeeds inside the sandbox.
- Export ChordPro, mixed stems, and project data to a user-selected location.
- Quit and relaunch, then confirm the selected song, analysis, stems, and
  playback controls restore correctly.

## Current release configuration

- The app target uses App Sandbox entitlements.
- User-selected file read/write is enabled for imported audio, ChordPro import,
  stem import, and exports.
- Network client access is enabled for model downloads.
- The app icon is provided by `Resources/Assets.xcassets/AppIcon.appiconset`.
- Release signing is automatic and driven by `SONGWORKBENCH_DEVELOPMENT_TEAM`.
- The default bundle ID remains local for development until overridden with
  `SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER`.
