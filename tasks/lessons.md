# Lessons

- When the user says to skip already completed items in a batch, exclude them
  from the new output folder and manifest rather than copying prior results
  into the batch deliverable.

- `isolation: "worktree"` on the Agent tool fails outright in this environment
  ("not in a git repository and no WorktreeCreate hooks configured") — the
  sandbox's view of the checkout isn't a git repo from the harness's
  perspective even though the real Mac checkout is. Dispatch parallel
  subagents WITHOUT isolation instead, and make safety come from disjoint
  file-scoping in the prompt, not the isolation parameter.
- Non-isolated parallel subagents share one working tree with whatever else
  is touching it concurrently (the user, another session, a background
  merge). One subagent's real, verified-passing edit (LyricBlendRowBuilder.swift
  fix, task #15) silently vanished — not committed, not even present as an
  uncommitted diff — most likely clobbered by an unrelated concurrent
  process (an iPad-support merge landed mid-run). Always `git status`/`git
  diff --stat` right after subagents report back, before trusting a
  "done" report — a subagent's own build/test verification inside its
  sandbox doesn't guarantee its edits survived on the real checkout.
- Do not carry a prior batch-exclusion rule into a new analysis request when the
  user broadens the scope; explicitly include all requested unique recordings.
- When packaging a workflow as a skill, confirm whether adjacent outputs belong
  inside the primary artifact. For song transcription, embed tone analysis in
  the ChordPro chart instead of treating it only as a separate report.
- When exporting one lyric file per catalog item, exclude continuous live-set
  recordings when the user wants a song list rather than a concert transcript.
- For chord-chart review, do not treat lyric lines as harmonic units. Anchor a
  beat/downbeat grid to timestamped vocals, test center-cancelled accompaniment,
  and represent sub-measure changes explicitly in chord-only sections.
- When center cancellation leaves bass roots ambiguous, separate drums, bass,
  vocals, and accompaniment. Use the drum stem for the grid, bass for roots,
  and the accompaniment stem for chord quality before editing the chart.
- After retrying one analysis stage, verify every generated downstream artifact,
  not only the direct stage output. Lyrics and Harmony changes must rebuild an
  unreviewed generated ChordPro draft while preserving reviewed/imported charts.
- When a requested stem appears merged, distinguish the model's source taxonomy
  from leakage and output-mapping defects before adding mixer tracks. A UI track
  cannot expose a source the installed model does not predict.
- Chord detection must declare and test its audio source. Prefer the separated
  accompaniment stem and beat-level aggregation; never infer source isolation
  merely because stem separation ran earlier in the pipeline.
- A two-axis SwiftUI preview must explicitly own its viewport alignment and
  initial scroll anchor. Do not rely on a lazy stack's intrinsic width to start
  at the leading edge when wide monospaced rows are present.
- Do not report a multi-stem request as handled until the separator model,
  persisted stem taxonomy, playback/export services, and mixer all expose the
  additional real audio outputs. UI work elsewhere does not satisfy it.
- For stem-separation changes, do not accept "finite WAV files were written" as
  validation. Verify reconstruction error, headroom/clipping, source mapping,
  and representative listening/metric evidence before calling the model usable.
- After moving or renaming an Xcode/Tuist workspace, validate both the
  `.xcodeproj` and `.xcworkspace` entry points. Workspace SwiftPM lockfiles may
  be symlinks with absolute paths back to the previous location.

## 2026-06-25 — Don't delete low-confidence transcribed words as "hallucinations"
**Mistake:** Treated "Grass" (conf 0.045, span 0.0–20.0) as a Whisper hallucination and made the
silence gate DROP it. It is the real first word of the song — Whisper only mis-timed it (padding
the first word after the instrumental intro across the whole 20s gap).
**Rule:** Low confidence + an implausibly long span signals a TIMING error, not a fake word.
Re-time/normalize suspicious tokens (de-pad: trim the span) rather than delete them. Only drop a
token that is genuinely isolated in silence AND short AND low-confidence. Verify against the actual
lyric before calling anything a hallucination. Deleting persisted content is destructive — the word
is then gone from storage and only re-analysis from the raw cache can restore it.

## 2026-07-01 — Verify which subsystem owns a symptom before patching
**Mistake risk:** "Short musical intervals shown as separate lines" looked like a lyric-grouper
(TimedLyricSegmentGrouper) bug, and the grouper is a documented minefield. Patching it blind would
have been wrong AND risked regressions.
**Reality:** The lyric lines were clean; the spurious line was a chord-only line emitted by
ChordProDraftBuilder for any sub-4-bar inter-line gap containing a chord. Root cause was a different
file entirely.
**Rule:** When a symptom could live in several subsystems, confirm the owner against live data/UI
first (read the running app's store, screenshot the actual render) before editing a fragile core
algorithm. The sandboxed app's real store is in ~/Library/Containers/com.local.SongWorkbench/…, not
~/Library/Application Support/SongWorkbench (stale copy).

## 2026-07-01 — computer-use input environment is menu-bar-only this session
- Symptom: in-window left_clicks collapse in Y (hit menu bar or wrong control); typed keys land on
  whatever control is focused (Timing slider, Transpose stepper), not the song list. Menu-BAR clicks
  (y≈11) DO work, but menu-ITEM clicks below collapse, and keyboard menu nav didn't select either.
- Consequence: could not switch songs or toggle View on screen; accidentally changed Timing/Transpose.
- Rule: when live UI control is unreliable, DON'T keep poking (it mutates user state). Verify layout
  changes NUMERICALLY against the cached analysis JSON (container Caches/.../Analysis/*.json:
  transcription cache = word onsets; beat cache = beatTimes/bpm/chords), replicating the view's
  formula in Python. Then hand the live eyeball to the user. This proved the fixed-grid downbeat
  alignment (constant 114px column) without a screenshot.
- MeasureGrid downbeat phase is derived IN-VIEW from beatTimes + first-word onsets; no re-analysis.

## 2026-07-01 — Whack-a-mole symptoms = shared-state architecture smell
**Pattern:** Four "different" ball/chart bugs (one intro line tracked, early word entry,
phantom line-8 pause, progressive drift) all traced to ONE cause class: six subsystems
independently re-derive structure×time from a ChordPro STRING round-trip, plus clock math
mixing sample-rate timebases (`sampleTime / fileRate` where sampleTime is bus-rate).
**Rule:** When a third symptom lands in the same feature area, stop patching and audit the
data flow end-to-end with real container data (segments vs vocals-stem RMS vs beat cache)
before touching code. Prefer `playerTime.sampleTime / playerTime.sampleRate` — never divide
a sampleTime by a rate it wasn't expressed in. See tasks/audit-ball-timing.md.

## 2026-07-01 — Baseline-testing in a tree full of someone else's WIP
- `git stash -u` to get a "clean baseline" also stashes the USER's uncommitted in-flight work, so
  the comparison is against HEAD, not against "my changes removed". Failures that appear/disappear
  may belong to the other WIP. To isolate MY change: patch out ONLY my files (git diff > patch;
  checkout my touched files; mv my new files away), test, restore.
- `git stash pop` can fail restoring untracked files when Xcode has recreated one (xcuserstate);
  tracked changes ARE applied and the stash is kept — verify content markers, then `git stash drop`.
  Avoid `stash -u` here while Xcode/the app is running.
- AppModelTests import/restore tests fail in this tree due to pre-existing uncommitted WIP (or real
  Application Support store pollution), independent of chord-pipeline changes — proven by removing
  my changes and re-running.

## 2026-07-05 — Regression tests must mirror the field data's FULL shape
**Mistake:** The first non-adjacent duplicate-merge fix "passed" its regression test but
failed on the real song: the test's clusters held ONE mode each, while the real cluster held
the same line from TWO modes — the flat text concatenation read as the line doubled and
never matched. Eric had to re-analyze and re-report before the miss surfaced.
**Rule:** When building a regression test from observed field data, reproduce the complete
shape (every mode/candidate/row involved), not a minimal sketch of the mechanism. Before
declaring a data-pipeline fix done, replay it against the actual persisted values that
exhibited the bug — the unit fixture must be copied from that data, not invented.

## 2026-07-05 — `xcodebuild` from the CLI can write to a DIFFERENT DerivedData folder than Xcode.app
**Mistake:** After editing `WorkspaceEditorsView.swift` and running `xcodebuild build -workspace
... -scheme SongWorkbench -destination 'platform=macOS'` (no `-derivedDataPath`) via
desktop-commander, the command reported success but the RUNNING app showed zero visual change
across two separate edit+rebuild+relaunch cycles. `ps aux` showed the app launching from
`DerivedData/SongWorkbench-favoqfzepggqffaexaekdhrbjjwc/...`, but `stat` on that exact binary
path showed the SAME mtime from hours earlier — the CLI build had silently written to a
DIFFERENT hash-named DerivedData folder (`SongWorkbench-gxvqzdbqjmsizdbbkbbrwjujqgwr`, created
fresh) instead of updating the one Xcode.app/the launched app actually uses.
**Rule:** After any `xcodebuild build`, verify the fix landed by `stat`-ing the mtime of the
EXACT `.app/Contents/MacOS/<name>` binary the running process's `ps aux` path points to — don't
trust "BUILD SUCCEEDED" alone. If the mtime didn't move, pass `-derivedDataPath` explicitly
pinned to that same running app's DerivedData folder (find it via `find
~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "SongWorkbench*"` sorted by mtime) so
CLI builds and the GUI/launched app share one build product going forward.

## 2026-07-05 — A width/layout fix can reveal a SECOND, previously-invisible bug in the same code path
**Context:** Fixing `instrumentalTimeWidth` (chord-only ChordPro rows rendered at ~1/3 a sung
line's width — Eric: "compressed to roughly 1/3 the expected width") first appeared to do
nothing at all: `lineDuration` for those rows was silently 0 because `lineStrip`'s duration was
gated behind `instrumentalLane` (guitar/piano envelope) being loaded, an unrelated concern
bundled into the same guard. Fixing THAT revealed a third issue: chord glyphs still positioned
by column-fraction-of-bar-grid-TEXT no longer meant anything once the row's pixel width was
keyed to real duration, so labels clustered wrong: needed `rowChordTimes` + the row's real start
time threaded through as a new parameter. A fourth: the flat "| . . |" bar-grid text itself
can't stretch to the new width, so it had to be hidden in the rhythmic/time-scaled case.
**Rule:** When a single computed property's DOCUMENTED behavior doesn't show up after a fix,
suspect an upstream value silently defaulting to zero/empty behind an unrelated gate before
re-checking the fix's own formula. And once one property in a tightly-coupled layout
(width/position/text) is changed to a new coordinate space, audit every SIBLING property that
assumed the OLD coordinate space still holds.

## 2026-07-05 — Don't trust a doc comment's justification for a shortcut; verify against the code
**Mistake:** `ChordProDraftBuilder.measureGrid` hard-coded `beatsPerBar = 4` with a doc comment
implying the builder had no lyric-onset signal independent of the lyrics themselves — but
`lyrics: [TimedLyricSegment]` was already a parameter in that very function, exactly like the
live preview (`WorkspaceEditorsView`) already used to estimate 3/4/5/6 via
`DownbeatEstimator.estimateBeatsPerBar`. The comment's claim was simply false.
**Rule:** A comment explaining WHY a shortcut is "necessary" is a claim, not a fact — check it
against the actual function scope before accepting the shortcut.

## 2026-07-05 — `ChordProDraftBuilder` test fixtures need real `words:` and can't hand-derive bar-pipe strings
**Mistake:** Built a `ChordProDraftBuilderTests` fixture with several short `TimedLyricSegment`
lines (default `words: []`) before an instrumental outro. `TrailingLyricTailPruner
.tailLooksDegenerate` treats `words.count <= 2` as an ASR-hallucination blip, so it silently
pruned the trailing lines from `bodyLyrics`, shifting `lastLyricEnd` and the outro's start time
out from under the test — the assertion failed for a reason unrelated to the fix under test.
Separately, hand-computing the expected `"| [C] | [F] | ... |"` bar-pipe string from
`beatsPerBar` alone was unreliable: `instrumentalRows`' row-splitting math
(`typicalLyricBars`/`LyricSectionDeriver.bars`) uses its OWN hard-coded 4-beat-per-bar
conversion independent of the real `MeasureGrid.beatsPerBar`, and `DownbeatEstimator.barPhase`
re-fits bar boundaries to the given chord onsets — so even a "clearly wrong" grid can still
render a clean-looking bar-pipe string by accident (confirmed empirically: a 2-onset case
rendered identically under both beatsPerBar 4 and 5).
**Rule:** Give `ChordProDraftBuilder` test fixtures ≥3 dummy `words` per line whenever the test
needs several short, closely-timed lyric lines followed by a real instrumental gap. Prefer a
DIFFERENTIAL assertion (same chords/timing; vary only the signal under test — e.g. lyric-line
spacing — and assert the output differs) over a hand-derived exact-match string, and always
empirically confirm a new regression test actually fails when the fix is reverted before
trusting it.

## 2026-07-05 — A width fix can put a LATENT bug on-axis for the first time; re-audit adjacent scans, not just the new formula
**Mistake (near-miss, caught live):** The evening's `instrumentalTimeWidth` fix (switching
chord-only rows to `lineDuration * pixelsPerSecond`) was itself correct, but it made
`chordOnlyLineWindow`'s multi-row slicing (`rowCount`/`position`) load-bearing for the first
time — under the old character-count sizing, a wrong `rowCount` didn't visibly matter because
row width didn't derive from the window slice at all. `rowCount` was ALREADY silently broken:
it scanned `items` for consecutive chord-only rows via raw adjacent-index checks
(`isChordOnlyRow(index - 1)`), but `ChordProDraftBuilder` interleaves an `{x_chord_times: ...}`
directive immediately before every chord-only row, so real rows are 2 `items` slots apart, not
1 — the scan hit the directive and stopped, collapsing every multi-row run to `rowCount == 1`
(each row claiming the WHOLE gap). Reported live as "Intro and outro bars are now twice as
wide" right after the width fix shipped and the app was rebuilt/relaunched for the first time.
**Rule:** When a fix changes what a value is DERIVED FROM (character count → real duration,
proportional → absolute, etc.), audit every UPSTREAM computation that value now depends on for
the first time — a latent bug in one of them can look like a brand-new regression in the fix
itself. Also: any "scan adjacent items for a run of X" loop must skip over items that aren't X
and aren't a real boundary (directives, comments, blank lines) — a raw `index ± 1` check is
almost always wrong once directives can be interleaved between the things being counted.

## 2026-07-06 — `.build/checkouts` can be silently corrupted by a concurrent process sharing the checkout
**Symptom:** `swift build` failed with "the package manifest ... cannot be accessed" for
FluidAudio and onnxruntime-swift-package-manager, even though nothing in the current edit
touched dependencies. `ls .build/checkouts` showed duplicate ` 2`-suffixed dirs (`FluidAudio 2`,
`onnxruntime-swift-package-manager 2`) alongside a stale `workspace-state.json` pointing at
paths that no longer matched — almost certainly a concurrent `tuist generate`/`swift package
resolve` (the iPad-support work landing in the same checkout at the same time) racing on the
same SwiftPM cache directory.
**Fix:** confirm no build process is actually running (`ps aux | grep -iE
"xcodebuild|swift build|swift package|tuist"`) before touching `.build/`, then remove the
duplicate/stale dirs (`.build/checkouts/<name> 2`, `.build/workspace-state.json`,
`.build/repositories`) and re-run `swift package resolve` — cheap and safe since none of it is
tracked in git.
**Rule:** In a shared checkout where multiple sessions/subagents may run Tuist/SwiftPM
concurrently, a "manifest cannot be accessed" or similarly nonsensical SwiftPM error is more
likely stale/corrupted `.build` state from a concurrent writer than a real problem with your own
change — check `.build/checkouts` for duplicate/` 2` dirs before assuming your edit broke

## 2026-07-06 — iPad Simulator UI is cramped: verify test-data state on screen, don't infer it
**Symptom:** Assumed 4 songs were imported into the iPad app's isolated sandbox based on an
earlier screenshot; after a rebuild+relaunch (needed to pick up the landscape-orientation fix),
only 3 remained and a "Failed — Install the X model before running" message referenced models
that hadn't actually finished installing yet. Separately, a `+` (import) button sits only ~15pt
from a song row's trash icon in the cramped iPad toolbar; a click meant for `+` landed on trash
and silently deleted "Flip Flops and Barbeque" mid-session.
**Rule:** On the iPad simulator (or any narrow/cramped layout), re-verify the actual on-screen
song list / model-install state with a fresh screenshot after ANY rebuild+relaunch or long wait
— don't carry forward "I saw 4 songs earlier" as still true. When two small tap targets sit
within ~20pt of each other (import `+` vs. a list row's trash icon), zoom in first to get exact
glyph coordinates rather than estimating from a full screenshot, and prefer re-verifying
immediately after the click (a stray deletion is otherwise invisible until several steps later).

## 2026-07-06 — Whisper (Accuracy transcription) can't install on iPad: known, not a regression
**Symptom:** Installing the Whisper Large V3 Turbo model on the iPad simulator failed with
"Model archive extraction isn't supported on this platform yet."
**Diagnosis:** `ModelPackageManager.swift`'s `DittoModelArchiveExtractor` shells out to
`/usr/bin/ditto` via `Process`/`NSTask`, which doesn't exist on iOS; the `#else` branch already
throws `ModelPackageError.extractionUnsupportedOnPlatform`, and the surrounding comment already
says this was "tracked in the iPad port plan." Parakeet (Fast/Balanced) ships as a `.mlpackage`
that doesn't need zip extraction, so it installs and works fine.
**Rule:** Before treating a platform-specific install/feature failure as a new bug to fix,
`Grep` the error string in source — if the `#else`/platform-gated branch already throws a
named, documented error, it's a known, scoped-out gap (fixing it properly means implementing an
Apple-Archive-based in-process unzip, real work, not a quick patch). Document it as a finding,
keep testing with what DOES work on that platform (here: Parakeet-only), and don't burn the
current task's time budget implementing the missing platform feature unless asked.
something.
