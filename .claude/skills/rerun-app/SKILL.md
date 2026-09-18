---
name: rerun-app
description: Rebuild the macOS SongWorkbench app from the latest code and relaunch it, replacing any running instance. Use when the user says "re-run the app", "restart the app", "run the latest code", or wants to see a change live in the real app.
---

# Re-run SongWorkbench (macOS app)

Verified 2026-09-17 from /Volumes/SSD/Developer/SongWorkbench. The checkout has moved twice
(out of iCloud 2026-09-08, then onto the SSD), so every path below is resolved with
`git rev-parse` instead of being named.

Build products land in `build/` INSIDE the checkout: the project sets `SYMROOT` and `OBJROOT`
(2026-09-18), overriding Xcode's global custom build location. Before that, every project and
every worktree on the machine wrote to one shared `/Volumes/SSD/XCODE-BUILD-SCRAPS`, so any build
anywhere replaced the app bundle a running instance had been launched from. Each worktree now has
its own `build/`, and `build/` is gitignored. Builds the Xcode target (NOT the SwiftPM binary — the
app needs its bundle, entitlements, and code signature for security-scoped
bookmarks), then swaps the running instance for the fresh build.

## Steps

Run these with the shell tool. From a surface with no shell (e.g. Claude
Desktop), run the same commands via desktop-commander's `start_process`
(use `read_process_output` to follow the build).

1. **Build** (run in the background — a cold build takes minutes, an
   incremental one under a minute; wait for `** BUILD SUCCEEDED **`):

   ```bash
   cd "$(git rev-parse --show-toplevel)" && xcodebuild -workspace SongWorkbench.xcworkspace -scheme SongWorkbench -configuration Debug build 2>&1 | tail -5
   ```

2. **Relaunch** (kill the stale instance — whether launched by Xcode or a
   previous re-run — then open the built bundle):

   ```bash
   pkill -f "SongWorkbench.app/Contents/MacOS/SongWorkbench"; APP="$(git rev-parse --show-toplevel)/build/Debug/SongWorkbench.app" && open "$APP" && echo "launched $APP"
   ```

3. **Verify** it stayed up (a crash-on-launch dies within seconds):

   ```bash
   sleep 5; pgrep -fl "SongWorkbench.app/Contents/MacOS/SongWorkbench" || echo "NOT RUNNING - check crash logs: ls -t ~/Library/Logs/DiagnosticReports/SongWorkbench* | head -1"
   ```

## Notes

- Concurrent builds collide: if the build fails with "input file … was
  modified during the build", another build (Xcode, another session) is
  running in the same checkout — wait and retry once.
- `pkill` exiting 1 just means nothing was running; proceed.
- Do not glob for a DerivedData fallback. The bundle is always at
  `build/Debug/SongWorkbench.app` in the checkout, so a fallback never matches,
  and under zsh an unmatched glob aborts the whole command before `ls` runs —
  which leaves `APP` empty and silently "launches" nothing.
- A build REPLACES the bundle a running instance was launched from. Never build
  while a long analysis run is in progress; it can take the app down mid-run.
- The iPad variant is a different target (`SongWorkbenchiPad`, iPad-only);
  run that one in the iOS Simulator via the simulator MCP's build/attach
  tools, not with this recipe.
- Do NOT use `swift run` / the `.build/debug/SongWorkbench` binary for
  app testing — it lacks the bundle and entitlements.
