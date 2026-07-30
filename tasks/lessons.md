# Lessons

- When two user-facing chart surfaces are expected to have identical typography,
  spacing, highlighting, and playback animation, route both through the same
  renderer with configuration-driven toolbar differences. Parallel renderers
  will drift even when their initial constants match.

- Treat advanced analysis as a native Swift/Xcode feature first. Production
  inference should run in-process through Core ML or ONNX Runtime Swift
  adapters; subprocess/Python integrations are optional macOS extensions, not
  the main architecture and never the iPad path.

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

## 2026-07-28 — Verify generated assets before describing advanced stems as delivered

**Correction:** The refinement architecture and capability profiles existed, but
the production model catalog and default refiner factory still had no concrete
lead/backing vocal, drum-piece, or lead/rhythm model artifacts. The app therefore
truthfully continued to generate only six stems.
**Rule:** Do not describe advanced-stem infrastructure as delivered stem output.
Verify the production capability, factory registration, model catalog, installed
artifacts, persisted manifest, and visible mixer channels end to end.

## 2026-07-28 — Diagnose lyric disappearance from raw ASR through rendering

**Correction:** Most of the first lyric line was missing in the latest analysis.
The raw accuracy transcription cache had already collapsed the opening to one
word, while a bounded transcription of the actual opening vocal region recovered
the phrase. A separate near-onset transform could also drop leading words from a
straddling segment.
**Rule:** For missing lyrics, compare raw transcription, corrected lyric timeline,
persisted project, and ChordPro output before changing UI code. When full-song ASR
collapses after a long intro, retry a bounded vocal-onset region and merge only a
demonstrably richer opening.

## 2026-07-28 — Vocal phrase onsets do not imply a beat-grid error

**Correction:** Review flags appeared on most lines because the diagnostic treated
any lyric onset more than 0.3 beat from the nearest detected beat as a likely
mis-split. Valid pickups and syncopated phrases naturally span the full interval
between beats, so the rule produced false positives by construction.
**Rule:** Do not flag vocal timing from nearest-beat distance alone. Require an
expected metrical phase or repeated-phrase template; otherwise use evidence such
as duration outliers and corroborated section-shape differences.

## 2026-07-28 — Do not resize native progress controls with transforms

**Correction:** Xcode reported repeated AppKit progress-view geometry failures.
The compact sidebar spinner used `scaleEffect(0.6)` inside a fixed frame, which
made SwiftUI derive a fractional native size whose rounded minimum exceeded its
maximum.
**Rule:** Size bridged AppKit/UIKit controls with supported `controlSize` values
and ordinary layout constraints. Do not use transforms to force native controls
below their intrinsic geometry; reproduce runtime layout diagnostics under
Xcode and verify the console after relaunch.

## 2026-07-29 — `Benchmarks/*.md` reproduce recipes reference tooling that no longer exists

**Surprise:** Planning a chord-accuracy harness, the obvious starting points from the
benchmark docs were both dead ends. `Benchmarks/CHORD_ANALYSIS.md:10-11` names
`scripts/analyze_chord_timeline.py` as the Python baseline — **that file does not exist**;
`scripts/` contains only `verify_repo.sh`, and there is no deletion in git history.
`memory.md:194-196` likewise advises replaying cached frame JSON "in Python" with no such
script in the repo. Separately, `Benchmarks/Tools/native_analysis_benchmark.swift` calls
`BeatTracker`, `AudioAnalysisConfiguration`, `ChordAnalysisPipeline`, and `ChordObservation`
— all internal to `Sources/SongWorkbench/` and none defined in that file — so the bare
`xcrun swiftc <tool>.swift` recipe the sibling benchmarks document **cannot compile it**.
**Rule:** Treat a `Benchmarks/*.md` "reproducible with…" line as a historical claim, not a
working recipe. Confirm the referenced file exists AND that its documented invocation can
actually build before designing new work around it. When a benchmark tool calls app-internal
types, the compile line in the doc is necessarily incomplete.

## 2026-07-29 — Zero `public` in Sources forces offline tooling into the test target

**Surprise:** `grep -rn public Sources/SongWorkbench/` returns **no declarations** — the word
appears only in comments. Everything is `internal` to the app's *executableTarget*. That means
a standalone `Benchmarks/Tools` binary or a new SPM `.executableTarget` cannot reach
`AudioFileAnalysisService`, `ChordTimelineDecoder`, or `BassLineAnalyzer` at all without first
restructuring `Package.swift` to extract a library target.
**Rule:** For offline analysis/eval tooling here, default to a file in
`Tests/SongWorkbenchTests/` gated by an env var (precedent:
`ChordDecoderOfflineValidationTests.swift`, `SW_OFFLINE_VALIDATION=1`). It gets `@testable`
access for free and `Project.swift:132` globs the directory, so SwiftPM and Tuist both pick it
up with no build-system work. Reserve the library-extraction refactor for when a shipping
reason demands it, not for a harness.

## 2026-07-29 — `EditableChordEvent.chord` is a display STRING, not a structured `Chord`

**Surprise:** Writing a chord-accuracy scorer, the natural assumption was that the decoded
event stream carries `Chord { root: PitchClass, quality: ChordQuality }`. It does not.
`Chord`/`ChordQuality` exist only upstream in classification; the pipeline stringifies via
`Chord.displayName` and everything downstream of `ChordTimelineDecoder` — events, ChordPro,
persistence, any scorer — handles labels like `C`, `Cm`, `Cmaj7`, `Cm7`, `C7`.
**Consequence:** the 5-quality vocabulary ceiling is enforced *upstream at classification*, so
by the time chords reach any consumer the information is already gone — a scorer cannot
distinguish "the model considered Csus4 and rejected it" from "Csus4 was never representable."
Any comparison against external ground truth must parse strings and normalize enharmonics
(`Db` vs `C#`) and suffix conventions itself.
**Rule:** Before writing anything that compares chords, check whether you are holding a
structured `Chord` or a rendered label. Do not assume the structured type survives the decoder.

## 2026-07-29 — There is NO verified ground truth anywhere; the persisted charts are decoder output

**Finding:** Setting up chord-accuracy measurement, the obvious ground truth was "the user's
reviewed ChordPro charts." There are none. All five persisted song documents in the app
container (`~/Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/
SongWorkbench/songs/*.json`) carry `chordProReviewState = draft` AND `chordReviewState =
draft` — every chart on disk is unedited decoder output. `tasks/backlog.md:85` says the same
of the catalog: "original songs with no ground truth."
**Why this is a trap:** scoring detection against a `draft` chart is perfectly circular — it
compares the decoder to itself and will report near-100% accuracy regardless of how good the
detection actually is. The number looks like validation and means nothing. A *reviewed* chart
would fix the labels but still not the timings (those stay decoder-derived), so even then it
is a label oracle only.
**Second-order trap:** in agreement-only mode the "vocabulary ceiling" is also unmeasurable
and silently degenerate. `ChordQuality` has exactly 5 cases, so the detector CANNOT emit
anything outside them — a ceiling computed from detections is 0.0 by construction. Reporting
that 0.0 would read as "the vocabulary is not a limitation," the exact opposite of the truth.
The ceiling is only measurable against external labels that contain sus/dim/aug/6/9 chords.
**Rule:** Before any accuracy work here, establish where the labels come from and whether they
are independent of the thing being measured. With no independent labels, measure SENSITIVITY
(do the arms diverge?) not CORRECTNESS (which arm is right?) — and label the output as such,
loudly. Divergence bounds the *possible* effect of a change; it never identifies the winner.
Getting a real answer requires a human-verified chart on at least a few songs — that is a
prerequisite for Phase 1's A/B, not an optional extra.

## 2026-07-29 — `swift test` buffers all stdout to exit, and lingers holding the SwiftPM lock

**Symptom:** A 25-song analysis batch printed nothing for 12 minutes, then emitted every line at
once on exit. Mid-run there was no way to see progress, distinguish "working" from "hung", or
salvage partial results — and a subsequent `swift build` appeared to hang because the finished
`swift-test` process sat for several more minutes (audio-engine teardown, not test code) still
holding the `.build` lock.
**Rule:** For any long-running harness under `swift test`, write results incrementally to a file
(flush per item) instead of relying on stdout — otherwise a crash at song 24 loses all 24
results and there is no progress signal. Budget for the process lingering after its report
prints; do not interpret a held `.build` lock as a stuck build. Don't chain a watcher that
triggers on a symbol appearing in a file either: it fires while the writer is mid-edit, and the
resulting build errors look like real failures (`type 'Self' has no member …`) when the file is
simply incomplete. Wait on a clean compile, not on a grep.

## 2026-07-29 — "It's ONNX" says nothing about whether a model fits; probe the tensor contract

**Mistake avoided by one cheap test:** UVR-MDX-NET Karaoke 2 was planned in as a drop-in refiner
because it is "already ONNX, so it fits the existing `StemChunkPredicting` path with no new
runtime". It does not. Loading it and handing it a rank-3 waveform returns
`Invalid rank for input: Got: 3 Expected: 4`; it accepts `[1,4,2048,256]` and returns
`[1,4,2048,256]` — **spectrogram in, spectrogram out**. Every engine in this codebase is
waveform-out, so there is no ISTFT anywhere in `Sources/`, and the model is unusable without one.
**DrumSep is a false precedent for this.** It *looks* like a spectrogram model because
`HybridDemucsFrequencyFeatures` exists, but it takes a waveform AND a packed spectrogram and
returns a **waveform** — the STFT helper only ever runs forward.
**Rule:** before planning any model integration, load the artifact and probe its actual input
rank/dims. ORT names the expected rank and the offending indices in its error text, so a ~30-line
XCTest with no Python dependency settles it in seconds (`KaraokeModelProbeTests.swift`). Runtime
format (ONNX / Core ML) tells you nothing about the tensor contract. Do this at the point where
the artifact is first acquired, not after writing the integration.

**Second-order rule:** when the missing piece is a signal-processing inverse (ISTFT, overlap-add,
window normalisation), treat it as a stop-and-ask rather than just work. Its failure mode —
artifacts — is indistinguishable from poor model quality, so it silently invalidates the very
listening test meant to judge the model. This repo already carries one unvalidated instance
("STFT packing still needs PyTorch golden parity" for DrumSep); stacking a second makes both
unfalsifiable.

## 2026-07-29 — High divergence turned out to mean instability, NOT headroom

**The full arc, worth keeping:** the stem-source sensitivity run showed chord output changing on
20 % of song duration (15.1 % at ROOT level) between the guitar and accompaniment stems. That
looked like a strong signal that stem quality drives chord quality — the premise of the whole
per-instrument-model plan. Scoring the same arms against independent charts settled it:
guitar 77.1 % root, accompaniment 77.1 % root. Identical. Accompaniment marginally BETTER on
full quality. The two arms disagree constantly and are equally right.
**Rule:** a large divergence between two inputs is equally consistent with "the better input
wins" and "the model is unstable and its output is partly arbitrary." Those two have opposite
implications for whether to invest. Never let sensitivity stand in for accuracy — it took one
afternoon of ground truth to reverse a conclusion that would otherwise have justified weeks of
model-integration work.

## 2026-07-29 — Guard against provenance laundering when sourcing ground truth

**Near-miss:** told that exported ChordPro charts were human-validated, three of the candidate
files turned out not to be. `Desktop/Settle Down.cho` was a SongWorkbench export carrying
`{comment: Generated analysis draft - review required}` and `x_chord_times` — scoring against it
would have compared the decoder to itself and reported inflated accuracy. And of 37 charts in
the catalog, only THREE say `{subtitle: Reviewed performance chart}`; most say
`{subtitle: Automated best-effort transcription from the supplied recording}` — another tool's
output, independent of this decoder (so not circular) but of unknown accuracy.
**Rule:** before using any file as ground truth, read its own provenance metadata and check for
markers of machine generation (generated-draft comments, timing directives only this app emits).
"Validated" is a claim about a file's history that the file itself often records — check it, and
tier the results by trust rather than pooling them. Report which tier each number rests on.

## 2026-07-29 — A recall-only sequence metric rewards over-segmentation

**Trap:** LCS(detected, truth) / truth.count has no precision term, so emitting more chords can
only help. `Flip Flops` detected 123 chord events against a 34-chord chart (3.6×) and scored a
meaningless 100 % root accuracy, while the one song with balanced sequence lengths AND a
Reviewed chart scored 37.3 %. The ranking across songs was close to an artifact of how much each
arm over-detected.
**Rule:** for sequence-accuracy scoring, report an F-measure (or at minimum print both sequence
lengths beside every score) so over-segmentation is visible. A same-vs-same comparison can still
be valid when both sides have near-identical lengths — that is why guitar-vs-accompaniment
survived here — but absolute levels from a recall-only metric are not quotable.

## 2026-07-29 — Sensitivity is not accuracy; say which one you measured

**Finding:** The stem-source comparison showed chord output changing on 20 % of song duration
between the guitar and accompaniment stems (15.1 % at root level) — even though `accompaniment`
is literally `guitar + piano + other` summed, i.e. a strict superset of the guitar arm's content.
It is tempting to read a big divergence as "big headroom, go build the better model."
**Why that's wrong:** divergence measures how much the output MOVES, not how much it IMPROVES.
A pipeline that is highly sensitive to its input is exactly the pipeline most at risk of being
made *worse* by a different input — which is the documented failure mode where Demucs
preprocessing degraded a chord model. Without labels, a large divergence and a genuine
opportunity are indistinguishable.
**Rule:** State in the output which quantity was measured and label it loudly (this harness
prints an `AGREEMENT-ONLY — NO GROUND TRUTH` banner). Use divergence to BOUND a possible effect
and to decide whether measuring properly is worth it — never to pick a winner. And when the
divergence is high, that raises the value of ground truth rather than substituting for it.

## 2026-07-29 — Swift type-checker times out on short mixed-Float arithmetic in a closure

**Surprise:** `guitar[i] * 0.5 + bass[i] * 0.4 + drums[i] * 0.3` inside a `map` closure failed
with "unable to type-check this expression in reasonable time" — a three-term expression.
Literal-vs-`Float` overload resolution across an inferred closure return type is enough to
blow the budget.
**Rule:** In audio-sample code, write mixdowns as an explicit loop with annotated bindings
(`let x: Float = …`) rather than a chained expression in a closure. Cheaper than fighting
inference, and it reads better at 3am anyway.

## 2026-07-28 — Let degenerate timing override lexical interjection protection

**Correction:** Doc Holiday retained a zero-duration `Ain't no` line immediately
before `runner from the debt you owe.` because the lyric grouper protects lines
ending in `no` as possible standalone interjections.
**Rule:** Lexical safeguards are secondary to impossible timing. A multiword
line with effectively zero duration followed within a small fraction of a
second is a broken ASR fragment and should merge forward, while normally timed
short interjections remain protected.

## 2026-07-30 — Simulate a candidate rule against real data BEFORE editing shipping code

**Rule:** when changing a decision rule in the pipeline, first re-implement it inside the
diagnostic with the selection logic factored out, prove the re-implementation reproduces the
CURRENT shipping output exactly (a `faithful=true` flag), then score the competing rules against
the same frames. Only then touch `Sources/`.

**Why:** this caught a wrong fix before it shipped. The obvious repair for "`m7` is never
emitted" is to append `.minor7` to `BassInformedChordRefiner`'s candidate list. Simulation showed
that variant makes things WORSE — the scan is first-match, so `.minor` still returns before any
seventh is reached, and plain argmax pushed `maj7` from 11.8 % UP to 13.6-16.3 %. The rule that
actually worked (size-normalised threshold: triad 2-of-3, seventh 3-of-4) was only identifiable
by comparing three rules side by side on the same 2,000-3,200 cached frames per song. Cost:
one extra diagnostic run. Without the `faithful=` check the projections would have been unfalsifiable.

**How to apply:** the diagnostic is `Tests/SongWorkbenchTests/ChordQualityStageAttributionTests.swift`
(`simulate(observations:bassNotes:select:)` + one `select` function per rule). Same shape works
for any per-frame decision rule.

## 2026-07-30 — A defect measured in the harness may live in a stage the harness does not run

**Rule:** before attributing a number produced by `StemSourceChordAccuracyTests` to a stage,
check whether the harness actually runs that stage. It deliberately skips
`ChorusChordConsensus` (`StemSourceChordAccuracyTests.swift:574`) which production runs
(`AnalysisStage.swift:847`).

**Why:** the "maj7 emitted 6.8 %" figure came from the harness (no consensus), while the
"`Gmaj7` x20 in the persisted document" observation came from production (with consensus). They
are different pipelines, and reasoning that treats them as one leads to blaming the wrong stage.
Consensus turned out to be innocent (1-2 label rewrites per song), but that had to be measured,
not assumed.

**How to apply:** `ChordQualityStageAttributionTests` covers the full production order including
consensus (stage S9). Use it, not the accuracy harness, for attribution questions.

## 2026-07-30 — A "wrong" rule may be a deliberate feature with a test behind it

**Rule:** when a measurement says a rule is wrong, grep for tests covering that rule before
changing it. If tests encode the behaviour as intended, the change is a product decision, not a
bug fix — surface it rather than deleting the test.

**Why:** the flat "shares >= 2 tones" bar in `refineObservations` is simultaneously the source of
a 15-88x `maj7` inflation AND the deliberate upper-structure-seventh feature that
`testBassRerootRecoversUpperStructureSeventh` exists to protect (with an explanatory comment at
`ChordClassification.swift:263-265`). You cannot fix one without deleting the other. Combined
with a flat F1 result at N=3, that is not a call to make autonomously.

## 2026-07-30 — Commit far more often (Eric, explicit)

**Rule:** check in to git frequently — after each self-contained unit of work lands and verifies,
not at the end of a session. Do not let the working tree accumulate dozens of uncommitted files
across sessions.

**Why:** this session opened on a tree with **72 changed files** spanning several prior sessions
(stem refinement, ChordPro tabs, theme work, the drum-piece engine, an entire untracked eval
harness). Consequences that actually cost time here: no baseline to diff a change against, so
"did I break this or was it already broken?" needed a manual backup copy; a `swift format`
run reported pre-existing violations in files nobody had touched this session; and the repo had
**zero tags**, so there was no known-good point to return to. Committing a verified unit takes
seconds; reconstructing which of 72 files belong to which idea takes an hour.

**How to apply:**
- Commit when a unit is verified — tests green, lint clean on the touched files — even if the
  larger feature is unfinished. "Add stage-attribution diagnostic (additive, env-gated)" is a
  commit; it does not need the fix that follows it.
- Diagnostics, harnesses and task/lesson docs are independently committable the moment they run.
  They have no shipping risk, so nothing is gained by holding them.
- Before starting new work, commit or stash what is already dirty, so the next diff is readable.
- Tag known-good points so there is always somewhere to return to.
