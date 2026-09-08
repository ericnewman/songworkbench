# Spec — Fixed-period chart rows (DRAFT for Eric's review, 2026-09-08)

## Measured problem
`LineLengthConsistencyDiagnosticTests` (SW_LINE_LENGTH_DIAG=1) over the 14 library songs:
- The pipeline recut lyric lines on the RAW `SongBeatsPerLine` fit while the preview framed rows at
  the occupancy-doubled period: 3/14 songs were cut to 4 beats and framed at 8. FIXED in this
  commit — one rule, `SongBeatsPerLine.rowBeats`, used by both (timing post-pass tag → timing-2).
- Even with one period, row LENGTHS are not fixed: only 2–42 % of lyric rows are within ±½ beat of
  P; medians ≈ P but spreads run 2 → 26 beats. Rows are what ASR grouping + the gap-seeking
  recutter left; the preview's frame is only a floor (`max(frame, content)`).

## Proposal — music-first rows
Rows are exactly P beats, anchored on the bar grid's downbeat phase (`MetronomeGrid` with period
P·beat, anchor `beatTimes[barGrid.barPhase]`), for the whole song. Lyric words are ASSIGNED to the
window containing their onset; a phrase longer than P continues on the next row (no stretching);
consecutive empty windows collapse into the existing uniform chord-only rows. ChordPro and the
preview both consume these windows (`SongTimeline.Row.start/end`), so they are identical by
construction. The recutter becomes unnecessary for row boundaries (keep it only if lyric-line
identity for editing/accept state needs it; else retire).

## Acceptance
- Diagnostic: ≥ 95 % of lyric rows within ±½ beat of P; remainder exact multiples (final row of a
  section may be short — allow ≤ 1 short row per section).
- Existing tests: `ChartGeometryInvariantTests`, `ChordProPreviewLineLayoutTests`, grouping tests
  adjusted only where they encode the old variable-length rows.
- Overrides/accepted state carried by word identity across the re-cut (`TimedLyricSegment.reconciled`).

## Open
- User `beatsPerRow` override (View menu) must drive the SAME window builder, not just the frame.
- Pickup words before the song's first downbeat: first window starts at the anchor minus P.
