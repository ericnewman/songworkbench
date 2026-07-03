# Spec: SongTimeline consolidation + timing fixes (2026-07-01)

Companion to `tasks/audit-ball-timing.md` (root causes RC-1…RC-4, measured on
"Summertime's her with you (Edit)"). Goal: end the whack-a-mole by making ONE typed
timeline the source of truth for structure × time, and fixing the two data/clock defects
underneath it. For review before implementation.

---

## Phase 0 — RC-1: PlaybackClock fix (tiny, independent, ship first)

**Defect.** `AudioPlaybackService.updateCurrentTime()` divides `playerTime.sampleTime`
(expressed in the player node's OUTPUT BUS rate — the bus was connected with
`format: nil` before any file existed) by `audioFile.processingFormat.sampleRate` (48 kHz
for this mp3). Any bus/file rate mismatch scales the clock (44.1/48 → 8.2 % slow, ~5 s
lag per minute). `StemPlaybackService.updateCurrentTime()` has the same division and is
only accidentally consistent.

**Change.**
- `AudioPlaybackService.swift` and `StemPlaybackService.swift`: compute
  `elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate`
  (AVAudioTime carries its own rate — always the correct timebase).
- `AudioPlaybackService.load()`: reconnect `player → timePitch` with
  `file.processingFormat` (as StemPlaybackService already does) so scheduling never
  relies on implicit conversion.
- Extract a tiny shared helper so the math exists once:
  `enum PlayerClock { static func elapsedSeconds(_ player: AVAudioPlayerNode) -> TimeInterval? }`
  used by both services. (Full protocol unification folds into Phase 3.)

**Tests/verify.**
- Unit: `PlayerClock` math with a synthetic AVAudioTime (sampleRate 44100 vs 48000).
- Live: play Summertime (48 kHz mp3) 60+ s from the original file; ball/highlight stay
  locked; A/B against stem-mix playback (44.1 kHz) — both clocks agree with the waveform
  playhead.

---

## Phase 1 — RC-3: Word-timing normalization (data quality)

**Defect.** Whisper melisma: held words get tiny spans and the following onset lands
late ("Sitting" 35.02–35.10, "on" 36.15; "Summertime's" 46.10–46.23, "here" 48.21).
Rendered as phantom mid-line pauses; also feeds wrong windows to everything downstream.

**Change.** New `VocalWordSpanNormalizer` (pure, unit-tested), run in the transcription
stage AFTER `distributeAcrossSignal`/onset snapping, BEFORE grouping — both ASR and
reference paths (same wiring point as `StrandedLeadingWordRepairer`):
- Input: words + the vocals-stem RMS envelope already computed for the onset/offset gates
  (`VocalRMSEnvelope`).
- Rule A (melisma bridge): if the gap `[word.end, next.start]` is ≥ 0.4 s and vocal
  energy is CONTINUOUSLY voiced across it (strict-VAD voiced fraction ≥ ~0.8), extend
  `word.end` to `next.start` — the word is held; there is no pause.
- Rule B (late-onset pullback): if the gap is mostly UNVOICED but `next.start` sits
  > 0.25 s after the voiced re-entry edge, pull `next.start` back to that edge (mirror
  image of Rule A; bounded, nondecreasing, start < end).
- Never delete tokens (lessons.md 2026-06-25); only re-time.
- Bump grouping tag → `grouping-39-word-span-normalizer` so re-analysis re-groups from
  cached raw ASR.

**Tests/verify.**
- Unit: synthetic envelope — held word bridged; real pause NOT bridged; late onset pulled
  to energy edge; ordering/monotonicity preserved.
- Golden: re-analyze Summertime → line 8 renders without the 1 s hole; "Summertime's
  here" no longer shows a 2 s hole; assert seg4 word spans from projects.json.

---

## Phase 2 — RC-4 (data half): untranscribed-vocal detection

**Defect.** Sung regions with no words (49.8–55.4, 58.1–61.7, 121.7–124.4, 141.0–151.3 s)
are silently mislabeled Instrumental/Outro; structure decisions are built on unvalidated
ASR coverage.

**Change.** New `UntranscribedVocalRegionDetector` (pure): diff strict-VAD voiced
intervals against word coverage; regions ≥ 1.5 s voiced with zero words become
`untranscribedVocalRegions: [ClosedRange<TimeInterval>]` persisted on the document
(schema-additive, defaults to empty on decode).
- Consumers (Phase 3 timeline): such a region inside a "gap" renders as a
  `vocals — unrecognized` row (distinct style), NOT as Instrumental; bar-count comments
  computed from the true instrumental sub-range only.
- Follow-up (separate, not this spec): one-click re-transcription of just that span.

**Tests/verify.** Unit on synthetic VAD+words; golden on Summertime: the "Instrumental ·
6 bars" after chorus 1 must shrink to the real 55.4–58.1 break with flagged vocal rows
either side.

---

## Phase 3 — RC-2 + architecture: `SongTimeline` as single source of truth

**Principle.** The builder already decides rows/sections WITH time windows, then throws
the windows away by serializing to a ChordPro string; five consumers re-guess them.
Invert it: build the typed model once; the string becomes a projection.

### 3a. Model (new file `SongTimeline.swift`, pure, Codable, Sendable)

```swift
struct SongTimeline: Equatable, Codable, Sendable {
    var rows: [Row]                    // ascending, non-overlapping windows
    var sections: [Section]            // Intro/Verse N/Chorus/Instrumental/Outro spans

    struct Row: Equatable, Codable, Sendable, Identifiable {
        let id: Int                    // stable display number (matches current displayLine)
        var kind: Kind
        var window: Range<TimeInterval>        // authoritative [start, end)
        var chords: [PlacedChord]              // time + label (column derived at render)
        enum Kind: Equatable, Codable, Sendable {
            case lyric(segmentOrdinal: Int)    // index into sorted lyricSegments
            case instrumental(role: InstrumentalRole)   // intro/break/outro SLICE (one rendered row)
            case unrecognizedVocals            // Phase 2 regions
            case rest                          // ≥2-beat true silence marker (RC-4 render half)
        }
    }
    struct PlacedChord: Equatable, Codable, Sendable { var time: TimeInterval; var label: String }
    struct Section: Equatable, Codable, Sendable {
        var label: String; var window: Range<TimeInterval>
    }

    func row(containing time: TimeInterval) -> Row?     // binary search
    func nextRow(after time: TimeInterval) -> Row?
}
```

Key invariant the whole app gets for free: **every rendered row knows its own window**.
A multi-row intro is N rows with N windows — RC-2 becomes unrepresentable.

### 3b. Producer

- Refactor `ChordProDraftBuilder` into two layers:
  1. `SongTimelineBuilder.build(input) -> SongTimeline` — all existing decisions move
     here unchanged (gap ≥ 4 bars → instrumental rows via `instrumentalLines` slicing,
     section labeling, sustained-chord restatement, trailing-chord folding, tail pruning).
     Plus: `.rest` rows for ≥ 2-beat true-silence gaps (RC-4), `.unrecognizedVocals`
     rows from Phase 2.
  2. `ChordProTextRenderer.render(timeline, lyrics) -> String` — string projection,
     byte-compatible with today's output for the standard draft (golden test), so
     export/copy and the raw-text editor keep working.
- `SongTimeline` is NOT persisted: it is derived state, rebuilt by `AppModel` whenever
  `(lyricSegments, chordEvents, beatTimes, threshold, sourceDuration)` change — same
  trigger that rebuilds the draft today. (Avoids a schema migration and staleness bugs.)

### 3c. Consumers (the deletions are the point)

- `WorkspaceEditorsView` App Preview iterates `timeline.rows` directly (row → view),
  instead of `indexedBlocks(for: parsedDocument)`.
  - Ball: `timeline.row(containing: now)` + per-row local x mapping. While in an
    instrumental row, the ball tracks THAT row's chords over THAT row's window; the
    next intro row takes over when `now` crosses its window. DELETE
    `chordOnlyLineOffset(beforeLyricOrdinal:)`, `trailingChordOnlyLineOffset(in:)`,
    the whole-gap `BeatBallInput` window hack, and the waiting/outro special cases —
    one code path for lyric/instrumental/rest rows.
  - Highlight, beat dots, auto-scroll, `chordOnlyLineWindow`, `lyricLineWindows`,
    `wordTimings(forLyricOrdinal:)` all become row-window lookups.
  - `ChordProHighlightDeriver` shrinks to word-level logic inside a lyric row (its
    line-level `activeSegmentIndex` moves onto `SongTimeline`).
- Reviewed/imported charts (`chordProReviewState` = reviewed, or user-edited source):
  parse the user text into blocks, then re-attach windows with ONE alignment routine
  `SongTimeline.aligned(toParsed: document, lyrics:, chords:)` — nth non-blank lyric
  line ↔ nth sorted segment (today's convention, now in exactly one place, with a
  mismatch fallback = plain rendering, no ball, and a visible "timing unavailable" note
  instead of silent misalignment).
- Lyrics view (`LyricSectionDeriver` consumers) switches to `timeline.sections` so the
  Lyrics editor and the chart can never disagree about sections.

### 3d. Clock unification (completes Phase 0)

`protocol PlaybackClock { var currentTime: TimeInterval { get } var isPlaying: Bool { get } }`
implemented by both services; `AppModel.activePlaybackTime` returns the active one;
`WorkspaceEditorsView.currentPlaybackTime` stops choosing between services itself.

### Tests/verify (Phase 3)

- Unit: `SongTimelineBuilderTests` — multi-row intro produces N rows with correct
  windows; rest rows at the 37.6–38.4 s gap; unrecognized-vocals rows; renderer golden
  test (existing `ChordProDraftBuilderTests` corpus must pass unchanged through the
  two-layer path).
- Unit: ball row-selection — `row(containing:)` walks intro rows in sequence (the RC-2
  regression test), enters the first lyric row at 24.56, outro rows after the last lyric.
- Migration safety: reviewed charts with hand-edits still render; mismatch fallback
  covered by a test with a user-added line.
- Live (Summertime): ball visits all 3 intro rows in time; enters "Warm sun…" at the
  audible vocal onset; line 8 has no phantom hole but shows the 2-beat rest between
  lines 8 and 9; chorus-1 tail shows the unrecognized-vocals row; 60 s drift check.
- Rebuild the .app with xcodebuild + relaunch before UI verification (lessons.md).

---

## Order & risk

1. **Phase 0** — one-line root-cause fix, immediately user-visible. No dependencies.
2. **Phase 1** — pure data pass + grouping tag bump; touches the heavily-tuned
   transcription path, so it ships with its own unit + golden tests before Phase 3
   consumes the improved words.
3. **Phase 2** — additive schema + detector; independent of Phase 3 but its rows render
   only once Phase 3 lands (until then the data is just persisted).
4. **Phase 3** — the big one; land as: 3a+3b (model + renderer, golden-tested, no UI
   change) → 3c preview switch (feature-flagged if desired) → 3d cleanup → delete dead
   heuristics. Each step compiles green and is separately revertable.

Out of scope (unchanged): chord decoding quality work (todo.md A-phase), reference-lyric
alignment, ChordPro export fidelity (B-phase) — though B2/B3 get easier on top of
`SongTimeline`.

## Open questions for Eric

1. Rest markers: render as a small "𝄽 2 beats" glyph inside the gap between rows, or as
   trailing space on the earlier row? (Spec assumes a distinct inline marker row.)
2. Unrecognized-vocals rows: visible label ("vocals — not transcribed") vs subtle
   waveform-only row? (Spec assumes visible label; it's actionable.)
3. Keep the raw ChordPro text editor as-is (projection + re-alignment on edit), or move
   editing to structured rows later? (Spec assumes keep as-is.)
