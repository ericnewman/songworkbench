# Design: ChordPro Review Consolidation (backlog #15 Phase 2)

Status: Design confirmed with Eric (4 decisions below, via AskUserQuestion, 2026-07-04). Building next.

## Why

Phase 1 (commit `4612da2`, this morning) split the old single interactive `ChordPro` tab into:
a new spec-exact read-only `ChordPro` tab (`ChordProReadOnlyView`, unchanged/kept per decision #4
below) plus a `Review` tab holding the ORIGINAL interactive chart (`ChordProTabEditor` /
`ChordProAppPreview`, untouched) stacked above a new list-based `ChordProReviewAnnotationsPanel`
(per-line/per-chord accept + correct + optional bass row).

Eric's follow-up: the Review tab's bottom list panel is redundant chrome — every capability it
offers (bass row, confidence tint, accept, correct) should live directly IN the interactive chart
instead of a separate scrolling list below it. Two brand new capabilities also requested: drag a
chord to a new position, and edit a lyric line's words, with both surviving re-analysis.

Root cause of the "chords clustered near the left edge, unacceptable" bug report earlier today:
NOT a positioning regression. Eric was looking at the NEW spec-exact `ChordPro` tab (plain
monospace character-column render, `ChordRowStringBuilder`) under the OLD tab name, and comparing
it against memory of the finely-tuned interactive chart, which had simply moved to the `Review`
tab, unchanged. No bug in `metricX`/`rhythmicX`/`monospaceChordX`/`rowDownbeatTime`. Confirmed
against real data for the song in question (35 lyric segments in the stored JSON = 35 non-blank
lyric lines in `chordProSource`, draft-state so it's rebuilt fresh every load — ordinals match).

## Confirmed decisions

1. **Chord drag semantics: free timestamp, no snapping.** A dragged chord goes exactly where it's
   dropped — nearest-beat/nearest-word snapping was explicitly declined.
2. **Confidence tint + Accept carry into the chart** (not dropped). Low/medium confidence chords
   and lyric lines get a subtle tint directly in the interactive chart; Accept becomes a small
   in-chart control, not a separate list row.
3. **Bass Notes tab is removed.** Bass row becomes a toggleable row inline in the consolidated
   chart (reusing `BassNoteRowFormatter`), positioned on the chart's own time axis rather than the
   old panel's fixed-indent text row. `EditorTab.bassNotes` and its `ChordProTabConfig.bassNote`
   usage go away.
4. **The spec-exact read-only `ChordPro` tab stays separate**, unchanged from this morning. Final
   tab set: `Lyrics`, `Chords`, `ChordPro` (spec-exact, read-only), `Review` (consolidated
   interactive chart — bass/tint/accept/correct/drag all in one view). No 5th tab.

## Scope

### Schema additions (purely additive, decode-if-present defaults, no migration)

- `EditableChordEvent.manualTime: TimeInterval? = nil` — a user-dragged position. `nil` means "use
  the detected `time`." Rendering AND playback/highlight logic read through a new
  `effectiveTime` (`manualTime ?? time`), so a drag doesn't require touching every call site that
  currently reads `.time` directly for detection-adjacent logic (only display/highlight needs the
  override; anything reconciling against fresh detection output should keep comparing raw `time`).
- `TimedLyricSegment.overrideText: String? = nil` — mirrors the existing, working
  `LyricBlendRow.overrideText` pattern (see project memory: lyric-blend-override-and-
  reconciliation). Editing a line's words writes here, never to `text` directly, so the original
  ASR output is never destroyed and reconciliation has something stable to diff against.
- `TimedLyricSegment.accepted` / `EditableChordEvent.accepted` already exist (added in Phase 1) —
  reused as-is.

### Persistence across re-analysis

New `reconciled(newSegments:against:)` / `reconciled(newChords:against:)` free functions (or
extend `AppModel.applyAnalysis`), modeled directly on `LyricBlendRowBuilder.reconciled`: for each
freshly-produced segment/chord, find the OLD entry with the greatest time-window overlap (fallback
nearest-start), and if found, carry forward `overrideText`/`manualTime`/`accepted` onto the new
entry. Matching always uses the RAW detected `time`/segment window, never the manually-overridden
value, so a manual edit doesn't poison future reconciliation.

### View changes

- Delete `EditorTab.bassNotes` case + its switch arm; delete/retire `ChordProTabConfig.bassNode`
  usage (keep `AppModel.bassNoteChordProSource`/`BassNoteNaming` — still used by the inline bass
  row's data source).
- Delete `ChordProReviewAnnotationsPanel` and the `Divider` + bounded `ScrollView` wrapper in
  `ChordProReviewTab` — the Review tab becomes just the chart, full height.
- Extend `ChordProPreviewLineView` (additive overlays on the existing coordinate system, NOT a
  rewrite of `metricX`/`rhythmicX`/`monospaceChordX`):
  - Optional bass row above the chord row, reusing `BassNoteRowFormatter.label`, positioned via
    the SAME per-word x-mapping the chord row already uses for that line (rhythmic/metric/
    monospace, whichever the line is using) rather than a fixed left-padded string.
  - Chord glyphs tinted per `ReviewConfidenceTier(chordEvent.confidence)`; lyric words tinted per
    `ReviewConfidenceTier(segment.confidence)`.
  - Small Accept affordance per line/chord (checkmark, toggles `accepted`).
  - Tap-to-edit on a lyric line opens an inline `TextField` seeded with `overrideText ?? text`,
    committing to `overrideText`.
  - `DragGesture` on each chord glyph; on end, invert the line's current x-mapping to a timestamp
    and write it to `manualTime`.
- `AppStorage("reviewShowBassNotes")` toggle relocates from the panel into the chart's toolbar.

### Out of scope / explicitly not doing

- No per-word confidence or per-word text editing (line-granularity only, matching what the old
  panel already did).
- No snapping logic for chord drag (decision #1).
- No changes to the spec-exact `ChordPro` tab (decision #4).

## Verification plan

Same workflow as Phase 1: implement in a worktree, `tuist generate` + real `xcodebuild test` on
the Mac via Desktop Commander, `swift format lint --strict` clean, then merge to `main` from the
Mac's main checkout. New unit tests: reconciliation carry-forward (segments + chords, matching +
no-match cases), `effectiveTime` resolution, drag→timestamp inversion math per positioning mode.
