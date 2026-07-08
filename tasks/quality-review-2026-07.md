# Quality Review — chord/lyric detection reliability, timeline precision, instrumental structure (2026-07-08)

Four parallel read-only audits: chord pipeline, lyric pipeline, instrumental structure,
preview render time-scale. Findings verified against code with file:line anchors.
`.build/` and `.worktrees/` excluded.

## Fixed this session (WorkspaceEditorsView.swift, swift build green)

1. **Instrumental beat-dot clustering** — `beatDotPositions` routed chord-only rows through
   `wordCenterX` because bar-grid text (`| . . |`) masquerades as words (`wordCenters` splits
   on whitespace; the `hasSungText` doc-comment at ChordProPreviewDocument.swift:34-45 warned
   about exactly this). Character-column space is far narrower than `instrumentalTimeWidth`,
   so all dots packed near line start. Fix: `!isInstrumentalLine` gate so instrumental rows
   reach the existing time-spread branch (same axis the ball uses at `ballPosition`).
2. **Chord confidence shading → outline box** — `.background(tint.opacity(0.3))` replaced with
   `chordConfidenceOutline(at:)` (strokeBorder, no fill) at all 3 render sites; legend swatches
   updated to match. Accepted/high-tier still renders nothing.

## Answer: do all layers share one time-scale? (Eric's purple-vs-yellow question)

**No — by design asymmetry, and the suspicion is confirmed.** Both row types are internally
consistent, but their widths use different bases:

- Instrumental rows: pure time — `instrumentalTimeWidth = lineDuration × 100 px/s`
  (WorkspaceEditorsView.swift:3256-3261). Chords, strip, ball, (now) dots all map through it.
- Lyric rows: time WITH a per-word monospace floor — `rhythmicWordXs` (:3678-3691) nudges each
  word right to at least `previousX + textWidth + space`, so dense lines stretch 1.5-2× beyond
  `duration × 100`. Chords/strip/ball/dots follow the *nudged* word axis (`rhythmicX`).

So a purple row of equal elapsed time renders ~half the width of a wordy yellow row. Per-layer
mapping table and remaining width unification options are in §Rendering below.

**Secondary bug found:** outro chord-only rows collapse to character-count width when
`chordOnlyLineWindow` can't resolve an end bound without a loaded stem envelope
(WorkspaceEditorsView.swift:2588-2593 → `lineDuration = 0` → char fallback :3260). Fix: resolve
the outro end from song/beat duration as `LyricSectionDeriver.resolvedSongEnd` already does.

## Area 1 — Chord detection (root cause of Task #46 + instrumental noise)

No ML model: cosine template matching over 12-bin chroma, 5 qualities only
(ChordClassification.swift:4-10), source stem guitar→piano→accompaniment→other single-winner
(HarmonyAudioSource.swift:34-49), frames 8192/4096 @44.1k (~93 ms hop), beat-window Viterbi
(ChordTimelineDecoder.swift:230-297), onset snap 0.35 s, min duration 0.8 beat.

Key weaknesses, ordered by leverage:

- **W1. No harmonic-rhythm prior → passing-chord density.** `switchPenalty` 1.5 (tuned down
  from 2.5 for recall), onset discount ×0.5 within 0.12 s — pop onsets land on most beats, so
  changes are near-free every beat. The only floor is 0.8 beat (KeyAwareChordFiltering.swift:104),
  which deliberately KEEPS one-beat passing chords. This is the density that breaks
  `MelodyPhraseProxy` clustering (Task #43-B residual) and floods instrumental chord patterns.
  Fix: metric-position-dependent switch penalty (cheap on downbeats, expensive mid-bar) using
  the downbeat phase already computed by MeasureGrid/DownbeatEstimator; keep onset discount for
  genuine syncopation. Anchor: ChordTimelineDecoder.windowSwitchPenalties (:190-211).
- **W2. Systematic ~93 ms early bias.** Frame timestamp = window START (AudioFraming.swift:82)
  but Hanning energy centers at +frameLength/2. Every chroma observation is labeled ~93 ms
  early; near beat boundaries this buckets evidence into the wrong beat window. Fix: center the
  timestamp; bump harmony cache version.
- **W3. Onset-source mismatch.** Chroma prefers piano second; onset sources for discount/snap
  are guitar→other→accompaniment — piano absent (AnalysisStage.swift:663-668). Piano-led songs
  snap chords to non-harmony transients. No cross-stem latency calibration exists.
- **W4. Nondeterminism.** `ChordEventReducer.winningChord` `Dictionary.max` tie (known,
  ChordEventReducer.swift:87 — fallback path only, no beat grid); plus float sums over
  `Dictionary.values` iteration order (ChordTimelineDecoder.swift:245, ChordEventReducer.swift:88)
  can flip near-ties run-to-run. Cheap fix: keyed tie-break + sorted-key sums.
- **W5. Chroma front-end.** Linear magnitude, no upper frequency cap (cymbal bleed), no tuning
  offset (±50 cent recordings bias `midiNote` rounding) — SpectrumChroma.swift:127-144.
  5-quality vocabulary force-fits sus/dim/aug to triads.

## Area 2 — Lyric detection + word timing

Pipeline: engine timings (Parakeet TDT token timings; Whisper token t0/t1 at 10 ms quantization)
→ ~15 sequential conservative passes (AnalysisStage.swift:193-501) → final
`VocalWordOnsetAligner.snapped` + `VocalWordSpanNormalizer`.

- **W6. Onset refinement, not forced alignment; starts only.** `VocalWordOnsetAligner` snaps
  word STARTS to vocals-stem energy-flux onsets within flat 0.15 s
  (AudioFileAnalysisService.swift:904-947); ends never re-anchored → inconsistent durations.
  Detector is the generic `InstrumentOnsetDetector` — misses soft/fricative onsets. Fix: snap
  ends to next onset/voiced edge; vocal-band flux; tempo-scaled tolerance.
- **W7. De-pad magic numbers.** >5 s span → collapse to exactly 1 s anchored at end
  (Transcription.swift:258-261). 2-4 s paddings (common after fills) slip through; true duration
  discarded though VAD knows it. Fix: VAD-aware de-pad, trigger ~2 s.
- **W8. All stem-based refinement is `hasStems`-gated** (AnalysisStage.swift:366) — no-stem
  songs ship raw ASR timings.
- **W9. Blend is whole-row, not word-level.** Accuracy-first with 0.25 corroboration margin
  (LyricBlendRowBuilder.swift:16,271); can't combine best words + best timing; `overrideText`
  rows lose per-word timing entirely (:223-234, falls back to line interpolation).
- **W10. Repetition-filter middle-excision hole.** Safety valve inspects only the dropped TAIL
  (WhisperCPPTranscriptionEngine.swift:215-232); a `[cutoffTime, resumeTime]` middle cut is
  never diversity-checked.
- **Cross-cutting:** ~15 hardcoded absolute-seconds thresholds (0.15/0.18/1.5/2/3/5/8 s) should
  derive from tempo/beat length (`beatTimes` already available).

## Area 3 — Instrumental structure over-segmentation

**Structure is 100% lyric-driven.** `LyricSectionDeriver.sections`
(ChordProDraftBuilder.swift:1030-1106) emits instrumental markers ONLY at ≥4-bar gaps between
lyric lines. Two distinct symptoms:

- **True over-segmentation of Form** happens when spurious ASR fragments land inside a break:
  each fragment spawns Instrumental→"vocal"→Instrumental alternation.
- **"One part per chord"** is the flat chord-signature list: `buildInstrumentalSummaries`
  (SongStructureOverview.swift:347-368) collapses only *consecutive* duplicate numerals
  (:376-381), so a 4-chord loop ×5 prints ~19 symbols (todo.md §C verbatim). Chart side:
  `chordOnlyLine` gives each change its own bar cell.

None of the landed fixes (gap-fragment merge, chord-majority representative, Jaccard phrase
clustering) touch instrumental spans — verse-kind-only / worded-kinds-only / requires lyric
lines respectively. Unused signals already in the codebase: MeasureGrid+DownbeatEstimator bar
grid (threaded into the builder but only for row sizing), `signaturesMatch` Jaccard,
`ChromaChangePointDetector` (QA-only).

Fix directions (F1-F5, detail in audit):
- **F1** loop-cycle collapse in `buildInstrumentalSummaries` → "I-V-vi-IV ×3" display.
- **F2** 4/8-bar phrase cells from the existing MeasureGrid; group identical cells.
- **F3** windowed `signaturesMatch` within a span → "solo = verse loop ×4"; feeds
  reclassifyBridgeAndSolo. (Jaccard is order-blind — may need sequence comparison.)
- **F4** min part length + display-cap on chord symbols (cheap guard).
- **F5** suppress onset-uncorroborated ASR fragments inside large gaps (fixes Form
  alternation). Anchor: bodyLyrics filter SongStructureOverview.swift:216-219.

NOTE: F1-F4 are mitigations; W1 (chord density) is the upstream cause of the noise they manage.

## Rendering — remaining decisions

- **Width unification (purple vs yellow):** either (a) drop the lyric text floor so both rows
  are pure `duration × 100 px/s` (glyphs may collide on dense lines — needs collision handling
  or font scaling), or (b) keep the floor but apply the SAME floor logic to instrumental rows
  (width = max(time, content)) so equal durations render comparably. (b) is lower risk; (a) is
  the honest single-time-axis answer Eric asked for.
- Outro `lineDuration = 0` fallback fix (see above) — small, do with either option.

## Proposed priority order

1. **W1 downbeat-aware switch penalty** — deepest lever; fixes Task #46, chorus phrase
   clustering, and instrumental chord noise at the source. Verify against cached Analysis JSON
   of reference songs before/after (stage-tag bump).
2. **F5 + F1/F2** — instrumental structure grouping (F5 fixes Form fragmentation; F1/F2 fix
   the per-chord display even before W1 lands).
3. **W2 93 ms centering bias + W4 determinism** — small, mechanical, high-precision payoff;
   both need cache-version bumps.
4. **Width unification decision + outro fallback** — rendering truthfulness.
5. **W6/W7 word-end snapping + VAD de-pad** — lyric timeline precision.
6. **W3/W5, W8-W10** — larger scope, schedule separately.
