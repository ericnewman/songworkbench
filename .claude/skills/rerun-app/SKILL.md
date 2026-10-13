---
name: rerun-app
description: Rebuild the macOS SongWorkbench app from the latest code, install it to /Applications (the copy Eric launches), and relaunch it. Use when the user says "re-run the app", "restart the app", "run the latest code", or wants to see a change live in the real app.
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

Eric launches `/Applications/SongWorkbench.app`. A build that stays in `build/` never reaches him
(2026-10-13: `/Applications` ran a 4-day-old build while every fix sat in `build/Release`). So the
default is the optimized build, installed there.

Run these with the shell tool. From a surface with no shell (e.g. Claude Desktop), run the same
commands via desktop-commander's `start_process` (use `read_process_output` to follow the build).

1. **Build, install, relaunch** (run in the background; a cold build takes minutes):

   ```bash
   cd "$(git rev-parse --show-toplevel)" && make install 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|installed|busy|error"
   ```

   `make install` builds Release (`make app-release`), then `scripts/install_app.sh` quits the
   running app, keeps the replaced copy at `/Volumes/SSD/SongWorkbench-previous.app`, installs to
   `/Applications` and relaunches. It refuses while the app is busy (over 20% CPU), because
   quitting would lose an analysis in progress; say so and wait.

2. **Verify** it stayed up and is the installed copy:

   ```bash
   sleep 5; pgrep -fl "MacOS/SongWorkbench" || echo "NOT RUNNING - check crash logs: ls -t ~/Library/Logs/DiagnosticReports/SongWorkbench* | head -1"
   ```

   The path must start with `/Applications/`. Tell Eric which commit is installed (the script
   prints it).

## Debug build (debugging only)

Debug (`-Onone`) is 20x slower at analysis (one 219 s song: 120 s Debug, 6 s Release,
2026-09-19), so use it only when you need a debugger, and put the Release build back with
`make install` afterwards:

```bash
cd "$(git rev-parse --show-toplevel)" && xcodebuild -workspace SongWorkbench.xcworkspace -scheme SongWorkbench -configuration Debug build 2>&1 | tail -5
pkill -f "SongWorkbench.app/Contents/MacOS/SongWorkbench"; open "$(git rev-parse --show-toplevel)/build/Debug/SongWorkbench.app"
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
