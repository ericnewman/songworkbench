# Align to Reference Lyrics

Goal: user pastes a song's real lyrics; we align them to the audio using the
existing ASR word timings (no new model). Reference text gives perfect words +
line breaks; ASR gives the timing.

## Plan
- [ ] Data model: add `referenceLyrics: String?` to the song document; persists.
- [ ] Core: `ReferenceLyricAligner` — align reference words to ASR words
      (Needleman-Wunsch on normalized text), borrow ASR timings, interpolate
      timings for reference words ASR missed. Lines come from reference newlines.
      Pure + fully unit-tested.
- [ ] Wire: when referenceLyrics present, produce aligned TimedLyricSegments
      that override the ASR-grouped lyrics (in applyAnalysis or a dedicated step).
- [ ] UI: a field/sheet to paste reference lyrics + trigger alignment.
- [ ] Verify: unit tests for alignment (matches, inserts, deletes, interpolation,
      line breaks); build; re-align Flip Flops and confirm.

## Notes
- Reuse Needleman-Wunsch from the (unwired) RepeatedLyricCorrector if present.
- Reference newlines = line breaks (sidesteps all ASR grouping heuristics).

## Review (done 2026-06-25)
- ReferenceLyricAligner built + unit-tested (4 tests: timing borrow, interpolation,
  char ranges/punctuation, blank-reference passthrough). All pass.
- document.referenceLyrics persisted; transcription stage aligns when present and
  folds a stable FNV hash of it into the stage version (edit -> re-align from cached
  raw, no re-transcription).
- AppModel.referenceLyrics + applyReferenceLyrics(); Reference Lyrics sheet UI with
  green checkmark when active.
- VERIFIED on Flip Flops: a corrected 9-line reference produced exact words
  ("Like"/"brews" overriding ASR "Laugh"/"bruise") and reference line breaks, timed
  from ASR; stage version showed |ref-<hash>. Reverted test injection; song clean.
- Note: paste the FULL lyrics incl. repeats — repeated short references align to a
  single ASR occurrence, leaving gaps (expected).
