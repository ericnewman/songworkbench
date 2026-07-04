# Design: Split ChordPro Tab (backlog #15)

Status: Design / scope only. No code in this pass.
Research: subagent pass over `WorkspaceEditorsView.swift` (3576 lines),
`ChordProPreviewDocument.swift`, `SongAnalysisDocument.swift`, `AppModel.swift`, 2026-07-04.

Eric's framing (backlog.md, verbatim): split the ChordPro tab into (a) a true, spec-exact
read-only ChordPro view, and (b) a new Review/Annotate tab carrying everything currently
overlaid (waveform, beat dots, ball, highlight), with low-confidence chords/lyrics color-coded
and an incremental, per-line/per-chord-event accept-or-correct workflow.

This is the largest, riskiest remaining item: it touches an ~800-line tangled view
(`ChordProPreviewLineView`) that several past sessions have carefully tuned (waveform color
accuracy, beat-dot independence, measure-grid alignment — see project memory), and the spec
implies two things that don't exist in the codebase today. Three decisions need to be made
before writing code, not implicitly while coding:

## 1. Lyric confidence — doesn't exist in the persisted document today

Confirmed via research: `TimedLyricWord`/`TimedLyricSegment` (the persisted, editable types)
carry NO confidence field. Confidence exists only on the upstream ASR-facing types
(`TimedTranscriptionToken.confidence`, `TimedTranscriptionSegment.confidence`) and is discarded
once tokens are grouped into lines — consumed only by `TranscriptionSilenceGate` for
hallucination dropping, never persisted forward.

Two options:
- **(a) Thread it through.** Add `confidence: Float?` to `TimedLyricWord`, populate it from the
  owning token at grouping time, and carry it through every downstream transform that already
  touches words: `VocalHallucinationGate`, `TrailingLyricTailPruner`,
  `TrailingDuplicateLineCollapser`, `RepeatedLyricCorrector`, `IntraLinePauseSplitter`,
  `VocalWordOnsetAligner`, and now also `LyricPhraseGrouper`'s re-cutting (backlog #9,
  just-shipped — its `resegmented`/`segment(from:)` helpers rebuild `TimedLyricWord`s and would
  need to carry the field through too). Real, non-trivial plumbing across ~7 existing
  transforms, but it's the only way to get genuine per-word "the ASR wasn't sure here" signal.
- **(b) Heuristic proxy, no schema change.** Color-code by segment-level signals we already
  compute — e.g. a line the `VocalHallucinationGate`/repair passes flagged as borderline, or
  Whisper's `no_speech_prob`/average logprob if still available at grouping time (H2 in a past
  session, `todo.md` 2026-06-29) — without a persisted per-word field. Cheaper, but weaker/more
  approximate signal, and the "at whatever granularity their confidence data already exists at"
  phrasing in the spec suggests Eric expects (a) if a real per-word signal already existed,
  which it doesn't — this reads as permission to use segment-level granularity if that's what's
  available, not a mandate for word-level accuracy.

**Recommendation: (b) first pass** — color by segment/line-level confidence (average token
confidence at grouping time, persisted once per `TimedLyricSegment`, not per word), deferring
true per-word threading as a later refinement if line-level granularity proves too coarse in
practice. Matches the "at whatever granularity already exists" phrasing and avoids touching 7
existing transforms before knowing whether the coarser signal is even useful. Chords already
have exactly this shape (`EditableChordEvent.confidence`, one value per event) — segment-level
lyric confidence is the closest lyric analogue, so the two column's granularity actually
matches instead of chords being finer-grained than lyrics for no product reason.

## 2. Per-line/per-event acceptance state — doesn't exist today

`lyricReviewState`/`chordReviewState`/`chordProReviewState` are single scalars per song
(`AnalysisReviewState.draft`/`.reviewed`) — accepting one line today has no way to avoid
flipping the WHOLE song's state. The spec's "incremental... one at a time" framing needs
per-line granularity.

**Recommendation**: add `var accepted: Bool = false` directly to `TimedLyricSegment` and
`EditableChordEvent` (simplest shape — a flag alongside the data it describes, not a separate
keyed map to keep in sync). Existing whole-song `lyricReviewState`/`chordReviewState` become a
derived/summary concept: could auto-flip to `.reviewed` once every visible line/event is
`accepted`, or simply stay as today's manual "Mark Reviewed" button for "I've looked at the
WHOLE thing," independent of the new tab's per-line micro-accepts. Recommend keeping them
fully independent (no auto-derivation) for this first pass — simplest, avoids surprising
interactions with the pipeline's existing reviewed-state gating (`SongAnalysisPipeline.swift`
checks these to avoid clobbering a reviewed ChordPro draft on re-analysis).

## 3. The view split itself

`ChordProPreviewLineView` (~800 lines) draws chord-over-lyric text, the bouncing ball, beat
dots, measure barlines, waveform strip, melody fill, and playback highlight all in one `ZStack`
sharing one coordinate system — there is no existing overlay SEAM to cut along. The parsed AST
(`ChordProPreviewDocument`/`Block`/`Line`/`Chord` in `ChordProPreviewDocument.swift`) IS clean
and directly reusable for a true/read-only renderer; the rendering code is not.

**Recommendation**: build a NEW, small `ChordProReadOnlyView` (~100-150 lines, new file) that
renders `ChordProPreviewDocument.blocks` directly — chord-over-lyric column math only, no
waveform/ball/dots/highlight, no `AppModel` dependency beyond the raw ChordPro source string.
This becomes the `chordPro` tab. Leave `ChordProAppPreview`/`ChordProPreviewBlockView`/
`ChordProPreviewLineView` and all their overlay chrome EXACTLY as they are — do not attempt to
carve chrome out of them — and mount that existing view tree, unchanged, under a NEW tab case
(`EditorTab.review` or similar) that also hosts the new color-coding + accept/correct UI as an
ADDITIONAL layer on top (new interaction affordances added to the existing per-line view, not
a rewrite of it). This is much lower-risk than trying to extract chrome from a tangled
800-line view: the existing, carefully-tuned interactive view keeps working exactly as before,
just relocated to a different tab, and the new tab is additive on top of it rather than a
refactor of it.

## Phased plan

**Phase 1** (this item, recommended scope):
- New `chordPro` tab renders `ChordProReadOnlyView` (new, small, AST-only).
- Existing `ChordProAppPreview` moves, unchanged, to a new `review`/`annotate` tab.
- Add `accepted: Bool = false` to `TimedLyricSegment`/`EditableChordEvent` (schema bump).
- Add segment-level lyric confidence (`TimedLyricSegment.confidence: Float?`, populated at
  grouping time from constituent tokens' average confidence) — schema bump, decision #1(b).
- Color-code low-confidence lines/chords in the review tab (reuse the existing dimming/opacity
  convention chords already use for below-threshold exclusion, extended to a 2-3 tier color
  scale rather than binary include/exclude).
- Per-line "Accept" / inline edit action (reuses `TimedLyricsEditor`'s existing inline-TextField
  pattern) and per-chord-event "Accept" (reuses `ChordTimelineEditor`'s pattern) — new small
  affordances added to the existing review-tab view, not a new editor from scratch.

**Phase 2** (explicitly deferred): true per-word confidence threading (decision #1(a)), if
line-level granularity proves too coarse once used on a real song; any auto-derivation between
per-line `accepted` and the whole-song `AnalysisReviewState` scalars, if wanted once used.

## Open questions for Eric

1. Confirm decision #1: segment-level lyric confidence (recommended, cheaper) vs. full
   per-word threading (more accurate, touches ~7 existing transforms) for Phase 1.
2. Confirm decision #3's approach: relocate the EXISTING interactive view unchanged to a new
   tab and layer new accept/correct UI on top of it (recommended, lower-risk), vs. a deeper
   refactor that actually extracts/recomposes the overlay chrome into reusable pieces (larger
   effort, cleaner architecture long-term, higher regression risk to a heavily-tuned view).
3. New tab naming/placement: `EditorTab` order/label for the new tab (e.g. "Review" as a
   4th/5th tab) — no strong constraint found in the research, any reasonable name works.
