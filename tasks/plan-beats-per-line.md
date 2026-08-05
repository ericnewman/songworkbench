# Plan — song-level beats-per-line (Task #47)

Status: **PLAN — awaiting Eric's approval, nothing implemented.**
Raised 2026-08-05. Supersedes nothing; extends `tasks/quality-review-2026-07.md` and the
2026-08-01 bar-slot measurement.

## Problem

Line boundaries are decided three times by three authorities that never share state:

1. `TimedLyricSegmentGrouper` — punctuation, capitalization+gap, ASR segment cues, silence gaps.
   Tempo-blind.
2. `IntraLinePauseSplitter` / `StrandedLeadingWordRepairer` — VAD voiced intervals. Tempo-blind.
3. `LyricPhraseGrouper` — the only bar-aware pass. Measured to fire on **zero** real songs
   (0.09–0.29 confidence against a 0.75 gate).

The result is never stored: no bar, beat, or measure field exists on `TimedLyricSegment` or
`SongTimeline.Row`. Bar association is recomputed from `MeasureGrid` on demand and discarded.
Visually, row width = real duration x 200 px/s with no shared metric frame, so a mis-segmented
line is indistinguishable from a genuinely long one.

## Measured basis (2026-08-05, six live container songs, read-only Python)

Scripts: `.scratch/swb_bpl.py`, `.scratch/swb_metrical.py`. Non-circular inputs only — stored line
START times plus median beat spacing. No chord-window evidence (that is the circularity trap named
on 2026-08-01), no downbeat phase.

### A song-level beats-per-line exists

| song | bpm | best P | median rel. err | outlier lines |
|---|---|---|---|---|
| Flip Flops | 147.7 | 8 | 0.092 | 15% |
| Doc Holiday | 101.3 | 5 | 0.098 | 18% |
| Summertime | 112.3 | 5 | 0.097 | 18% |
| Key West | 93.7 | 8 | 0.105 | 16% |
| Paradise | 87.1 | 4 | 0.155 | 29% |
| Settle Down | 110.0 | 6 | 0.245 | 48% |

Key West's 8.12 independently reproduces the 8.01 that Route 4 recovered on 2026-08-01. Outlier
rate tracks known breakage (15–18% clean vs 29% / 48% broken).

### Non-dyadic P is a tempo-level tell

The two songs whose P is non-dyadic are exactly the two the chord-loop pass flagged as being on a
wrong metrical level. Scoring candidate tactus ratios by how well line IOIs fit a dyadic P:

| song | chord-loop said (2026-08-01) | dyadic-P says | agree |
|---|---|---|---|
| Summertime 112.3 | 168.5 or 84.3 | 84.3 (0.070), ties 168.5 (0.070) | yes |
| Doc Holiday 101.3 | 152.0 | **152.0** (0.079) | yes |
| Paradise 87.1 | unchanged | KEEP | yes |
| Key West 93.7 | unchanged | KEEP | yes |
| Flip Flops 147.7 | unchanged | KEEP | yes |
| Settle Down 110.0 | 88.0 | 164.9 (0.232) | **no** |

Two independent non-circular signals agree on 5 of 6, including both confident retunes. The
disagreement is the song with 48% outliers and a 0.20-beat minimum line duration — its line onsets
cannot carry a tempo verdict. Gate `err <= 0.15 AND err <= 0.6 x current` gives the correct verdict
on all six: Settle Down declines to retune and is flagged instead.

## What this plan deliberately does NOT do

- **No downbeat phase.** Measured dead 2026-08-01: slot boundaries near a real inter-word gap
  maxed at 53% against a 70% gate; on Key West only 10 of 33 line starts sat within 0.35 s of a
  slot (median deviation 0.63 s, about one full beat). Period recovery worked; phase did not.
  Everything below needs period only.
- **No re-cutting of lines from P** this pass (Eric, 2026-08-05: diagnose first).
- **No 2:1 octave reconciliation.** The loop test provably cannot discriminate it (a 4-bar loop is
  8 bars at half tempo). Only 3:2, 2:3, 4:3, 3:4, 5:4, 4:5.
- **No content rescaling in the renderer.** Word x stays measured time. Per Eric's standing rule,
  a grid-quantized time makes every later comparison circular.

## Steps

- [ ] **1. Metrical-level reconciliation in `BeatTracker`** (`BeatTracking.swift:139-224`).
      `analyze` keeps one `bestLag` and never compares it to related lags. Add a post-ACF pass over
      the six ratios, scored by dyadic beats-per-line fit over measured line onsets, gated as
      above, tie-broken by the independent chord-loop score. Note `BeatTracker.confidence` is
      structurally pinned near `1/nLags` and is NOT a usable gate — do not reuse it.
      Expect: Doc Holiday -> 152.0, Summertime -> 84.3 or 168.5, other four byte-identical.
- [ ] **2. `SongBeatsPerLine` estimator.** Period only, dyadic candidates {4, 8, 16}, per-section
      override permitted, carries median-relative-error as confidence, refuses to answer below the
      gate. **Persisted on the document** rather than recomputed and discarded.
- [ ] **3. Outlier flags.** Classify each line's measured IOI against small multiples of P:
      ok / short (< 0.6P) / long (> 1.6P). Surface through the existing structure-alignment
      diagnostics. Generalizes the existing within-section line-length heuristic to a song-level
      reference. Diagnostic only.
- [ ] **4. Uniform P-beat frame** in `ChordProPreviewLineView`
      (`WorkspaceEditorsView.swift:3330`). Frame width `P * beatLength * pixelsPerSecond`, barlines
      in fixed columns, reusing the existing `gutterPx` downbeat pin (`:3533`). `metricX`
      (`:3540`) and `rhythmicWordXs` (`:4071`) are untouched — a long line visibly overruns its
      frame, a short one under-fills. That overrun IS the diagnostic.
- [ ] **5. Verify.** Diff both retuned songs before/after (the retune re-derives chords); confirm
      the four KEEP songs are unchanged; confirm outlier rates drop on Doc Holiday and Summertime.
      Rebuild the .app with `xcodebuild` (not `swift build`) and UI-verify. Run `tuist generate
      --no-open` for any new file and commit `project.pbxproj` in the same commit.

## Risks

| risk | mitigation |
|---|---|
| Tempo retune re-derives chords on 2 songs and could regress them | Gate is conservative; diff chord output before/after and treat a regression as a veto |
| Summertime's 84.3 vs 168.5 tie is unresolved by this signal alone | Tie-break with the chord-loop score, which preferred 168.5 (0.063 vs 0.126) |
| P varies by section (verse vs chorus) | Estimator supports a per-section override; song-level is the default, not an assumption |
| Settle Down stays broken | Expected and correct — it is flagged, not silently retuned. Its segmentation is the real defect |
