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

## Review

(to be filled after implementation)

---
# (previous) Align to Reference Lyrics — done 2026-06-25, see git history for details
