# Fix: missed chord changes + dropped end-of-song lyrics (2026-07-04)

## Diagnosis (verified against code + real cached data)

### Symptom 1: Missed chord changes
Owner: `ChordTimelineDecoder` (Viterbi), NOT the old `ChordEventReducer` (only used as no-beat-grid fallback).

1. **Viterbi switchPenalty = 2.0 over-smooths** (`ChordTimelineDecoder.swift:19`).
   A one-window (one-beat) chord excursion pays 2×2.0 nats ⇒ needs ~e⁴≈55× evidence
   dominance in that window to survive. Real sweep on cached frames (Settle Down,
   482 beats, 2105 frames ≥0.45 conf):
   - penalty 2.5 → 106 events; 2.0 → 124; 1.5 → 137; 1.0 → 161; argmax voting → 215.
   Passing chords / one-bar changes are systematically absorbed.
2. **KeyPriorChordRescorer chromaticWeight 0.5** (`KeyAwareChordFiltering.swift:20`)
   compounds with the penalty: real secondary dominants/modulations rarely win.
3. **ChordOnsetAligner + ChordEventDurationFilter interaction**
   (`AudioFileAnalysisService.swift:539-570`, `KeyAwareChordFiltering.swift:101-146`):
   snap's nondecreasing clamp can compress two REAL changes to sub-0.8-beat spacing;
   the duration filter then drops one and `collapseDuplicates` can erase an A-B-A
   into a single A. Persisted docs show min gaps 0.7-1.0 beat, so this fires.

### Symptom 2: Lyrics dropped at end of songs
Owner: `TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail`
(`AudioFileAnalysisService.swift:1492-1513`), applied on the pure-ASR path in
`AnalysisStage.swift:434`.

- The geometric heuristic fires on virtually ANY song: if the 2nd-to-last line ends
  ≥3s before file end and the last line starts within 2s of it (normal singing), the
  cutoff = 2nd-to-last line's end ⇒ **final line(s) always cut**.
- **Proof from real data (Settle Down, pure-ASR)**: raw Whisper cache has
  `[220.8-225.9] "I never thought I'd want to hang around." conf 0.98` and
  `[226.8-229.8] "She makes me want to settle down." conf 1.00` — both missing from
  the final doc (final last end 220.3 in a 257.1s song). Key West Bar similarly loses
  its repeated outro hook (17s of vocals).
- Tests only cover the Summertime hallucination fixtures; no test covers a normal
  final line with `sourceDuration` set — which is why this shipped.
- The heuristic checks only geometry, never whether tail lines look degenerate
  (word count, confidence, duplication) and `min(signalCutoff, lyricBodyEnd)` lets
  it OVERRIDE a correct VAD that says vocals continue.

## Fix plan

### Lyrics (do first — bigger, clearer win)
- [ ] `lyricBodyEndBeforeInstrumentalTail`: only return a cutoff when the tail looks
      degenerate — every tail line is (a) ≤2 substantive words, or (b) a normalized
      duplicate of an earlier line or of another tail line. Keeps Summertime blips
      ("I", duplicated "Sunset winks…") cut; keeps real unique closing lines.
- [ ] `resolvedCutoff`: geometry may only TIGHTEN the VAD signal cutoff by ≤3s
      (never override a VAD that says vocals continue much later).
- [ ] Add regression tests: normal final line + sourceDuration (Settle Down shape),
      repeated-outro-hook kept, Summertime fixtures still pass.

### Chords
- [ ] Lower `switchPenalty` 2.0 → 1.5 AND make it onset-aware: pass the instrument
      onsets (already computed for snapping) into the decoder; windows whose start
      lies within ~0.12s of an onset get a reduced penalty (~0.75). Real changes
      happen on attacks; flicker suppression stays for mid-note windows.
- [ ] `ChordOnsetAligner.snap`: don't move an event if that compresses gap to the
      previous event below 0.8 of the local beat (kills the sliver source instead of
      deleting real events downstream).
- [ ] Keep ChordEventDurationFilter as safety net; add A-B-A regression test proving
      genuine one-beat B on an onset survives the whole pipeline.
- [ ] Bump reducer-version suffix in `AnalysisStage.swift:618` so cached raw frames
      re-reduce without re-running chroma.

### Verify
- [ ] Unit tests green; xcodebuild on Mac; re-analyze Settle Down + one more song;
      confirm final lyrics reach ~230s and chord event count rises with changes
      landing on onsets.

## Review (2026-07-05)

Implemented, all in existing files (no tuist generate needed):
- `ChordTimelineDecoder`: switchPenalty 2.0→1.5; new onset-aware per-window penalty
  (×0.5 within 0.12s of an instrument onset); `decode(switchPenalties:)` +
  back-compat constant overload; onsets plumbed from AnalysisStage (computed
  before decode, reused for snap).
- `ChordOnsetAligner.snap(beatTimes:minimumBeatFraction:)`: refuses snaps that
  compress neighbours below 0.8 beat (sliver source eliminated; duration filter
  now truly a safety net).
- `TrailingLyricTailPruner`: `tailLooksDegenerate` (≤2 words or normalized dup)
  gates the geometric body-end; `maxSignalTightening = 3.0` caps how far geometry
  may tighten the VAD cutoff.
- Stage tags bumped: `reduce-12-onset-viterbi`, `grouping-42-degenerate-tail-prune`
  → next analysis re-reduces/re-groups from cached raw data, no re-chroma/re-ASR.
- Tests: +2 decoder (onset excursion survives / far onsets don't discount),
  +4 pruner/aligner (Settle Down kept, Key West hook kept, blip tail still cut,
  no sub-beat snap sliver). Full suite 558 tests: only the 8 pre-existing
  AppModelTests environment failures (identical on clean main, verified by stash).
- swift format lint clean.

Remaining to fully verify: re-analyze Settle Down / Key West in the app and
confirm final lyrics reach ~230s and chord changes land on onsets.

## Batch 2 review (2026-07-05, later)

- **Bass notes positioned on the time axis**: `BassNoteRowFormatter.timedLabels`
  (onset + name); `ChordProPreviewLineView.rowBassNotes` renders each note at
  `rhythmicX(forTime:)` on its own 18px row between the ball/dot reserve and the
  chords (collision-nudged like chords). Flush-left label kept only as
  monospace/override fallback. +2 formatter tests.
- **Duplicated preview lines (ball skips them)**: verified against persisted docs —
  NOT a preview-builder bug. `LyricBlendRowBuilder.buildRows` clusters the 3
  engines' lines with a 1.5s anchor window; engines timing the same line further
  apart (Grass: 20.26 vs 24.90) produced two rows → two rendered lines.
  Fix: `mergeCrossModeDuplicates` — merge adjacent clusters (≤8s apart) whose mode
  sets are DISJOINT and normalized texts equal; real repeated hooks share a mode
  and never merge. +3 tests. Also `ReferenceLyricAligner` now drops pasted-site
  timestamp tokens/lines ("0:00" junk, Flip Flops). +1 test. Existing docs clean
  up on next Analyze (grouping-42 re-groups from cached raw).
- **Smooth auto-scroll**: replaced default spring `scrollTo` with a 1.1s easeInOut
  glide (`ChordProAppPreview.autoScrollGlide`), anchor .center; ScrollView
  clamping inherently defers scrolling until the active line can reach center.
- Full suite 564 tests: only the 8 pre-existing AppModelTests environment
  failures. Lint clean. UI changes need an app rebuild + relaunch to see.

## Batch 3 review (2026-07-05): vocal-onset corroboration (Eric's invariant)

- `LyricBlendRowBuilder.onsetCorroboration(words:vocalOnsets:tolerance:)` — pure
  scorer: fraction of a candidate's word onsets within 0.18s of a vocal-stem
  energy onset (binary search, unit-tested).
- `onsetPreferredMode` / `onsetCorroborated(rows:vocalOnsets:)` — for rows the
  user hasn't picked, flip to the candidate the stem clearly corroborates
  (margin ≥ 0.25 over the accuracy-first default); user picks never touched.
- Wired into `AppModel.runLyricBlendPasses` AFTER reconcile: vocals-stem onsets
  via `InstrumentOnsetDetector` on a detached utility task; missing stem = no-op.
- +4 tests (scorer fractions, flip, user-pick protection, margin). Suite: 561
  run (audible playback suites now skipped locally via --skip to stop the
  "raspberry" — they play a real AVAudioEngine), same 8 pre-existing failures.
- .app rebuilt via xcodebuild (Debug) — RELAUNCH REQUIRED to see today's UI work.

Follow-ups (not started): per-line orphan flag in Review UI (line with ~zero
onset corroboration = suspect), unmatched-onset audit beyond the existing
untranscribedVocalRegions badge, and real-audio validation of the auto-pick
margin on Flip Flops after re-analysis.

## Batch 4 review (2026-07-05, afternoon)

- **Window/layout**: control row's fixed widths made content min ~1,790 > 1,540
  default ⇒ SwiftUI centered + clipped both outer columns. Tab picker moved into
  the middle pane (Eric's suggestion), scrubber/pitch/speed sliders made
  compressible, root minWidth 1,380. Sidebar + stem rail both 360pt (symmetry).
- **Blend fixes round 2**: non-adjacent cross-mode duplicate merge (Grass line
  landed 2 rows past its twin); Lyric Blend window no longer auto-opens —
  toolbar icon glows mint + badge when results are ready.
- **Re-analysis validation (Flip Flops)**: chords 119→133, 0:00 junk gone,
  outro kept; line-2 zipper traced to the non-adjacent duplicate (fix awaits
  next ⌘R).
- **Bass-vs-chord clashes** (measured 24–43%): BassLineAnalyzer parabolic lag
  interpolation + global tuning-offset via clarity-weighted CIRCULAR mean;
  display floor at clarity 0.5. Detuned-fourth regression test.
- **Mixer pan + L/R meters**: StemMixState.pan (persisted, back-compat),
  constant-power panGains, stemStereoLevels post-fader/post-pan, PanKnob rotary
  + HorizontalLRMeter per strip, export carries pan. AVFoundation gotcha: set
  AVAudioMixing params AFTER engine start (unit-test guarded).
- Suite: 568 tests, same 8 pre-existing AppModel env failures. App rebuilt —
  NEEDS RELAUNCH; then ⌘R re-analysis cleans remaining duplicates and applies
  the bass-detector fixes.

---
# (previous) Align to Reference Lyrics — done 2026-06-25, see git history for details
