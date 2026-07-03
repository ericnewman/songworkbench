# Audit: bouncing-ball / chart timing symptoms (2026-07-01)

Song used for verification: **"Summertime's her with you (Edit)"** (most recently opened).
All numbers below were measured from the app's real container data (persisted lyric
segments, beat cache, vocals stem RMS) — not guessed from code.

## Symptoms reported

1. Ball only followed ONE line of a multi-line intro.
2. Ball started into the words several seconds before they were really sung.
3. Non-existent pause rendered inside line 8 ("Sitting on the beach with you").
4. No instrumental break shown between lines 8 and 9.
5. Ball consistently falls farther and farther behind during playback.

## Ground truth measured from data

- Real vocal onset: **24.5 s** (vocals stem RMS). ASR first word "Warm" = 24.56 s → the
  first-line timing itself is CORRECT.
- Intro (0–24.56 s) renders as **3 chord-only rows** (11 bars split 4+4+3).
- Line 8 = seg4 "Sitting on the beach with you": ASR gives "Sitting" a **0.08 s** span
  (35.02–35.10) then "on" at 36.15 → a ~1 s blank hole is drawn mid-line. Vocals show the
  word is actually held ("Sittiiing") with only a ~0.5 s dip — the rendered pause is an
  ASR word-span artifact. Same pattern: "Summertime's" 0.13 s (46.1), "here" not until 48.2.
- Real instrumental fill **37.6–38.4 s** (vocals fully silent) between lines 8 and 9 —
  below the 4-bar threshold, so the chart renders nothing.
- Vocal activity map vs segments: sung regions **49.8–55.4** and **58.1–61.7** have NO
  transcribed words (chorus tail + verse-2 lead-in). The chart's "Instrumental · 6 bars"
  (49.8–61.7) is mostly WRONG — the real break is only 55.4–58.1. Outro regions
  **121.7–124.4** and **141.0–151.3** contain vocals but the chart shows chords only.
- Beat grid is clean: 295 beats, median IBI 0.534 s = 112.35 BPM, no drift in the grid.
- Source mp3 is **48 000 Hz**; stems are 44 100 Hz.

## Root causes

### RC-1 — Playback clock timebase mix-up (symptom 5, likely 2)
`AudioPlaybackService` connects `player → timePitch` with `format: nil` at init, so the
player's output bus runs at the engine/default rate — not the file's rate.
`updateCurrentTime()` then computes
`playerTime.sampleTime / audioFile.processingFormat.sampleRate` — **sampleTime is in the
bus's timebase, the divisor is the file's (48 k)**. Whenever the two differ the reported
clock runs fast/slow by the ratio (44.1/48 = 8.2 % slow → ~5 s of lag per minute; the
reverse ratio runs early). Audio itself sounds fine, only the ball/highlight clock drifts.
`StemPlaybackService` happens to be consistent today (connects with
`file.processingFormat`) but uses the same fragile division.

**Fix:** compute elapsed with the timebase the sampleTime is expressed in —
`playerTime.sampleTime / playerTime.sampleRate` — in BOTH services (AVAudioTime carries
its own rate). One-line, root-cause fix.

### RC-2 — Waiting ball maps the whole gap onto ONE chord-only row (symptoms 1, 2)
`ChordProDraftBuilder.instrumentalLines` splits a long intro into N rows, each with its own
time window — but those windows are thrown away when the chart is serialized to ChordPro
TEXT. On the render side, `chordOnlyLineOffset(beforeLyricOrdinal:)` walks UP from the
upcoming lyric line and attaches the ball to the single nearest chord-only row, and
`beatBallValue` gives that row the ENTIRE gap window `[0, 24.56]` with all gap chords.
Result: the ball rides only the last intro row, gliding across its chords far ahead of
when that row's bars actually play (row 3 begins ~16.9 s, ball is already ~70 % across it).

**Fix (structural):** keep the per-row time windows and give the ball the row whose window
contains `now` — see the architecture section.

### RC-3 — ASR word spans are not validated against vocal energy (symptom 3)
Whisper gives held/melisma words tiny spans at onset and pushes the next word's onset
late. Rhythmic layout renders onset-proportional x, so a held word becomes a blank "pause."
This is the same class of defect as the earlier "Grass" incident (tasks/lessons.md
2026-06-25): timing error, not content error.

**Fix:** post-alignment pass on words using the vocals-stem energy already computed for
the onset gate: extend a word's end to the next word's onset when vocal energy is
continuous between them (melisma bridge), and pull implausibly late onsets back to the
energy edge. Pure data normalization; no model change.

### RC-4 — Break rendering is inconsistent with break detection (symptom 4)
Sub-4-bar real gaps (37.6–38.4 s) get NO visual break, while phantom intra-line gaps
(RC-3) DO render. The user reads this as "pause in the wrong place." Also the 6-bar
instrumental after the chorus is mis-bounded because the ASR missed sung content
(49.8–55.4, 58.1–61.7) — structure decisions are built on unvalidated ASR coverage.

**Fixes:** (a) render a small in-line rest/fill marker for ≥2-beat vocal gaps backed by
vocal-energy silence; (b) flag untranscribed vocal regions (energy present, no words)
instead of silently labeling them Instrumental — offer re-transcription of just that span.

## The architectural problem (why this is whack-a-mole)

There is **no single timeline model**. Six subsystems each independently re-derive
"structure × time × layout":

1. ASR segments/words (persisted, unvalidated inside the song).
2. `ChordProDraftBuilder` — decides rows/sections WITH time windows, then serializes to
   a ChordPro **string**, discarding every window.
3. `ChordProPreviewDocument` — re-parses that string into blocks.
4. `ChordProHighlightDeriver` — re-derives active-line state from raw segments, assuming
   chart lyric line N ↔ sorted segment N (ordinal-counting convention).
5. `WorkspaceEditorsView` glue — re-attaches time to blocks via adjacency heuristics
   (`chordOnlyLineOffset` walk-up, whole-gap windows, chord/word x interpolation).
6. Two playback services with private clock math, mixed per active source in the view.

Every consumer re-guesses what the builder already knew. Each local patch moves the
mismatch to the next consumer — that is the whack-a-mole engine.

### Proposed consolidation

**One `SongTimeline` value type, produced once, consumed everywhere.**

- Builder emits `[TimelineRow]`: `.lyric(segment, words, window)`,
  `.instrumental(chords, window, kind: intro/break/outro)`, `.restMarker(window)` —
  each row carries its authoritative `[start, end)` window. The ChordPro string becomes a
  *projection* of this model (for export/manual editing), not the interchange format.
- Preview renders rows directly; highlight/ball/dots/auto-scroll become a single lookup:
  `timeline.row(containing: now)` + per-row local mapping. Deletes
  `chordOnlyLineOffset`, `trailingChordOnlyLineOffset`, ordinal-matching, and the
  whole-gap window hack (RC-2 disappears by construction).
- One `PlaybackClock` protocol (`currentTime` from `sampleTime/sampleRate`) implemented by
  both services (RC-1 fixed at the root, once).
- A `WordTimingNormalizer` stage (RC-3) runs at analysis time, before grouping, using the
  vocals-energy envelope; the timeline is built from normalized words.
- Reviewed/imported charts: rows parsed from user text get windows re-attached by the
  SAME single alignment routine, so manual edits keep working.

### Suggested order of work

1. RC-1 clock fix (tiny, immediate, testable: play 60 s, ball stays locked).
2. RC-3 word normalization (data quality; fixes line-8 pause + improves everything else).
3. `SongTimeline` refactor (RC-2, RC-4 and the class of future bugs).
4. Untranscribed-vocal detection + UI flag (chorus tail / outro vocals).

## Verification evidence lives in
- Vocals RMS regions: sung = [23.5–55.4, 58.1–92.7, 94.9–109.7, 121.7–124.4, 141.0–151.3]
- Beat cache: 295 beats, 1.14–158.15 s, median IBI 0.5341 s
- Container store: `~/Library/Containers/com.local.SongWorkbench/Data/Library/Application
  Support/SongWorkbench/projects.json`
