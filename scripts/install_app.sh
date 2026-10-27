#!/bin/zsh
# Installs build/Release/SongWorkbench.app to /Applications, the copy Eric launches, so a rebuild
# is never stranded in the checkout (2026-10-13: /Applications ran a 4-day-old build).
# Quits the running app first (refuses while it is busy analyzing), keeps the replaced copy on
# the SSD as SongWorkbench-previous.app (the system disk is nearly full), then relaunches.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
built="$root/build/Release/SongWorkbench.app"
installed="/Applications/SongWorkbench.app"
previous="/Volumes/SSD/SongWorkbench-previous.app"

[[ -d "$built" ]] || { echo "no $built; run make app-release first" >&2; exit 1; }
# The installed app must open Eric's library, which lives in the com.endogenllc.songworkbench.debug
# container (com.local.SongWorkbench until 2026-10-26).
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$built/Contents/Info.plist")"
if [[ "$bundle_id" != "com.endogenllc.songworkbench.debug" ]]; then
  echo "refusing to install $bundle_id: it would open a different (empty) library container" >&2
  exit 1
fi

running="$(pgrep -f 'SongWorkbench.app/Contents/MacOS/SongWorkbench$' || true)"
if [[ -n "$running" ]]; then
  # A busy app may be mid-analysis; quitting it would lose the run.
  cpu="$(ps -o pcpu= -p ${running%%$'\n'*} | tr -d ' ')"
  if (( ${cpu%.*} > 20 )); then
    echo "SongWorkbench is busy (${cpu}% CPU); finish or cancel the analysis, then rerun." >&2
    exit 1
  fi
  for id in com.endogenllc.songworkbench.debug com.local.SongWorkbench; do
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  done
  for _ in {1..20}; do pgrep -f 'SongWorkbench.app/Contents/MacOS/SongWorkbench$' >/dev/null || break; sleep 0.5; done
  pkill -f 'SongWorkbench.app/Contents/MacOS/SongWorkbench$' || true
fi

if [[ -d "$installed" ]]; then
  rm -rf "$previous"
  ditto "$installed" "$previous"
fi
rm -rf "$installed"
ditto "$built" "$installed"
open "$installed"
echo "installed $(git -C "$root" rev-parse --short HEAD) to $installed (previous copy: $previous)"
