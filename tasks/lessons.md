# Lessons

- When the user says to skip already completed items in a batch, exclude them
  from the new output folder and manifest rather than copying prior results
  into the batch deliverable.
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
