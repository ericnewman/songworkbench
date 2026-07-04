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

---

# ChordPro preview fixes + Lyric Blending feature (2026-06-27)

## Phase 1 — ChordPro App Preview fixes (do first, one build/verify batch)
- [ ] A. Reset button sits too far from slider -> place it adjacent to the slider (before the ms readout).
- [ ] B. First chords overlap in rhythmic mode -> de-collide rhythmic chord x positions (push each chord >= prev chord width to the right).
- [ ] C. Bouncing ball hidden in rhythmic mode -> render ball over rhythmic word x positions (user wants it shown).
- [ ] D. Word highlight drifts vs sung time -> make highlight lead rate-aware (0.45s / tempoRate); the fixed lead is wrong at non-1.0x speed. (Word-level ASR bias is a separate, larger effort.)
- [ ] E. Accuracy (Whisper) duplicates lyric lines -> drop adjacent duplicate Whisper segments (same normalized text + overlapping/adjacent timespan) in WhisperCPPTranscriptionEngine before grouping.
- [ ] F. Outro/instrumental (chord-only) lines have no beat dots -> beat dots are keyed to lyric lines only; extend to chord-only lines via their time window (feasibility-check; may defer).
- [ ] Verify: Clean Build Folder + Run (external edits need clean build), screenshot each fix.

## Phase 2 — Lyric Blending feature
- Drop the Fast/Balanced/Accuracy quality picker; always run all 3 modes.
- On analysis complete, open a new "Lyric Blend" window (openWindow id) for the selected song.
- Rows = time windows across the song (model-agnostic). Per row, stack the 3 models'
  text for that window in 3 distinct colors, with a blank gap before the next row.
- User picks the best candidate per row; blended selection persists as official lyrics.
- Open question: with run-all-3, do we still expose any per-model settings (see G)?

## G. Model-settings question (answer)
- Recommendation: do NOT expose raw Parakeet/Whisper params; with run-all-3 + blend, the blend IS the tuning.
- High-value optional knobs worth exposing instead: timing lead (per song), silence sensitivity, confidence threshold, reference lyrics (already exists).

## G2 — Lyrics start at 0:00 over an instrumental intro (timeline misalignment)
- Symptom: first lyric line timestamped at song start though vocals enter several measures in.
- Likely: Whisper first-word-after-silence padding bias (de-padding may not be catching it),
  or first segment start pinned to 0. Investigate de-padding thresholds + segment start handling.
- Root-cause pass needed before fixing (don't guess).

## Batch status (2026-06-27, code complete, pending visual verify)
- A done+verified. B (snap-to-beat + de-overlap) code done. C (ball in rhythmic) code done.
- E (Whisper overlapping-dup dedup) code done. F (beat dots on chord-only lines) code done.
- D deferred. G2 + drum-track beats = follow-ups.

## G2 review (done 2026-06-27)
- Root cause: Whisper places/hallucinates lyric words during a silent instrumental intro; grouper
  de-padding only fixes a SINGLE >5s token, so a multi-word intro line keeps start≈0.
- Fix: VocalOnsetDetector (energy onset on isolated vocals stem) in AudioFileAnalysisService.swift;
  TranscriptionStage drops tokens before the onset (hasStems only, best-effort, never empties).
  Grouping tag bumped grouping-10 -> grouping-11-vocal-onset so re-analysis re-groups from cache.
- Tests: 3 in AudioAnalysisTests.swift (onset after intro, nil when immediate, nil degenerate).
- Compiles (Xcode Build succeeded). NOT yet runtime-verified — re-run Accuracy on the intro song.
- Existing songs keep wrong lyrics until re-analyzed.

---

# Lyrics/chords accuracy review (2026-06-29)

## Plan
- [x] H1: Wire `VocalOnsetDetector` + `TranscriptionOnsetCorrection` (reanchor + drop pre-onset tokens) before grouping; bump grouping tag to `grouping-27-vocal-onset-strict-vad`.
- [x] H2: Whisper segment `no_speech_prob` + average token logprob filter (~0.6 / -1.0); optional locale→language hint for whisper.cpp.
- [x] H3: Repetition-filter safety valve (revert to raw when retained span < 50% duration); whisper engine version bumped to `6`.
- [x] H4: `HarmonyAudioSourceSelector` prefers guitar → piano → accompaniment → other; per-stem `configurationIdentifier` in cache key.
- [x] H5: Run strict VAD on full-mix path when stems absent.
- [x] M1: Unify strict `VocalActivityEnvelope.Configuration.strictVocalPresence` for distribute + hallucination gate.
- [x] Quick wins: `RepeatedPhraseCollapser` minCycles 3→2; `VocalHallucinationGate` padding 0.35→0.15.
- [x] H6: maj7/min7/dom7 templates in `ChordClassifier` + `Chord.displayName`.
- [ ] M7: Default transcription mode → Accuracy (skipped — not requested).

## Review (2026-06-29)
- H1–H6 + M1 + quick wins implemented. Grouping tag `grouping-27-vocal-onset-strict-vad`; whisper engine `6`.
- Tests: `swift test --filter 'AudioAnalysisTests|WhisperCPPTranscriptionEngineTests|HarmonyAudioSourceTests|SongAnalysisPipelineTests'` — all pass except pre-existing `testDrumBeatGridKeepsUniformBeatWhereOnsetIsMissing` flake (unrelated).
- M7 deferred: user asked not to change default transcription mode.
- Runtime verify: re-analyze a song with a long instrumental intro to confirm onset re-anchor; re-analyze harmony on a guitar-forward mix to confirm stem selection.

---

# Trailing lyric hallucinations + full-song timeline (2026-06-29)

## Acceptance criteria
- [x] Trailing ASR hallucinations after the last real vocal offset are dropped (token + line gates).
- [x] `TranscriptionSilenceGate` fences trailing islands using `sourceDuration` (actual audio end).
- [x] Strict VAD for gating/distribution is clipped at the detected vocal offset (bleed blips ignored).
- [x] Lyric/chord timeline spans full song duration (`sourceDuration` persisted + UI `timelineDuration`).
- [x] Real outro vocals before the offset are preserved (regression test).
- [x] Grouping tag bumped to `grouping-28-trailing-vocal-cutoff`.

## Review (2026-06-29)
- Root causes: (1) `TranscriptionSilenceGate` treated `songEnd` as last token end, so trailing outro
  islands were never isolated; (2) intro had `VocalOnsetDetector` but outro had no symmetric cutoff;
  (3) strict VAD bleed blips after real vocals kept hallucinated lines in `VocalHallucinationGate`;
  (4) ChordPro outro/chord-only windows ended at last chord or last beat, not full audio length.
- Fix: `VocalOffsetDetector`, trailing token drop, clipped strict VAD, `trailingCutoff` on gate,
  `sourceDuration` on document + `ChordProDraftInput`, `BeatDotContext.songDuration`.
- Tuning knobs: `VocalOffsetDetector.Configuration.minOutroSeconds` (0.75),
  `TranscriptionOnsetCorrection` trailing `padding` (0.15), `VocalHallucinationGate.trailingCutoff`
  (vocal offset, no extra padding), `TrailingLyricTailPruner` (`minClusterGap` 2s).
- Tests: `swift test --filter 'AudioAnalysisTests|TranscriptionTests|ChordProDraftBuilderTests'` — all new tests pass; only pre-existing `testDrumBeatGridKeepsUniformBeatWhereOnsetIsMissing` flake fails (unrelated).

---

# Trailing tail pruner + Lyrics section headers (2026-06-29)

## Acceptance criteria
- [x] Remaining 2-line outro hallucinations dropped (segment-level + tail pruner pass).
- [x] Lyrics view shows Intro / Instrumental / Outro / Verse / Chorus section headers.
- [x] Regression tests for 2-line outro scenario and section derivation.
- [x] Grouping tag bumped to `grouping-29-trailing-tail-pruner`.

## Review (2026-06-29)
- Root cause of surviving hallucinations: bleed segments starting at/after vocal offset kept partial
  tokens (token drop only); clipped strict-VAD blips still let overlap-gated lines through; trailing
  cutoff used offset+0.25s padding so lines just past offset survived.
- Fix: drop whole ASR segments at/after offset, tighten token padding to 0.15s, gate at raw offset,
  `TrailingLyricTailPruner` after grouping for isolated tail clusters.
- Section headers: `LyricSectionDeriver` (shared with ChordPro gap logic) wired into
  `TimedLyricsEditor` timestamped + paragraph views.

---

# Vocal level threshold for stem bleed (2026-06-29)

## Acceptance criteria
- [x] Adaptive body-level threshold in `VocalEnergyThreshold` filters sub-threshold instrumental bleed.
- [x] `VocalOnsetDetector`, `VocalOffsetDetector`, and `VocalActivityEnvelope` share level-aware enter threshold.
- [x] Strict VAD / `voicedIntervalsForGating` / offset detector ignore bleed after real singing (~107.7s scenario).
- [x] Quiet vocal tail regression preserved (amplitude ~35% of body still detected).
- [x] Grouping tag bumped to `grouping-30-vocal-level-threshold`.
- [x] Tests in `AudioAnalysisTests` for bleed rejection + quiet tail regression.

## Review (2026-06-29)
- Root cause: relative-only thresholds (noise floor × multiple, peak × fraction) still admit bleed
  once the noise floor drops after vocals end; bleed RMS clears the bar but sits far below typical
  sung level.
- Fix: `VocalEnergyThreshold` adds adaptive floor = 75th-percentile RMS of relative-threshold frames ×
  `vocalBodyFraction` (default 0.30; strict VAD 0.25). Quiet-frame median noise floor avoids inflation
  on vocal-heavy files. Shared via `VocalRMSEnvelope`.
- Tuning knobs: `vocalBodyFraction` on each detector `Configuration` (0.30 default, 0.25 strict VAD),
  plus existing `peakFraction`, `noiseFloorMultiple`, `minOutroSeconds`, `minVoicedSeconds`.
- Tests: `swift test --filter AudioAnalysisTests` — bleed + quiet-tail tests pass.

---

# Tail line-start cutoff for outro hallucinations (2026-06-29)

## Acceptance criteria
- [x] Lines **starting** at/after `vocalOffset` or `lastVoicedEnd` dropped (Summertime "Sunset winks…" scenario).
- [x] Real last line ending at offset kept (starts before cutoff).
- [x] Trailing duplicate identical lines collapsed after tail filter.
- [x] Token drop at raw offset (no +0.15s padding).
- [x] Grouping tag bumped to `grouping-31-tail-start-cutoff`.
- [x] Regression test for 107.76s anchored hallucinations + duplicate tail.

## Review (2026-06-29)
- Root cause: `TrailingLyricTailPruner` used `start < cutoff + 0.08s` (kept lines starting just after
  offset); token drop used `offset + 0.15s` (kept bleed tokens anchored to previous line end); gate
  only checked `segment.start` so lines with offset slightly after anchor survived bleed overlap.
- Fix: line-start cutoff at `vocalOffset` and `lastVoicedEnd` (2ms epsilon), strict token drop at
  offset, `TrailingDuplicateLineCollapser` for repeated tail lines.
- Tests: `swift test --filter AudioAnalysisTests` — new Summertime + duplicate + token tests pass.

---

# Vocal tail cutoff fallback (2026-06-29)

## Acceptance criteria
- [x] Summertime "Sunset winks…" hallucinations dropped when `VocalOffsetDetector` returns `nil` (bleed to file end).
- [x] Same hallucinations dropped when detector anchors on bleed (~109.5s) instead of body end (~107.76s).
- [x] `VocalTailCutoffResolver` infers body end from strict-VAD trailing blip + min with detector offset.
- [x] `TrailingLyricTailPruner` lyric-body fallback when song continues instrumentally after last real line.
- [x] Grouping tag bumped to `grouping-32-vocal-tail-cutoff-fallback`.
- [x] Regression tests for nil offset, late offset, and resolver min().

## Review (2026-06-29)
- Root cause (production): grouping-31 tests assumed `vocalOffset ≈ 107.7`, but on Summertime the
  detector often returns `nil` (bleed keeps RMS above threshold until EOF — no sustained silence) or
  a **late** offset on the bleed blip (~109.5s after a short silent outro). With cutoff ≥ 109.5,
  lines at 107.76/109.36 overlap clipped/unclipped strict-VAD bleed and survive all tail gates.
  Re-analyze did re-run post-processing (no stage skip); persisted lyrics were not the issue.
- Not root cause: reference-lyrics bypass (only outputs reference lines), UI reading a different
  source (`model.lyricSegments` from persisted document), grouping-31 cache tag (transcription stage
  always re-groups when re-analyzed).
- Fix: `VocalTailCutoffResolver` takes `min(detector, strict-VAD body end)`; strict VAD computed once
  and reused; `TrailingLyricTailPruner` adds lyric-body end fallback from `sourceDuration`.
- Verify UI: Re-analyze Summertime → last lyric "And under the stars it feels so right" ending
  ~107.76s; no "Sunset winks…" lines. Stage record should show `grouping-32-vocal-tail-cutoff-fallback`.
- Tests: `swift test --filter AudioAnalysisTests` — Summertime nil/late offset + resolver tests pass.

---

# Tail earlier-lyric repeater + section labels (2026-06-29)

## Acceptance criteria
- [x] Single tail ASR repeat of an earlier lyric line (Summertime "Sunset winks…" at ~107.76s) dropped.
- [x] `TrailingEarlierLyricRepeater` cross-timeline duplicate filter after tail pruner/collapser.
- [x] `LyricSectionDeriver` / ChordPro: no Verse/Chorus labels after inferred body end; Outro from last real line.
- [x] `lyricBodyEndBeforeInstrumentalTail` requires tail cluster within 2s of body line (no false cut on verse→chorus gaps).
- [x] Grouping tag bumped to `grouping-33-trailing-earlier-repeater`.
- [x] Regression: intentional double chorus before cutoff preserved.

## Review (2026-06-29)
- Root cause A: `TrailingDuplicateLineCollapser` only drops *consecutive* identical tail lines. When ONE
  hallucinated line survives (107.76–109.36) and its text matches an *earlier* chorus line (~40s), nothing
  removed it — not a new invention, an ASR repeat during bleed.
- Root cause B: `SongStructureAnalyzer` matched the tail repeat to the earlier chorus → spurious "Chorus"
  header; Outro anchored on tail hallucination end instead of last real body line.
- Fix: `TrailingEarlierLyricRepeater` drops tail-window lines whose normalized text appears earlier;
  section deriver/ChordPro infer body end and exclude post-cutoff lines from verse/chorus labeling.
- Verify UI: Re-analyze Summertime → last lyric "And under the stars it feels so right" ~107.76s;
  no "Sunset winks…"; section headers show Outro (not Chorus) after last lyric.
  Stage record: `grouping-33-trailing-earlier-repeater`.
- Tests: targeted AudioAnalysis + ChordProDraftBuilder section tests pass.

---

# Lyric line highlight lag (2026-06-29)

## Acceptance criteria
- [x] Active lyric line is a pure function of playhead time (`[start, end)` containment).
- [x] Overlapping segments resolve to the latest-starting match; past last end keeps last line lit.
- [x] TimedLyricsEditor refreshes highlight on every playhead tick (no scroll animation fighting).
- [x] Playback services publish time at 60 Hz without async timer hop.
- [x] Unit tests for playhead → segment index.

## Review (2026-06-29)
- Root cause: `TimedLyricsEditor` used a "latest started + cap at next start" heuristic instead of
  direct `[start, end)` lookup, so highlight could trail when segment ends were short or gaps were
  capped early; SwiftUI List row backgrounds did not always refresh because playhead lived only on
  child `ObservableObject`s; 30 Hz playhead publisher added visible delay.
- Fix: shared `ChordProHighlightDeriver.activeSegmentIndex(at:in:)`; `playheadTime` state synced from
  active playback service; scroll without animation; playhead timer raised to 60 Hz.
- Tests: `swift test --filter ChordProHighlightDeriverTests` — all pass.
- Manual verify: play/scrub a song with timed lyrics — highlight should track the waveform playhead.

---

# Lyric highlight lag + instrumental gaps (2026-06-29)

## Acceptance criteria
- [x] Highlight at exact `line.start` (zero offset vs playhead).
- [x] During instrumental gap between lines, previous line stays highlighted (karaoke hold).
- [x] Intro section header highlighted before first sung line.
- [x] Playhead timer updates synchronously on main thread (no `Task` hop).
- [x] `TimedLyricsEditor` reads `lyricHighlightTime` (= waveform clock), not stale `@State`.

## Review (2026-06-29)
- Root cause (~5s lag): `TimedLyricsEditor` cached playhead in `@State` updated only via `.onChange`,
  which could fall behind `@ObservedObject` playback ticks under load; playback timers still wrapped
  `updateCurrentTime` in `Task { @MainActor }`, queueing ticks and letting `currentTime` drift behind
  audible output. Highlight also wasn't sharing a single clock with the waveform.
- Fix: `model.lyricHighlightTime` aliases `activePlaybackTime`; removed `@State playheadTime`; timer
  callbacks call `updateCurrentTime` / `updatePlaybackMeters` directly; scroll uses
  `disablesAnimations`.
- Instrumental UX: `activeSegmentIndex` default spans `[start, nextLine.start)` (hold previous line);
  strict `[start, end)` kept via `holdThroughGaps: false` for bouncing-ball gap detection; intro
  section header highlights via `activeInstrumentalSection` when no lyric is active.
- Tests: `swift test --filter ChordProHighlightDeriverTests` — all pass.

# Vocal-energy alignment (ChordPro preview) — 2026-07-01

## Done & verified
- [x] Q1: instrumental/chord-only line strips are time-scaled (pixelsPerSecond) so a 5-bar
  interlude reads wider than a 4s verse line. WorkspaceEditorsView: isInstrumentalLine,
  instrumentalTimeWidth, monospaceChordX; stripWidth/monospaceContent/beatDotPositions use it.
  Verified live on "Summertime's her with you".

## Planned (approved: upstream / persisted)
- [ ] Q2: per-word onset snapping. The pipeline ALREADY aligns words to voiced signal via
  VocalAlignmentCorrector.distributeAcrossSignal (AudioFileAnalysisService.swift:907). Add a
  precise pass on top: detect vocal onsets with InstrumentOnsetDetector.onsets(url: vocalsStem)
  and snap each word.start to the nearest onset (tolerance ~0.15-0.2s), nondecreasing, start<end,
  update segment.start. New enum VocalWordOnsetAligner modeled on ChordOnsetAligner.snap. Wire into
  AnalysisStage transcription stage AFTER distributeAcrossSignal (both ASR + reference paths).
  Unit tests. Re-analyze Summertime to apply; verify words+strip sit on energy bursts.
- [ ] Q3: bouncing ball bottoms on vocal peaks. Change ball cadence from the beat grid to the
  (now energy-accurate) word onset times so each bounce-bottom lands on a vocal peak. Lives in the
  ball position logic (WorkspaceEditorsView rhythmicBallPosition/ballPosition + BouncingBall in
  ChordProPreviewDocument.swift). Verify live.

## Note / caution
This touches the most heavily-tuned code path (word↔vocal alignment: distributeAcrossSignal, VAD,
VocalHallucinationGate, onset detectors — many prior fixes in memory). Implement as a focused,
test-backed pass with a Summertime re-analysis to verify, not a rushed change.

# Fixed measure grid — restore repeating cadence (ChordPro preview) — 2026-07-01

## Problem (data-verified, "She thinks I'm a millionaire", bpm 105.47, beat 0.569s)
- Vocal-line first-word onsets cluster at beat 3 (pickup) and beat 0 (downbeat):
  histogram {0:13, 1:5, 2:5, 3:13}, mean 3.61b — a strong repeating anacrusis cadence.
- Current view loses it: (a) each line has its OWN local time axis (words stretched to fill
  row width via rhythmicWordXs' `max(desired,cursor)` clamp) so a beat = different px per row;
  (b) leadingIndent = (onset mod one bar) x pxPerSec off an arbitrary phase (beatTimes.first),
  so a 3.9b pickup looks hugely indented while the downbeat 0.1b later snaps flush-left — same
  cadence, scattered indents.

## Approach (user-approved: option 1 + 3 = fixed grid aligned to true downbeat)
1. MeasureGrid helper (new, pure, unit-tested): given beatTimes+bpm+barPhase, map time->(bar,
   beatInBar), nearestDownbeat(time), downbeatTime(barIndex). No new model download.
2. Downbeat phase detection (new, pure, unit-tested): pick barPhase in {0,1,2,3} that best aligns
   vocal-line onsets to the grid (min circular variance of (onset mapped to beat-in-bar), favoring
   mass at beat 0 & pickup beat 3). Feed vocal onsets already computed in AnalysisStage. Persist on
   BeatEstimate (add `barPhase: Int` + `downbeatTimes: [TimeInterval]`, Codable; bump grouping/beat
   version tag so cached songs re-derive).
3. Layout rewrite (WorkspaceEditorsView ChordProPreviewLineView): replace per-line
   leadingIndent+rhythmicWordXs scale with ONE shared mapping x(t) = gutter + (t - rowDownbeat) *
   pxPerBeat/beatLen, constant pxPerBeat across ALL rows. rowDownbeat = grid downbeat the line
   resolves to; gutter = one bar so pickups render to the left of the shared downbeat column.
   Keep a light local overlap-nudge only for crowded syllables (does not move the row's downbeat
   anchor), so readability holds without breaking vertical beat alignment.
4. beat dots + NEW barlines drawn at the fixed shared columns; strip/chords/ball reuse x(t) so they
   stay consistent for free.

## Key tradeoff to confirm
Fixed pixels-per-beat means dense/fast syllables can crowd. Plan: keep pxPerBeat generous (~57px)
and apply a local right-nudge ONLY within a bar cluster, never moving downbeat anchors. Alternative
(rejected unless requested): full metric reflow where lyrics wrap at bar boundaries (breaks
one-row-per-lyric-line readability).

## Verify before done
- Unit tests: MeasureGrid mapping, downbeat-phase picker (synthetic + the real onset set).
- Rebuild .app (xcodebuild, not swift build) + relaunch; re-analyze the song to apply new tag.
- Live: confirm downbeat columns align vertically across verse rows and the pickup cadence renders
  identically line-to-line. Diff against current screenshots.

## Added 2026-07-01: trailing melody fill (user: "no melodic parts at the END of lines")
- Only leadingMelodyFill (pre-vocal gap) was ever built; the symmetric trailing fill from the
  user's original ask ("same is true at the end of a line") was never implemented.
- Fold into the grid rewrite: on the shared x(t) axis, draw melody-stem peaks in BOTH gaps —
  leading [rowStart..firstWord] and trailing [lastWordEnd..rowEnd/nextDownbeat] — same melody
  lane color. Trailing bounded so it can't overrun the NEXT line's first word.

## Review (2026-07-01) — fixed measure grid DONE
- New MeasureGrid.swift (MeasureGrid + DownbeatEstimator), 9 unit tests PASS (incl. realistic
  "She thinks" cadence → barPhase 0). Derived in-view from beatTimes + word onsets (NO BeatEstimate
  schema change, NO re-analysis needed — simpler than the planned persistence).
- WorkspaceEditorsView: rhythmicWordXs now places words at metricX(t)=gutterPx+(t-rowDownbeat)*pps,
  constant px/sec; downbeat pinned to gutterPx column on every row; local nudge only. Beat dots +
  faint barlines drawn at pure-metric columns. Leading AND trailing melody fill on the shared axis.
- Numerical proof on real data: downbeat column constant 114px across all verse rows; OLD mod-bar
  indent scattered 22-222px for the same pickup cadence. swift build + xcodebuild + app relaunch OK.
- LIVE VIEW: blocked this session — the computer-use input env only registers menu-bar clicks;
  in-window clicks/keys collapse or hit the wrong control, so I could not select the rhythmic song
  on screen. Verified by tests + numerics instead. User to eyeball "She thinks I'm a millionaire"
  → ChordPro. (Accidentally nudged Timing/Transpose on "Theres a place in my heart" — hit Reset.)

# Phrase-structure lyric grouping — 2026-07-01 (approved)
User signals: (1) verse lines have similar word/syllable counts; (2) lines often end on a rhyme;
(3) there's usually a repeating musical phrase (bars/chords) behind verse lines.

## Approach — post-pass over the beat/chord grid (keeps the tested lexical grouper intact)
New LyricPhraseGrouper.swift (pure, tested), applied in AppModel.applyAnalysis AFTER regroup when
beats+chords exist; falls back to current grouping when no reliable musical period.
- Stage 1 (foundation, this pass): detect the repeating PHRASE PERIOD in bars from per-bar chord
  labels (autocorrelation over {2,4,8}, default 4). Lay phrase boundaries at section downbeat +
  k*period*barSeconds (via MeasureGrid). Re-segment each section's words into one line per phrase
  cell, breaking at the word gap nearest each boundary → musically-aligned, consistent-length lines.
- Stage 2 (refinement, next): score/adjust candidate breaks by rhyme at line ends + syllable-count
  similarity to sibling lines; nudge a boundary to the local best break within ±~1 beat.
- Guard: only re-segment sections with a confident period + enough bars; never cross section
  headers; bound line length by existing caps.

## Verify
- Unit tests: period autocorrelation (synthetic ABAB / AABB chord bars), re-segmentation at
  boundaries, fallback on no-period.
- Re-analyze the song on ACCURACY (user chose) for clean words, then eyeball verse lines: even
  length, aligned to bars. Bump grouping version tag.

---

# Reconstruction-accuracy audit + refinement plan — 2026-07-01

Goal: ChordPro accurate enough to reconstruct the original song. Reference case:
"Summertime's her with you (Edit)" (158.7s, 112.35 BPM, est. key Db/C# major,
117 chord events, 24 lyric lines, 295 beats, all states draft).

## Audit findings (numeric, from persisted document + generated chart)

### Chord accuracy — the dominant error source
- 33/117 chord events (28%) are non-diatonic to the estimated Db-major key
  (E, Eb, D, Dm, F, Bb, Cm, Gm, Em) — implausible for this song; almost all noise.
- 26/116 events last < 1 beat despite two-beat voting — sub-beat flicker survives.
- Chorus self-consistency ~40%: the identically-sung choruses get materially
  different progressions (c1: Ab C# Ab F# Cm... vs c2: Fm C# F# Ab Eb...).
  Same melody must yield the same chords.
- Confidences span only 0.53–0.84; the 0.5 threshold filters almost nothing.

### Lyric accuracy — minor
- ASR text mostly clean; suspect line "Toes curl up like a secret's toe" (72.9s);
  minor line-boundary overlaps (~0.1s). referenceLyrics is empty for this song —
  for ORIGINAL songs the writer has ground-truth lyrics; the existing
  ReferenceLyricAligner path is the highest-accuracy route and should be the
  canonical-chart default.

### Arrangement detail — structural information loss in ChordProDraftBuilder
(Full inventory from code audit of ChordProDraftBuilder.swift + input types.)
- Never emits {key} (estimatedKey isn't even in ChordProDraftInput), {time}, {capo}.
- Chord-only lines are proportional-space strings with a single "N bars" comment;
  no bar boundaries → a reader cannot map chords to measures.
- Chord durations, beat/bar alignment, and sub-measure timing are all quantized
  away to character offsets; stacked artifacts like [Eb][E][C#][Ab][F][Bb]Word
  come from rapid noise events all snapping to the same word anchor.
- Sections are {comment}s, not {start_of_verse}/{start_of_chorus} directives;
  repeats not identified; bassNotes never used in the standard draft.

## Refinement plan (proposed order)

### A. Chord-timeline accuracy (do first — everything downstream inherits it)
- [ ] A1 Key-aware decoding: pass estimatedKey into chord selection; penalize
      non-diatonic labels unless evidence is strong (allow common borrowed chords).
      Target: non-diatonic rate 28% → <10% on Summertime.
- [ ] A2 Minimum-duration enforcement: investigate why sub-beat events survive
      two-beat voting; merge events < 1 beat into neighbors by evidence.
      Target: <1-beat events 26 → ~0.
- [ ] A3 Repeated-section consensus: sections with matching lyrics (chorus
      detection already exists) vote on ONE shared progression, applied to all
      instances. Target: chorus agreement 40% → >90%.
- [ ] A4 Bass-root fusion: constrain bar-root choices with persisted bassNotes
      (per lessons.md: bass stem owns roots).

### B. ChordPro arrangement fidelity (reconstruction)
- [ ] B1 Emit {key}, {time} (4/4 explicit), tempo already present.
- [ ] B2 Bar-aligned chord-only lines: `| C# | F# . | Ab | C# |` style with real
      barlines derived from MeasureGrid + DownbeatEstimator (already built);
      bar count must equal the section comment.
- [ ] B3 Beat-anchored chord placement in lyric lines (MeasureGrid), replacing
      pure character-proportional anchoring; kill stacked-chord artifacts at
      source (A2 helps) and de-collide the rest.
- [ ] B4 Proper section directives {start_of_verse N}/{start_of_chorus} (+ keep
      human comments); mark detected repeats (identical section → "Repeat chorus").
- [ ] B5 Round-trip carrier for timing the ChordPro spec can't hold: x_ custom
      directives (e.g. {x_section_start: 24.56}, per-bar chord map) that the app
      writes and can re-import losslessly; foreign parsers ignore them.

### C. Lyric canonicalization
- [ ] C1 Reference-lyrics-first workflow for original songs: prompt/surface the
      paste-reference step before a chart is considered reviewable.

### Verification (definition of done per phase)
- Golden metrics on Summertime (scripted, repeatable): non-diatonic %, sub-beat
  event count, chorus-agreement %, chart bar-count consistency.
- Round-trip test: parse the generated chart → rebuild per-bar chord map →
  compare against the persisted chord timeline within one beat tolerance.
- Unit tests per change + swift test; re-analyze Summertime in-app to verify live.

## Review — A1+A2 done (2026-07-01)
- Plain per-window rescoring (first A1 attempt) was measured INSUFFICIENT on the real
  cached frames (28%→24% non-diatonic only). Replaced with `ChordTimelineDecoder`:
  Viterbi over per-beat windows; emissions = confidence-summed labels scaled by
  `KeyPriorChordRescorer` (dia 1.0 / borrowed 0.75 / chromatic 0.5; parallel minor
  of tonic demoted to chromatic — one-chroma-bin confusion of the tonic); switch
  penalty 2.5; explicit no-chord state (floor 0.5) absorbs weak windows; empty
  windows are uninformative (do NOT punish sustaining). Falls back to
  ChordEventReducer when no beat grid. `ChordEventDurationFilter` (0.8 beat min,
  merge into previous, collapse duplicates) runs LAST, after bass refine + onset
  snap, on the drum-locked grid.
- Offline validation on Summertime's cached frames (cache 28136d82b525…):
  old voting 117 events / 28% non-diatonic / 26 sub-beat / 31% chorus agreement →
  Viterbi+prior ~58 / ~12% / ~4 / 67%; +chorus consensus sim (A3 preview) 56 /
  11% / 2 / 100%.
- Harmony stage record tag bumped: reduce-5-per-beat-chords → reduce-7-viterbi-key-prior
  (re-reduces from cached chroma; no re-separation).
- Tests: ChordTimelineDecoderTests (6) + KeyAwareChordFilteringTests (13) pass;
  pipeline/key/audio suites pass. AppModelTests import failures are PRE-EXISTING
  (uncommitted WIP in tree; proven by removing my changes — see lessons.md).
- Tuist regenerate + xcodebuild compile check OK (signing skipped in CLI).
- NEXT: user re-analyzes Summertime in-app (harmony re-runs from cache), then
  re-run metrics on projects.json. Then A3 (consensus in ChordPro stage,
  event-level, lyric-matched sections) and B-phase chart fidelity.

## Review — cascading-indent + missing-verse-chords fixes (2026-07-01, user-reported)
User saw (ChordPro preview, Summertime, after re-analysis with reduce-7):
(1) verse rows 4-6 cascade rightward, row 7 snaps left; (2) no melody strip in
rows 5-6's leading space; (3) NO chord symbols in verse 1; (4) row 4's leading
strip shows intro material that isn't part of the verse.
Root causes (data-verified):
- (1) Lines are spaced ~2.7s = exactly FIVE 0.534s beats; drum comb fit confirms
  the 112.35 tactus is real, so the song phrases in 5-beat units while the view
  hard-coded beatsPerBar=4 → each line lands +1 beat-in-bar (phases 3.86, 0.88,
  1.95, 3.01; R=0.22). With 5-beat bars R doubles and lines align.
  FIX: DownbeatEstimator.estimateBeatsPerBar (phrase-period scoring of line-onset
  spacings vs candidate bar lengths {3,4,5,6}, conservative 4 default + margin),
  wired into WorkspaceEditorsView.beatsPerBar. 4 unit tests incl. real onsets.
- (2) NOT a bug: lines are contiguous (prev vocal runs to each line start), so
  there is no unheard melody; blank was metric offset only, disappears with (1).
- (3) New sparser decoder timeline holds one chord (C#→D transposed) across the
  whole verse; chart marks CHANGES only, and the change happened in the intro.
  FIX: ChordProDraftBuilder restates the active sustained chord at each section
  start (index 0, ≥4-bar gap, or labeled section) unless the line already opens
  with a chord within 0.5s. 2 unit tests. Draft rebuilds on next analysis/retry.
- (4) Leading melody fill reached gutterSeconds back into the intro whose audio
  the intro rows already draw. FIX: suppress leading fill when the pre-vocal gap
  ≥ 4 bars (same threshold as Intro/Instrumental rows).
Verify: swift test MeasureGrid+ChordProDraftBuilder PASS; xcodebuild Debug PASS.
User must relaunch the app to see (1)(2)(4); re-run analysis to regenerate the
draft for (3).

## Review — A4 done: frame-level bass re-rooting (2026-07-01)
Author confirmed verse changes MID-LINE → penalty 2.5 was over-smoothing, but
the root cause was deeper: in the verse's Ab passage the classifier emits Cm/C
on EVERY frame (Ab root quiet in chroma; C+Eb dominate) — Ab never appears as a
label, so no re-weighting can recover it, and the decoder rode C# through 3s of
real Ab. The persisted BASS LINE is ground truth here (C#@24.4 F@26.6 F#@27.3
Ab@29.5→32.3 F#@33.0 C#@35.8 = the actual verse progression).
- FIX: `BassInformedChordRefiner.refineObservations` — the ≥2-shared-tones
  re-rooting moved to the FRAME level, applied inside `ChordTimelineDecoder`
  BEFORE windowing/voting (sustained bass: last onset ≤ t within 4s, conf
  ≥0.25 via existing bassPitchClass). Event-level refine kept downstream.
- switchPenalty 2.5 → 2.0. Sim on real frames: verse now decodes
  C#…Ab(29.6) F#(32.8) C#(35.4) — matches bass ground truth; global n=77,
  nonDia 17%, chorus 67%. Stage tag reduce-8-bass-frame-reroot.
- triad() third fixed for minor7 (was mapping major7/dom7 wrong is fine, minor7
  previously OK; now explicit: minor/minor7 → 3, else 4).
- Tests: testBassRerootRecoversChordMaskedByChromaConfusion + all chord suites
  PASS; xcodebuild Debug PASS. Sim scripts: outputs/summertime_frames.json.
- Remaining known miss: early F#@27.3 (1-beat change, evidence 1.48 vs C# 2.79
  neighbours) — A3 chorus/section consensus + possible per-line pass later.

## Review — F#@27.3 recovered: seventh-chord re-rooting (2026-07-01)
Root cause: bass holds F# 27.28→29.49 (not 1 beat) while chroma reads C# — the
FIFTH of F#. C# triad shares only 1 tone with the F# triad, so ≥2-shared-tones
re-rooting skipped it; but it shares 2 tones (C#+E#) with F#maj7 — the actual
upper-structure sound.
- `refineObservations`: candidates extended to [major, minor, major7, dominant7]
  (plain triads first so Cm→Ab stays Ab); bass notes filtered to conf ≥0.35
  (persisted bassNotes include conf-0 junk); `tones()` adds the seventh.
- `ChordTimelineDecoder.mergeSameRootExtensions`: adjacent same-root events that
  differ only by a seventh extension (F# / F#maj7) merge into the plain triad —
  upper voices moving over one sustained chord, not a change.
- Sim on real frames (pen 2.0): verse = C#, F#maj7@27.4, Ab@29.6, F#@32.8 —
  matches the bass ground truth; chorus agreement 67%→80%, nonDia 17%→11%.
- Stage tag reduce-9-seventh-reroot. 3 new decoder tests; all suites + xcodebuild
  Debug PASS. User: re-run analysis to apply.

## Review — adaptive row anchoring (2026-07-01, "left sides all over the place")
After re-analysis the verse-2 rows still scattered. Data: verse-2 line spacings
are 4.7/5.2/5.5/6.2/8.2 beats (verse 1 was a tight 5.0) and first-word onsets
sit ANYWHERE relative to the beat grid — beat-alignment score R = -0.09
(deviation from nearest beat spread across the full ±0.5-beat range). The
performance is loose/rubato; metric downbeat anchoring renders that honestly
as scattered indents, which reads as chaos.
- FIX: `DownbeatEstimator.beatAlignment(beatTimes:onsets:)` = circular mean of
  cos(2π·distance-to-nearest-beat). WorkspaceEditorsView: alignment ≥ 0.3 →
  metric downbeat anchor (tight songs keep the verified cadence rendering,
  e.g. She thinks I'm a millionaire); below → rows anchor on their FIRST WORD
  (uniform left margin), and barlines are suppressed (row origin is not a
  downbeat). Beat dots keep true times.
- 3 new MeasureGrid tests; xcodebuild Debug PASS. User relaunches app to see.
- NOTE: this is presentation-level. The underlying loose timing is real; if the
  user wants beat-aligned indents on loose songs, that would need onset
  quantization upstream (not planned).

## Review — Oceans gap + missing verse chords + beat-ball rework (2026-07-01)
1. "Oceans" false 2.4s intra-line gap: vocals stem proves real singing starts
   61.8s; ASR pinned the word at 59.54 on a half-level bleed blip. FIX:
   `StrandedLeadingWordRepairer` (small leading cluster + ≥1s mostly-UNVOICED
   gap → translate forward to abut the body; voiced gap = held note, untouched).
   Wired after the tail gates, both ASR and reference paths. Tag
   grouping-38-stranded-lead-repair. 3 tests.
2. "Chords not detected": Swift timeline lost the verse-opening C# (21-29.6s
   all F#). Reproduced offline: the real bass C#@24.38 has conf 0.27, fell under
   the 0.35 filter, so the stale F#@22.64 sustained 4s into the verse and
   frame-re-rooted every C# to F#maj7; the same-root merge then swallowed it.
   FIX: low-confidence bass onsets now TERMINATE the previous note's sustain
   without asserting pitch (no re-root there — chroma wins). Tag
   reduce-10-bass-sustain-boundary.
3. Bouncing ball (user-chosen model): the ball now lands ON THE BEAT everywhere.
   Rhythmic lyric rows: bounce bottoms at beats, x = metricX(beat) (same fixed
   columns as beat dots) — replaces word-onset bounce. Instrumental rows: beats
   at time-proportional x across instrumentalTimeWidth (was stale character
   columns that no longer matched the time-scaled render).
All suites + xcodebuild Debug PASS. User: relaunch + re-analyze to apply 1+2.

---

# SongTimeline consolidation — audit + full plan (2026-07-01, AWAITING APPROVAL)

User called whack-a-mole; full audit in `tasks/audit-ball-timing.md`, implementation
spec in `tasks/spec-songtimeline.md`. Root causes (all data-verified on Summertime):
RC-1 playback clock divides bus-rate sampleTime by FILE rate (48k mp3 → progressive
drift); RC-2 waiting ball gets ONE chord-only row + whole-gap window (multi-row intro
broken); RC-3 melisma words get tiny ASR spans → phantom mid-line pauses (line 8);
RC-4 sub-4-bar real breaks invisible + ASR-missed vocal regions mislabeled Instrumental.

## Plan (per spec — do not start until Eric approves)
- [ ] Phase 0: PlayerClock fix (sampleTime/playerTime.sampleRate) in both services +
      connect player with file format; unit + 60s live drift check.
- [ ] Phase 1: VocalWordSpanNormalizer (melisma bridge + late-onset pullback) before
      grouping; tag grouping-39-word-span-normalizer; golden re-analysis of Summertime.
- [ ] Phase 2: UntranscribedVocalRegionDetector; persist regions (additive schema).
- [ ] Phase 3a/b: SongTimelineBuilder + ChordProTextRenderer (string = projection;
      golden byte-compat test).
- [ ] Phase 3c: preview/ball/highlight/dots consume timeline rows; delete
      chordOnlyLineOffset/trailingChordOnlyLineOffset/whole-gap window hack; single
      alignment routine for reviewed/edited charts.
- [ ] Phase 3d: PlaybackClock protocol; view stops picking services.
- [ ] Verify each phase: unit + golden + rebuilt-.app live checks (see spec).

## Open questions for Eric (in spec §Open questions)
rest-marker rendering; unrecognized-vocals row style; keep raw text editor as-is.

## Review (2026-07-01) — Phases 0–3 implemented
- Phase 0 DONE: `PlayerClock` (elapsed = sampleTime / playerTime.sampleRate) used by BOTH
  services; `AudioPlaybackService.load` reconnects player→timePitch→mainMixer at the FILE's
  format (timePitch can't resample across its own seam — an 8 kHz test file made
  engine.start() throw until the full segment ran at file rate; mixer converts to hw).
  3 PlayerClockTests. This also fixed the previously failing
  testPlaybackCompletionClearsPlayingState + testPlaybackSourceSwitchTransfersPosition.
- Phase 1 DONE: `VocalWordSpanNormalizer` (melisma bridge ≥0.4s gap ≥0.8 voiced → extend
  word.end; late-onset pullback ≤0.5 voiced → next.start to voiced re-entry edge, slack
  0.25s) wired LAST in the transcription stage (both ASR + reference paths). Tag bumped
  grouping-38 → grouping-39-word-span-normalizer. 4 tests on the real Summertime seg8 shape.
- Phase 2 DONE: `UntranscribedVocalRegionDetector` (strict-VAD voiced minus padded word
  coverage, ≥1.5s) persisted as `document.untranscribedVocalRegions` (schema 7→8, additive
  decode). 3 tests.
- Phase 3 DONE (core): `SongTimeline` (typed rows w/ authoritative windows);
  `ChordProDraftBuilder.buildResult` emits rows in the SAME pass as text (byte-compat
  proven: 22 golden builder tests unchanged + testBuildAndBuildResultProduceIdenticalSource);
  `AppModel.songTimelineForPreview()` validates by REBUILDING the draft and comparing
  byte-for-byte with chordProSource (edited/reviewed charts → nil → legacy fallback);
  ball follows `timeline.row(at: now)` — multi-row intros tracked row by row (RC-2 dead
  on generated charts); waiting auto-scroll targets display line numbers. 6 SongTimelineTests.
- NOT done (follow-ups): preview rendering for unrecognizedVocals rows + rest markers
  (RC-4 render half — flags/data are persisted and on the rows already); PlaybackClock
  protocol cosmetic unification (3d); deleting the legacy ball heuristics (kept as the
  fallback for user-edited charts).
- Verification: swift test 408 executed / 8 failures — ALL 5 failing tests are the
  documented pre-existing Application-Support store pollution class (lessons.md
  2026-07-01), none in changed code paths; xcodebuild Debug BUILD SUCCEEDED; tuist
  generate re-run for the 4 new files.
- User steps: relaunch the app (Phases 0/3 immediate); re-analyze Summertime to apply
  grouping-39 + untranscribed regions (re-groups from cache, no re-transcription).

## Follow-up (2026-07-02) — instrumental row width + double-phrase lines ("Settle Down")
- Data-verified: line 9 = one ASR segment holding TWO chorus phrases with a 1.72 s pause
  ("down," → "trading", 12 % voiced); seg27 same (1.09 s, 30 % voiced). Chorus 2 splits fine.
- Fix 1: `IntraLinePauseSplitter` — split ASR lines at internal word gaps ≥ 1.0 s that are
  ≤ 50 % voiced with ≥ 4 words per side (recursive; exact text/characterRange slicing).
  ASR path only (reference line breaks are authoritative). Tag →
  grouping-40-intra-line-pause-split. 3 tests + numeric verification against the stem RMS.
- Fix 2: instrumental rows now split to the TYPICAL LYRIC line length: typicalLyricBars
  floor 4→2 bars, row cap 8→16 — intro/outro rows render about as wide as verse rows
  instead of exploding when the time-scaled strip is on. 2 builder tests updated to the
  new intent (intro "[C]" + "[G]" rows; per-row rhythmic spacing preserved).
- User steps: relaunch, then Re-analyze the song (re-groups from cached transcription).

## Follow-up (2026-07-02) — truncated outro vocals ("Settle Down")
- Data-verified: Whisper DID transcribe "I never thought I'd want to hang around."
  (220.8–225.9) and "She makes me want to settle down." (226.8–229.8); the tail cutoff
  resolved to ~220.4 (level-aware offset detector anchored on the last LOUD phrase) and the
  pre-grouping segment drop deleted both REAL lines. Strict VAD hears sustained voice
  221.5–230.1 (the same spans our UntranscribedVocalRegionDetector flagged).
- Fix: `VocalTailCutoffResolver` extends the cutoff through trailing strict-voiced
  intervals ≥ 1.5 s (`minRealSingingSeconds`) — sustained voice is singing, not bleed;
  sub-1.5 s blips still never extend (Summertime regression covered by test). Tag →
  grouping-41-keep-voiced-tail. Junk repeats after 230.1 ("I don't know what else to say"
  ×3, "to say." at 248) stay outside the cutoff and are handled by the existing gates.
- Ball-vs-beat accuracy: crude drum-flux check shows the persisted grid locked to 10 ms in
  the song's middle third; first/last thirds unverifiable with a crude detector (uniform
  grid scored WORSE, 145 ms) — no evidence to convict the beat tracker; not touched.
  Re-test after relaunch (clock fix) + re-analysis (restored lines, grouping-41).
- Ball tap model changed (user-chosen 2026-07-02): on lyric lines the bounce bottoms land
  on WORD ONSETS over the rendered word (rhythmic + monospace modes); the beat grid is the
  fallback only when a line has no word timings; instrumental rows keep beat/chord taps.
  WorkspaceEditorsView rhythmicBallPosition + ballPosition. Supersedes the 2026-07-01
  "ball lands on the beat" model.

## Follow-up (2026-07-02 evening) — queue execution
- [x] Trailing line-end chords (user report): builder anchors a chord sounding ≥ last word's
      end at the END-OF-TEXT column (was: stacked over the last word); preview widens the
      onset-snap tolerance to 1.6 s for end-of-line chords. Builder test added; goldens pass.
- [x] RC-4 render half: rest markers ("𝄽n" glyph after the last word for ≥2-beat, <4-bar true
      gaps; word ends are energy-normalized so the glyph starts where the voice stops) and
      amber "vocals — not transcribed" badges on rows overlapping untranscribedVocalRegions.
- [x] B3 (precise chord placement): preview places chords at the SongTimeline row's REAL
      chordTimes (1:1 with rendered chords) — the lossy column→word→nearest-onset round trip
      is now only the fallback for edited charts.
- [x] 3d partial: preview reads model.activePlaybackTime (single clock accessor).
- Chord EVENT-time audit ("There's a party goin on", guitar stem, crude flux onsets):
  signed median +10 ms (no systematic bias), median |Δ| 100 ms, 63% within 150 ms of a real
  onset; chord→nearest-beat median 135 ms. Caveat: with 941 onsets the nearest-onset metric
  is weak — a rigorous event audit needs chroma-flux change-point comparison (A-phase work).
- Still open: B2 bar-aligned chord-only rows, B4 section directives, B5 x_ round-trip
  directives, C1 reference-first workflow, phrase-structure grouper, Lyric Blending,
  legacy ball-heuristic deletion.

## 2026-07-03 (batch A, worktree) — Backlog #1 audited, #2 PlaybackClock unification done
- [x] #1 Delete legacy ball-heuristic code: audited the pre-SongTimeline fallback ball math;
  it's still load-bearing for user-edited charts (the one case `songTimelineForPreview`
  falls back to), so nothing was safe to delete. No code change, just confirmed.
- [x] #2 PlaybackClock protocol unification (3d): added `PlaybackClock` protocol
  (PlayerClock.swift) that `AudioPlaybackService`/`StemPlaybackService` conform to with no
  body changes (their currentTime/duration/isPlaying/play/pause/seek surfaces already
  matched exactly). `AppModel.activeClock` resolves to whichever backs
  `activePlaybackSource`; `activePlaybackTime`/`activePlaybackDuration`/
  `isActivePlaybackPlaying`/`seekActivePlayback` now delegate through it instead of each
  repeating the `activePlaybackSource == .stemMix ? … : …` branch.
  `PlaybackProgressSlider.activeDuration` (the one real view-level violation) now reads
  `model.activePlaybackDuration`. `toggleRecordingPlayback`/`toggleStemPlayback` left as-is
  — they need both services by name for the source hand-off, not "the active one."
  New test `testActiveClockResolvesToTheCorrectConcreteServiceForBothSources`. Verified on
  the Mac (temporarily applied to the main checkout to reuse its open Xcode session): 416
  passed (prior baseline +1), same 5 pre-existing unrelated failures, 0 regressions.

## 2026-07-03 (later) — Repetition filter deleting real repeated chorus lines
- Live bug: "Good friends and a beer or two" (Accuracy/Whisper) stopped transcribing
  mid-song, several vocal lines missing (amber "vocals — not transcribed" badges).
  Root-caused to `WhisperCPPRepetitionFilter` (added 42bfa0f for genuine hallucination
  loops): any 6-word phrase recurring >3× within a fixed 30s window was treated as a
  stuck-decoder loop and the whole span between first/last occurrence was deleted. This
  song's chorus hook ("good friends and a beer or two") legitimately recurs that often
  within 30s, so real lyrics got deleted — the actual cause of "Whisper used to work
  better." Balanced Draft (Parakeet, no repetition filter) transcribed the same song
  clean, confirming the diagnosis.
- Fix (commit 646fd18): replaced the fixed-time-window trigger with word-index adjacency
  — only counts as a loop if repeats sit back-to-back with (near) zero distinct words in
  between (the actual signature of a stuck decoder); a real chorus always has whole
  verses between recurrences and never builds a "packed" run. Also invariant to the
  0.85× slow-decode retry's timestamp rescaling (index-based, not time-based). Tightened
  the loop's resume-point search to stop at the first real-content gap. engineVersion
  6→7 to invalidate poisoned caches.
- Tests: `testGenuinelyRepeatedChorusHookIsNotTreatedAsALoop` (regression for this bug),
  `testLoopWithMinorFillerBetweenRepeatsIsStillRemoved` (still catches real loops with a
  single filler word between repeats). Full suite run on the Mac:
  WhisperCPPTranscriptionEngineTests 11/11 passed (1 skipped, env-gated). 5 pre-existing
  failures elsewhere (AppModelTests sandbox-path comparison, MusicLibraryAppModelTests
  timing) unrelated to this change — not investigated further here.
- Also committed in passing: `.gitignore` `.worktrees/` entry and `tasks/backlog.md`
  (both pending from the prior session, uncommitted).

## 2026-07-03 — Whisper decode collapse ("second half missing", slow analysis)
- Data-verified (cache c74117de, 225.6s song, decode2-1.00): whisper.cpp emitted segments
  0–66s then JUMPED to 204s — the middle of the song was never transcribed (5 segments
  total). The user's 0.80 decode-speed run (7385b31f) recovered all 38 segments, at the
  cost of a slow-render pass + 25% longer decode = "extremely long".
- Fix: `TranscriptionVoicedCoverage.fraction` (merged segment spans vs strict-VAD voiced
  time). On cache miss: if Accuracy at 1.0× covers < 60% of the sung audio, retry ONCE at
  0.85× and keep the better result (cached under the original key). On cache hit: a cached
  low-coverage Accuracy result is treated as a MISS (self-heals caches poisoned before the
  rescue existed). 2 unit tests on the real failure shape.
- User guidance: decode-speed slider can stay at 100% — the rescue engages only when a
  song actually needs it. Bulk-import auto-analysis is sequential by design (stems per
  song are the slow part).

## Continue (2026-07-02 late) — A3 + B1 done
- [x] A3 `ChorusChordConsensus`: repeated lyric lines (normalized text, ≥2 instances) vote
      confidence-weighted per beat-offset slot; dissenting labels rewritten only on a ≥0.6
      majority; label-rewrite ONLY (never adds/removes/re-times); deterministic ordering.
      Wired into HarmonyStage outcome (no-op without lyrics); tag reduce-10 →
      reduce-11-chorus-consensus. 3 unit tests + real-data validation (Key West Bar:
      chorus agreement 17%→50%, 1/114 labels rewritten — ties correctly left alone).
- [x] B1: `{key: …}` (from document.estimatedKey, all builder call sites incl. the timeline
      path so byte-compare stays valid) + `{time: 4/4}` emitted; chordPro stage version
      3 → 4 so existing drafts regenerate on next analysis/load. 2 golden tests updated.
- Note: harmony runs BEFORE transcription finishes on fresh songs? No — stage order is
  separation → transcription → harmony, so lyrics are present; on stage RETRY of harmony
  alone the persisted lyrics are used. Consensus is a no-op when lyrics are empty.

<<<<<<< HEAD
## 2026-07-03 — Backlog #1: legacy ball-heuristic deletion, audited (nothing unsafe to delete)
- Traced every ball-position code path in `WorkspaceEditorsView.swift`: `beatBallInput`
  branches on `model.songTimelineForPreview()` — non-nil (generated/un-edited chart) goes
  to `timelineBeatBall` (row-window, RC-2 fixed); nil goes to `legacyBeatBall`/
  `outroBeatBall`, which is the ONLY thing already named "legacy" in this file.
  `songTimelineForPreview()` (AppModel.swift) returns nil precisely when the rebuilt draft
  doesn't match `chordProSource` byte-for-byte — i.e. reviewed/user-edited charts — so
  `legacyBeatBall` is a live, reachable, still-necessary fallback, not dead code.
- `chordOnlyLineOffset`/`trailingChordOnlyLineOffset` (the RC-2 whole-gap-window helpers)
  are called ONLY from `legacyBeatBall`'s call sites inside `beatBallValue`'s non-timeline
  branch — still reachable, same reason.
- `ballPosition`/`rhythmicBallPosition` (monospace/rhythmic renderers) and `BouncingBall`
  itself are shared by BOTH the timeline and legacy paths (they consume the already-resolved
  `BeatBallInput`/`LineBeatBall`, not source text) — not legacy-specific, still fully live.
  `beatDotValue`/`chordOnlyLineWindow` (Beat Dots overlay) are an independent feature, not
  part of the ball heuristic at all (confirmed no shared state with `beatBallInput`).
- Conclusion: nothing safe to delete. Left the code as-is; added explicit "KEEP THIS" doc
  comments on `legacyBeatBall`, `chordOnlyLineOffset`, and `trailingChordOnlyLineOffset`
  naming `songTimelineForPreview()` as the trigger, so this doesn't get re-flagged as
  cleanup-able. No test changes needed (no dead code existed to remove tests for).

## 2026-07-03 (batch B, worktree) — Backlog #5 (B2) + #6 (B4) done
- [x] B2 bar-aligned chord-only rows (eb9c3c7): chord-only lines now render as
      pipe-delimited bars on the song's `MeasureGrid` (`| [C] | [F] | [G] | [C] |`)
      instead of proportional-time-spaced tokens; single sustained chord across
      multiple bars renders as one bare symbol per bar, no dots.
- [x] B4 section directives (f54ad61): `ChordProDraftBuilder` now emits real
      `{start_of_verse: Verse N}` / `{start_of_chorus}` / `{end_of_verse}` /
      `{end_of_chorus}` directives around each `SongStructureAnalyzer` vocal section,
      replacing the old plain `{comment: <label>}` line. Choruses stay unlabeled on
      every recurrence (existing "no numbering for repeats" behavior preserved). Open/
      close is keyed only off the analyzer's seconds-based section boundaries
      (`sectionByStart`), never the separate bars-based `gapBars >= 4` threshold that
      drives the generic Intro/Instrumental comment lines — the two thresholds are
      independent (seconds vs. tempo-relative bars) and can diverge at fast tempos, so
      keying off the wrong one would fragment one continuous verse/chorus whenever an
      instrumental breath crosses the bars threshold without crossing an actual section
      boundary. `ChordProPreviewDocument.previewBlock(forDirective:)` already parsed
      these directives with a distinct `.section` render style predating this fix, so
      this was the last piece needed for correct header rendering.
- Verified both via real Xcode build + full test suite (Mac, not the sandbox — no Swift
  toolchain here): 419 passed, 5 failed, all 5 the known pre-existing flaky tests
  (`AppModelTests` x4, `MusicLibraryAppModelTests` x1 — container temp-path/UUID and
  thread-QoS timing, unrelated). `ChordProDraftBuilderTests` 26/26 passing.
  `swift format lint --strict --recursive Sources Tests` clean.
- Still open in Batch B: B5 x_ round-trip custom directives (#7), C1 reference-lyrics-
  first workflow (#8).

## 2026-07-03 (batch B, worktree) — Backlog #7 (B5) done, scoped to chord timing only
- Scope decision: B5's backlog stub was a vague one-liner. Checked the old design note
  (line 469-470 above: "parse the generated chart → rebuild per-bar chord map → compare
  against the persisted chord timeline within one beat tolerance") and confirmed with Eric
  before implementing — chord timing only, not word-level lyric timing or section/beat-grid
  timing (those would be bigger, separate lifts).
- [x] B5 x_chord_times carrier (86843a3): `ChordProDraftBuilder` emits `{x_chord_times:
      <t>:<label>;...}` directives immediately before every rendered row/line that carries
      chord events — inline lyric-line chords, bar-aligned chord-only rows (B2), and the
      untimed chord grid. Each entry is an exact `time:label` pair (3-decimal seconds), the
      only place a chord's exact timestamp is ever written into the `.cho` TEXT itself
      (elsewhere a chord's position only ever encodes time approximately — proportional
      character offset, or a bar/beat grid cell — with the real timestamp living only in the
      separate in-memory `SongTimeline`/analysis cache).
- Added `ChordProChordTimeCarrier`, a small pure parser that reads the directives back out
  losslessly — the round-trip proof the backlog item asked for. Deliberately NOT wired into
  any import path: turning recovered entries into a live `SongTimeline`/chord-editing
  timeline is a separate, larger decision (confidence thresholds, reconciling with cached
  analysis, etc.) — left for a future item if actually needed.
- Confirmed before implementing (no parser changes required): `x_` is the ChordPro
  convention for app-specific extensions other tools should ignore; `ChordProParser` already
  stores any `{...}` line verbatim regardless of key, and `ChordProPreviewDocument`'s
  directive dispatcher already falls back to an opaque `.directive` case for unrecognized
  keys.
- `InstrumentalRowLine` gained a `chords: [RenderableChordEvent]` field (marked
  `fileprivate` — its type is `private`, so the internal struct's property needs matching
  access) carrying the real events rendered in that row, excluding synthetic sustain-hold
  repeats that reuse a symbol with no new timestamp — this is what the directive is built
  from, not re-derived from the rendered text (which can't disambiguate a real chord change
  from a sustain repeat).
- Updated 4 existing exact-match golden tests for the new directive line; added 4 new tests
  (inline-line round-trip, multi-site round-trip as a subsequence check across intro/lyric/
  outro, omitted-when-no-chords, and a `ChordProDocument` parse/export round-trip proving
  safe opaque passthrough).
- Verified via real Xcode build + full test suite (434 tests, +4 from the new tests): 422
  passed, 6 failed — all 6 match the known pre-existing flaky-test family (container
  temp-path/Song-lookup timing), including one new flaky manifestation in `LiveCaptureTests`
  this run with the identical failure signature as the others (`XCTUnwrap failed: expected
  non-nil value of type 'Song'`) — same root cause, unrelated to this change. Zero failures
  in `ChordProDraftBuilderTests` (30/30). `swift format lint --strict` clean.
- Batch B remaining: C1 reference-lyrics-first workflow (#8).

## 2026-07-03 (batch B, worktree) — Backlog #8 (C1) done, Batch B complete
- Scope decision (AskUserQuestion, confirmed with Eric before implementing): relocate the
  existing "paste real lyrics" feature's discoverability into the Lyrics tab as a persistent
  banner, rather than prompting during import — prompting on every import would add friction
  to the common original-song case with no reference lyrics available at all, cutting against
  the sibling design note on backlog #15 ("most of this catalog is original songs with no
  ground truth").
- [x] C1 reference-lyrics prompt banner (bdf8906): `ReferenceLyricsSheet`
      (`AnalysisWorkspaceView.swift`) made non-private so it can be presented from a second
      entry point; new `ReferenceLyricsPromptBanner` shown at the top of `TimedLyricsEditor`
      (`WorkspaceEditorsView.swift`) when a song has lyrics to review, no reference text is set,
      and the user hasn't dismissed it THIS session for THIS song. New
      `ReferenceLyricsPromptPolicy` enum factors the gating logic out of the view for direct
      unit testing (7 new tests in `ReferenceLyricsPromptPolicyTests.swift`).
- First backlog item this session to add a genuinely NEW Swift file — required `tuist generate
  --no-open` to regenerate `project.pbxproj` (SongWorkbench is a Tuist project; Xcode builds
  from the committed pbxproj file list, not a live glob of `Sources/`/`Tests/` — see
  [[songworkbench-tuist-project]]). Regenerated in the MAIN checkout (with the worktree's
  changed/new files copied in), then copied the resulting `project.pbxproj` into the worktree
  before reverting main back to clean — same copy-in/verify/revert/commit-in-worktree pattern
  used for every build+test verification this session, just extended to also carry back the
  regenerated project file. Git worktree operations must still go through the sandbox (its
  `.git/worktrees/<name>` metadata has sandbox-only paths baked in), but `tuist generate` /
  `xcodebuild` must run for real on macOS, which the sandbox can't do — so this two-sided
  dance is unavoidable for any commit that adds/removes a file.
- Verification workflow upgrade: discovered a `desktop-commander` MCP gives REAL shell access
  on Eric's Mac (not the sandbox) — `xcodebuild test -workspace SongWorkbench.xcworkspace
  -scheme SongWorkbench -destination 'platform=macOS' -quiet` ran the full suite in ~47s and
  printed a clean "Failing tests:" list directly, versus several minutes of screenshot/click
  round-trips through Xcode's GUI (Product > Test, Report Navigator, Test Navigator scrolling)
  used for every prior verification this session. Use this for all remaining batches/items —
  it's strictly faster and less error-prone than driving the Xcode UI via computer-use.
- Verified: `xcodebuild test` — failing tests were exactly `AppModelTests`
  (`testImportDuringRestoreIsMergedInsteadOfDiscarded`, `testRecentSongsFollowSelectionOrder`,
  `testRemovingSelectedSongPreservesSourceFileSelectsNeighborAndPersists`,
  `testSelectingDifferentSongResetsSelectedSongProgress`) and
  `MusicLibraryAppModelTests.testOpeningLocalLibraryTrackAddsAndSelectsSong` — the same known
  pre-existing flaky family seen every run this session, none touching this change. Zero
  failures in `ReferenceLyricsPromptPolicyTests` or any file this item touched. `swift format
  lint --strict` clean.
- **Batch B complete**: #5 (B2), #6 (B4), #7 (B5), #8 (C1) all done. Ready to merge to `main`
  once confirmed with Eric (same check-in pattern as Batch A's merge).

## 2026-07-03 — Chord EVENT-time rigor audit (backlog #10)
- Built the rigorous chroma-change-point comparison the 2026-07-02 evening crude-flux
  audit flagged as missing: `ChromaChangePointDetector` (frame-to-frame cosine distance
  over `ChromaVector`s, median+6×scaled-MAD adaptive threshold, no smoothing — smoothing
  turned out to bias clean step-function detections by ~half a window with no robustness
  gain) + `ChordChangePointAudit` (same signed-median/median-abs/hit-rate metric shape as
  the crude audit, but against genuine harmonic change-points instead of any broadband
  onset). `Sources/SongWorkbench/ChromaChangePointDetector.swift`.
- 14 synthetic-data unit tests (`ChromaChangePointDetectorTests.swift`): exact detection on
  clean step functions, zero false positives on repeated same-chord strums, correct
  detection under jitter (30 seeded trials + a 16-bar/15-change progression), correct
  detection of shared-note chord changes (C→Am) that a broadband onset detector cannot see,
  degenerate-input handling. No compiler available in this sandbox — algorithm was
  independently re-derived in Python and stress-tested there first; caught 2 real bugs
  (threshold collapse on near-silent data, under-scaled MAD letting jitter through) before
  they reached the Swift file.
- No bundled real-audio fixture or chroma dump exists in `Tests/` for "There's a party goin
  on" — no new real numbers reported; running this against the real song still needs a
  human in Xcode. Methodological takeaway either way: the earlier crude "+10ms / 100ms
  median / 63% within 150ms" numbers are an upper bound, not a confirmed read — dense onsets
  (941 of them) make SOME onset likely near most chord events whether or not it's the real
  change, so the old metric can't fully distinguish a correct chart from a lucky one.
  Write-up: `.scratch/chord-event-timing-audit.md`.

## 2026-07-04 — Chord event-timing rigor audit (backlog #10), real-build verification + fix
- Ran the real `xcodebuild test` (on-Mac toolchain, not the sandbox Python re-derivation) for
  the first time against this item and it caught a genuine bug the earlier sandbox-only
  verification missed: `testIgnoresRepeatedStrumsOfTheSameChordSameNotes` failed with
  `XCTAssertEqualWithAccuracy failed: ("3.049999999999997") is not equal to ("3.0")`.
- Root cause was in the TEST, not `ChromaChangePointDetector`: the test built its synthetic
  frames with a hand-rolled `while time < 3.0 { time += 0.05 }` loop. Repeatedly adding 0.05
  as a `Double` drifts by a full hop after 60 iterations (0.05 isn't exactly representable in
  binary floating point) — confirmed in Python (`while time < 3.0: time += 0.05` runs 61
  times, ending at `time = 3.049999999999997`). So the test generated 61 C-major frames
  instead of 60, and the first G-major frame landed at ~3.05, not 3.0. Read the detector
  implementation to confirm it reports `sorted[i + 1].timestamp` verbatim (no interpolation,
  no off-by-one) — it's correct as written; no product code change needed.
- Fix: rewrote the test to build frames via the existing frame-count-based `syntheticFrames`
  helper (`(chord, duration)` segments, integer `frameCount`), matching every other
  strict-accuracy (`0.000_001`) test in the file, instead of a parallel hand-rolled loop with
  a latent bug.
- Verified: `swift format lint --strict --recursive Sources Tests` clean; targeted
  `xcodebuild test -only-testing:SongWorkbenchTests/ChromaChangePointDetectorTests
  -only-testing:SongWorkbenchTests/ChordChangePointAuditTests` — 14/14 pass; full
  `xcodebuild test` suite — only the pre-existing known-flaky baseline (`AppModelTests` x4,
  `MusicLibraryAppModelTests.testOpeningLocalLibraryTrackAddsAndSelectsSong`), zero new
  failures. `project.pbxproj` also regenerated via `tuist generate --no-open` — the prior
  commit's pbxproj was missing the Sources/Tests file-reference entries for this item's two
  new files.
- Takeaway validated: this is exactly the kind of bug that only shows up under a real Swift
  compiler/test run — the sandbox's independent Python re-derivation could confirm the
  *algorithm* but not this specific test-data construction bug. Backlog #10 is now done with
  real verification, not just algorithmic cross-check.
- **Batch C item #10 done.** Next: backlog #9 Phase 1 (`LyricPhraseGrouper`, bar-period
  re-segmentation) per Eric's "Proceed with Phase 1" instruction — design doc and both open
  questions already resolved (`.scratch/PRD-phrase-structure-lyric-grouper.md`).

## 2026-07-04 — Phrase-structure lyric grouper Phase 1 (backlog #9)
- Built `LyricPhraseGrouper` per PRD §3.2-3.3: per-`SongStructureAnalyzer`-vocal-section
  bar-period detection (candidates 2/4/8 bars, autocorrelation of the per-bar chord-label
  sequence built via `MeasureGrid`/`DownbeatEstimator` — same construction
  `ChordProDraftBuilder.measureGrid(for:chords:)` uses), 0.75 confidence floor, >=2 full
  periods of evidence required. Qualifying sections re-cut at the nearest real inter-word
  gap to each computed phrase boundary (never mid-word, never inventing/dropping a word).
- Chorus-determinism guard (PRD §4) implemented literally: all `.chorus`-kind sections share
  ONE period value (whichever occurrence scored highest confidence), applied to every
  occurrence via its own local bar-aligned origin — so two sung passes of the same chorus
  with jittery ASR timings still land on matching relative cut points. Regression test
  confirms `SongStructureAnalyzer.vocalSections` still flags both occurrences `.chorus`
  after regrouping.
- Bounded by the same caps `TimedLyricGroupingConfiguration` uses for ASR lines (15s / 32
  tokens) — a computed cell exceeding either rejects the WHOLE section rather than emitting
  a degenerate line. No-ops on missing beat/tempo/chord data, low confidence, or a section
  with no per-word data (older analyses) — matches every §4 guard.
- Wired into `AppModel.applyAnalysis` as an unconditional post-pass immediately after
  `TimedLyricSegmentGrouper.regroup`. **Reconciles the PRD §6 versioning question**: Eric had
  approved "fold a chords-digest into the lyric stage version," but re-reading
  `applyAnalysis` while implementing showed `regroup` already runs unconditionally on every
  load with no version-tag gating at all (cheap + pure + idempotent). Following that SAME
  pattern for `LyricPhraseGrouper` achieves the intended outcome (a harmony-only
  re-analysis's new chords get picked up next time the song opens) for free, with no new
  digest/version-tag plumbing — simpler than the originally-approved answer while satisfying
  the same intent. Documented in the commit message rather than adding unneeded staleness
  tracking.
- 7 unit tests (`LyricPhraseGrouperTests.swift`): missing-data no-op, low-confidence no-op,
  clean 4-bar-period re-segmentation, never-merges-across-a-section-boundary, no-per-word-data
  fallback, line-length-cap rejection, and the chorus-determinism regression.
- Verified: `swift format lint --strict` clean; targeted `xcodebuild test` — 7/7 new tests
  pass; full suite — only the pre-existing known-flaky baseline (`AppModelTests` x4,
  `MusicLibraryAppModelTests` x1), zero new failures. `project.pbxproj` regenerated via
  `tuist generate --no-open`.
- **Phase 1 done.** Phase 2 (rhyme/syllable refinement) stays deferred pending real-song
  evaluation, per the PRD.

## 2026-07-04 — Lyric Blending feature (backlog #11)
- Own worktree (`.worktrees/lyricBlending`, branch `backlog/lyric-blending`), independent of
  Batch C. Implemented directly (no design-doc gate this time, per Eric's "minimal pauses"
  instruction) — scope followed the already-recorded Phase-2 sketch + the already-answered
  "G. Model-settings question" (don't expose raw engine params; the blend IS the tuning).
- Data model: `LyricBlendCandidate` (one mode's text + words for a row) / `LyricBlendRow`
  (a time window, every mode's candidate, optional `selectedMode`, `effectiveCandidate()`
  falling back accuracy > balanced > fast). `SongAnalysisDocument.lyricBlendRows`, schema
  v8 -> v9. `document.lyrics` always mirrors the row list's CURRENT effective picks.
- `LyricBlendRowBuilder` (pure): clusters each mode's own lines by proximity to a row's
  ANCHOR time (not chained to the last-added line, to bound drift), joins multiple same-mode
  lines in one row into a single candidate, `effectiveLyrics(from:)` rebuilds the official
  `[TimedLyricSegment]` array. 7 unit tests.
- Pipeline-orchestration decision: rather than restructuring `SongAnalysisPipeline`'s internal
  stage-loop concurrency (risky — deeply threaded through cancellation/progress code) to run
  3 transcription modes as sibling `async let` tasks, the 2 non-primary modes are re-run
  SEQUENTIALLY at the `AppModel` call-site via 2 extra `.transcription`-only pipeline
  requests reusing the primary analysis's already-populated document (so harmony/chords/stems
  are untouched, not redone). Sequential (not concurrent) because
  `SongAnalysisCoordinator.run` cancels any in-flight run — overlapping calls would cancel
  each other. This is a materially lower-risk, much smaller diff than touching
  `SongAnalysisPipeline` itself, at the cost of the 2 extra passes running one after another
  instead of in parallel — acceptable tradeoff for a first cut; can revisit if the added wall
  time (per song, once, after the primary result is already usable) matters in practice.
- Primary-mode selection is now dynamic (`AppModel.primaryTranscriptionMode`): prefers
  Accuracy, then Balanced, then Fast Draft, among whatever's actually INSTALLED — avoids a
  regression for users who only have the Parakeet (Fast/Balanced) model and not Whisper, who
  would otherwise see every analysis fail with "install the Accuracy model." Removed the old
  `transcriptionMode` `UserDefaults`-backed picker property and the `modeOverride`/per-song
  stored-mode plumbing in `reanalyzeAllSongs` entirely — both are meaningless now that mode
  is no longer a user choice.
- UI: new singleton `Window("Lyric Blend", id: "lyricBlend")` scene (modeled on the existing
  About-window pattern; there's no prior per-song/value-parameterized window in the app) +
  `LyricBlendView` (rows stack each mode's candidate in its own color — reused
  `Theme.swift`'s existing `swAccent`/`swViolet`/`swAmber` tokens rather than inventing new
  ones — tappable, selected one gets a checkmark + glow, blank gap between rows).
  `LyricBlendAutoOpen` view modifier opens it when `AppModel.lyricBlendReadySongID` is set,
  matching the spec's "on analysis complete, open a new Lyric Blend window."
- Deliberate design simplification: the Blend window always tracks the CURRENTLY SELECTED
  song's live `@Published` state (`lyricBlendRows`/`lyricSegments`), not a value bound to
  whichever song ID it was opened for — `analysisBySongID` is a plain cache dict, not
  `@Published`, so a per-song window bound to a non-selected song's cached document wouldn't
  update reactively anyway. Simpler and avoids that whole reactivity gap; documented as an
  intentional tradeoff (a window left open while switching songs will follow the switch).
- `applyLyricBlendSelection(rowID:mode:)` rebuilds `lyricSegments` from
  `LyricBlendRowBuilder.effectiveLyrics` and lets that property's EXISTING `didSet` (ChordPro
  rebuild + persist) do the rest — no parallel persistence path.
- Scope cut, called out explicitly rather than silently decided: `reanalyzeAllSongs` (bulk
  re-analyze) does NOT run the extra blend passes — 3x transcription cost across the whole
  library is a materially bigger tradeoff than the single-song case and deserves its own
  decision if wanted. Re-selecting a song and running Analyze on it individually populates
  its blend candidates as normal.
- Removed the segmented Fast/Balanced/Accuracy picker from `AnalysisWorkspaceView`; the
  decode-speed slider (previously shown only when Accuracy was the picked mode) is now always
  shown since Accuracy always runs whenever it's installed.
- Verified: `swift format lint --strict` clean; `xcodebuild build` — clean; targeted
  `xcodebuild test` — 7/7 new `LyricBlendRowBuilderTests` pass; full suite — only the
  pre-existing known-flaky baseline (`AppModelTests` x4, `MusicLibraryAppModelTests` x1),
  zero new failures. `project.pbxproj` regenerated via `tuist generate --no-open`.
- **Not yet manually verified in the running app** — opening the window, clicking through a
  real blend on a song with 2+ transcription models installed, and confirming ChordPro
  regenerates correctly all still need a human at the Mac. Everything else (data model,
  clustering algorithm, wiring, persistence path) is code-complete and unit-tested.

## 2026-07-04: Backlog #15 Phase 1 — split ChordPro tab
- Design doc: `.scratch/PRD-chordpro-tab-split.md`. Confirmed 3 open decisions with Eric via
  AskUserQuestion before implementing (segment-level lyric confidence over per-word
  threading; relocate the existing interactive view unchanged rather than a deeper chrome
  refactor; keep the new per-line/per-event `accepted` flag independent of the existing
  whole-song review-state gating) — this item touches a heavily-tuned interactive view
  (bouncing ball/beat dots/waveform, several past sessions' worth of tuning) and adds new
  schema fields, so it warranted a check-in even under the "minimal pauses" working mode.
- `EditorTab.chordPro` now renders a brand-new `ChordProReadOnlyView`
  (`ChordProReadOnlyView.swift`): builds `ChordProPreviewDocument` directly from the raw
  `.cho` source (same `ChordProDocument(parsing:).transposed(by:)` call `ChordProAppPreview`
  already used) and renders chord-over-lyric text only — no waveform, ball, beat dots, or
  playback highlight. Chord column placement (chords positioned at their recorded character
  column, padded with spaces, later chords pushed past an overlapping earlier one) is
  factored into a standalone `ChordRowStringBuilder` enum so it's unit-testable without
  SwiftUI (4 new tests in `ChordRowStringBuilderTests.swift`).
- All of the EXISTING interactive chrome (`ChordProTabEditor`/`ChordProAppPreview`/
  `ChordProPreviewBlockView`/`ChordProPreviewLineView`, ~800 lines) moved AS-IS to a new
  `EditorTab.review` tab (`ChordProReviewTab`) — deliberately not touched internally, since
  extracting/recomposing its overlay chrome was assessed as materially higher regression risk
  than relocating it whole. Below it, a new `ChordProReviewAnnotationsPanel` lists every
  lyric line and chord event (sorted by time), tinted by a 3-tier confidence read
  (low <0.4 / medium <0.7 / high, `Color.swCoral`/`swAmber`/clear), with an inline
  `TextField` to correct the text/chord and an Accept checkbox — reusing the same direct
  `$model.lyricSegments[index]`/`$model.chordEvents[index]` binding pattern
  `TimedLyricsEditor`/`ChordTimelineEditor` already use, so edits flow through the existing
  `didSet` → rebuild-ChordPro-draft → persist pipeline with no new plumbing.
- Schema (v9 → v10, additive/optional, no migration): `TimedLyricSegment.confidence: Float?`
  — the MEAN of the line's constituent ASR tokens' own `confidence` values, computed right
  at `TimedLyricSegmentGrouper.group`'s existing token→line grouping boundary (the tokens are
  already in hand there; no new data source needed). `TimedLyricSegment.accepted: Bool` and
  `EditableChordEvent.accepted: Bool`, both defaulting `false`. `EditableChordEvent` didn't
  previously have a custom `Codable` implementation (synthesized only) — added one (matching
  `TimedLyricSegment`'s existing pattern) so old JSON missing `accepted` still decodes via
  `decodeIfPresent(...) ?? false` instead of failing to decode the non-optional field.
- Confidence is `nil` wherever a line was rebuilt by a pass that doesn't carry per-token
  confidence forward: `TimedLyricSegmentGrouper.regroup` (synthesizes tokens with
  `confidence: nil` from stored words, which don't carry confidence), `LyricPhraseGrouper`'s
  bar-period re-cuts (only when it actually re-segments a section — untouched sections keep
  their original confidence), and `ReferenceLyricAligner` (no ASR confidence applies to
  user-provided reference text). Accepted as a Phase 1 scope cut per Eric's confirmed
  decision (segment-level granularity, not full per-word threading) — flagged in the PRD as
  a Phase 2 candidate if line-level coloring proves too coarse in practice.
- Verified via real `xcodebuild test` (Mac, `tuist generate` + build/test workflow): ran the
  full suite 3 times. Tests touching this change (`TranscriptionTests` incl. 2 new confidence
  tests, `ChordRowStringBuilderTests`, `LyricBlendRowBuilderTests`, `ChordProDraftBuilderTests`,
  `ChordProHighlightDeriverTests`, `ChordProPlaybackHighlightTests`, `ChordTimelineDecoderTests`,
  `LyricPhraseGrouperTests`, and the rest of the suite excluding the two flaky classes) passed
  deterministically every run. `AppModelTests`/`MusicLibraryAppModelTests` failed with a
  DIFFERENT subset of tests failing on each of the 3 runs with byte-identical code — confirmed
  pre-existing flaky-timing-test baseline (see `tasks/lessons.md` / memory), not a regression;
  none of the failing tests touch ChordPro, lyrics, chords, or `EditorTab`.
- Committed `4612da2` on `backlog/chordpro-tab-split`; merged to `main`.
- **Not yet manually verified in the running app** — clicking through the new Review tab's
  Accept checkboxes and confidence tinting on a real analyzed song still needs a human at the
  Mac. Everything else (data model, grouping-time confidence computation, view split, chord
  column placement) is code-complete and unit-tested.

## 2026-07-04: Bass Note row in Review tab + stem-separation truncation fix
- Bug reported by Eric: "Current Analysis did not complete vocal transcription for the whole
  ending parts of the song." Diagnosed using LIVE cached data on his Mac (not guessed): pulled
  `~/Library/Containers/com.local.SongWorkbench/.../songs/*.json` and
  `.../Caches/SongWorkbench/Analysis/*.json`. For "Good friends and a beer or two.mp3"
  (225.621375s), persisted lyrics stopped at 197.72s; the untranscribedVocalRegions audit only
  flagged a small [198.54, 200.06] gap, NOT the real ~20s gap to the true ending — because that
  audit consumes the same already-truncated voiced intervals. Checked every cached raw
  transcription pass for this song across whisper.cpp Accuracy, Parakeet Fast Draft, and
  Parakeet Balanced Draft, across multiple independent analysis runs: all three engines
  independently reported the vocals-stem `sourceDuration` as ~204.56-207.36s, never the true
  225.62s — proving the separated STEM FILE ITSELF was short, upstream of all transcription.
- Root cause: `CoreMLStemSeparationEngine.loadStereoFloatAudio`'s resample path called
  `AVAudioConverter.convert(to:error:withInputFrom:)` exactly once and trusted that single
  call's output as complete — not guaranteed for a resample (internal priming/latency can need
  multiple pulls to fully drain). Fixed with a `drainConverter` loop that pulls until
  `.endOfStream`. Bumped `ONNXSixStemSeparationEngine`'s engineVersion 2->3 (the only separation
  engine actually instantiated in production; it composes `CoreMLStemSeparationEngine` for this
  exact path) to invalidate every previously-cached, possibly-truncated stem across the whole
  library — matches this project's existing convention for cache-poisoning fixes (see the
  repetition-filter engineVersion 6->7 bump, backlog #21).
- New regression test: a 48kHz fixture (nearly all real sources need resampling) asserts the
  44.1kHz output stem lands within 50 frames of the exact expected duration.
- Feature (requested alongside): optional Bass Note row in the Review tab
  (`ChordProReviewAnnotationsPanel`) — a new `@AppStorage("reviewShowBassNotes")` display
  toggle (off by default, disabled with no bass notes detected) shows each lyric line's
  in-window bass notes, in `StemKind.bass.laneColor`, above the line — reusing the same
  `model.bassNotes` data the Bass Notes tab's ChordPro draft already reads, not a new detection
  pass. New standalone `BassNoteRowFormatter` (mirrors `ChordRowStringBuilder`'s testable-logic
  pattern), 5 unit tests.
- Verified via real `xcodebuild test`: full suite (excl. known-flaky `AppModelTests`/
  `MusicLibraryAppModelTests`) green across 3 runs; new tests individually confirmed passing.
  Committed `f98b312` on `fix/bass-note-review-and-separation-truncation`, merged to `main`
  (`2294a17`), `tuist generate` clean (no drift).
- **Practical note for Eric**: because of the engineVersion bump, the NEXT time any song is
  (re-)analyzed, its stems will be regenerated from scratch (one-time cost per song) rather than
  reused from the now-invalidated cache — this is intentional and needed to actually get the
  fixed, full-length stem for "Good friends and a beer or two" and any other song that hit this.

## 2026-07-04: Lyric Blend manual override ("4th candidate")

- Requested by Eric: "we should be able to edit a 4th version of the line as an override for a
  consistently misheard lyric - these overrides should then take precedence even if the song is
  re-analyzed."
- `LyricBlendRow.overrideText: String?` (schema v10 -> v11, additive, no migration). New
  `effectiveText(preferenceOrder:)` returns the trimmed override when set/non-empty, else falls
  through to `effectiveCandidate()`'s text — `effectiveCandidate()` itself is untouched, so it
  never considers the override and existing callers/tests are unaffected.
  `LyricBlendRowBuilder.effectiveLyrics` now checks the override first, producing a segment with
  no `words` (an override has no per-word ASR timing, same as any manually-edited lyric line —
  playback falls back to interpolation across the row's span).
- Core design problem: `AppModel.runLyricBlendPasses` always rebuilt `lyricBlendRows` FROM
  SCRATCH on every re-analysis (`LyricBlendRowBuilder.buildRows` has no memory of prior state),
  so an override would otherwise vanish the moment the song was re-analyzed. Fixed with new
  `LyricBlendRowBuilder.reconciled(newRows:against:)`: carries a row's `overrideText` forward
  onto whichever freshly-built row occupies the same time window, matched by greatest
  start/end-window overlap (falling back to nearest start within 0.75s if a boundary shift left
  no true overlap). Wired into `runLyricBlendPasses` right before the fresh rows replace the old
  ones.
- Incidental fix discovered while designing the above: a user's mode PICK (`selectedMode`, from
  the existing blend-selection feature) was *also* being silently discarded on every
  re-analysis — an existing, previously-undocumented gap, since nothing carried it forward
  either. Same `reconciled` mechanism now fixes both with no extra code.
- `LyricBlendView`: each row gets a 4th, mint-colored free-text field below the three mode
  candidates. Typing updates immediately via `AppModel.applyLyricBlendOverride(rowID:text:)`
  (empty/whitespace clears the override rather than persisting a blank line). An active override
  shows its own checkmark and suppresses the checkmark on all three candidate buttons, since the
  override unconditionally wins.
- 7 new unit tests (`LyricBlendRowBuilderTests`): override precedence, whitespace-only override
  ignored, override segment has no words, reconciliation by overlap / nearest-start fallback /
  no-match / no-old-rows / empty-override-not-leaked.
- Verified via real `xcodebuild test`: full suite (excl. known-flaky `AppModelTests`/
  `MusicLibraryAppModelTests`) green across 2 runs (one incidental `StemPlaybackServiceTests`
  failure on the first run reproduced as a pass both in isolation and on immediate rerun — same
  parallel-timing flakiness class as the documented `AppModelTests` flake, not a regression: this
  change touches only Lyric Blend files, nothing in playback/stems). All 15
  `LyricBlendRowBuilderTests` (8 existing + 7 new) individually confirmed passing. No new/removed
  files, so no `tuist generate` needed. Committed `0d09af1` on `feature/lyric-blend-override`,
  merged to `main` (`2e608f3`).

## 2026-07-04: Phrase-structure lyric grouper Phase 2 (backlog #9)

- Eric asked to proceed straight to Phase 2 (ahead of the PRD's "wait for real-song
  evaluation" recommendation) and confirmed the rhyme-detection approach: bundled phonetic
  table (CMUdict-derived), not an orthographic-suffix heuristic.
- New `Resources/cmudict_rhyme.tsv`: word -> rhyme part (phonemes from the last
  PRIMARY-stressed vowel to the end, stress digits stripped), derived from `cmudict.dict`
  (cmusphinx/cmudict, Carnegie Mellon University, BSD-style license, notice retained in the
  file header). 126,052 entries, first-listed pronunciation only.
- New `SyllableCounter` (pure vowel-cluster + silent-trailing-"e" heuristic, no bundled
  data) and `RhymeDetector` (pure lookup + `Bundle.main`-backed `.shared` singleton;
  `bestRhymeScore` distinguishes `nil` "no evidence" from `0.0` "confirmed non-rhyme" so an
  out-of-vocabulary word never masquerades as a signal; degrades to an empty table rather
  than crashing when the bundle resource is missing, including inside the unit-test host).
- New `RhymeSyllableScorer`: given Stage 1's boundary and nearby real word-gap candidates
  plus the section's OTHER cells as siblings, picks the best-scoring candidate — weighted
  end-rhyme (0.6) + whole-LINE syllable-count similarity to the sibling median (0.4) — only
  moving away from the nearest-in-time candidate past a `minimumImprovement` margin (0.05
  default).
- Wired into `LyricPhraseGrouper.resegmented`: Stage 1's per-boundary nearest-gap snap runs
  first unchanged, then Stage 2 nudges each boundary independently within a
  `nudgeWindowInBeats` (1 beat default) window, fenced strictly between the NEIGHBORING
  boundaries' BASELINE (not post-nudge) cuts so cells can never cross or overlap regardless
  of how any individual boundary moves; a defensive collision/inversion check falls back to
  the unmodified Stage 1 cut set (should be unreachable given the fencing, kept as a
  belt-and-suspenders net). The trailing cell (after the last real cut, running to the
  section's end) is always included as a sibling for every OTHER boundary's decision, even
  though it never gets a decision of its own.
- New `LyricPhraseGrouper.Configuration` fields (`refinementEnabled` default `true`,
  `nudgeWindowInBeats` default `1`, `rhymeSyllableConfiguration`); `regroup()` gained a
  defaulted `rhymeDetector: RhymeDetector = .shared` parameter — the existing
  `AppModel.applyAnalysis` call site needed zero changes, and Phase 1's "no version-tag
  bump" resolution still holds (same always-rerun post-pass, new logic inside it).
- Tests: `SyllableCounterTests` (6), `RhymeDetectorTests` (11), `RhymeSyllableScorerTests`
  (7), plus 3 new `LyricPhraseGrouperTests` integration cases on a hand-timed 3-cell fixture
  proving: the nudge happens with real rhyme+syllable evidence, `refinementEnabled: false`
  reproduces exactly Stage 1's cut, and syllable evidence alone (empty rhyme table) does
  NOT favor this particular nudge (confirms the main test's result is rhyme-driven, not a
  syllable-count coincidence) — caught during design that "syllable similarity" naturally
  means whole-line totals, not just the ending word's count, which flipped an earlier draft
  of that third test's expectation before it ever reached the real build.
- Real `xcodebuild test` caught a genuine bug the design/sandbox review missed:
  `RhymeDetector.parseTable` split on a bare `"\n"` `Character`, which silently fails to
  split CRLF-terminated text at all, since Swift represents `"\r\n"` as ONE grapheme
  cluster, not two characters — a test using `\r\n` line endings got a table of size 0.
  Fixed with `split(whereSeparator:)` using `\.isNewline` (correctly handles LF/CR/CRLF).
  Also caught an argument-order compile error (`rhymeDetector:` before `configuration:` at
  a call site, which Swift rejects since labeled arguments must appear in declaration
  order) — neither of these would have been caught without a real compiler.
- Verified via real `xcodebuild test` (Mac toolchain, via Desktop Commander): targeted new
  suites pass; full suite run twice — only the pre-existing known-flaky baseline
  (`AppModelTests`, `MusicLibraryAppModelTests`; the exact failing subset differed between
  the two runs on identical code, confirming flakiness rather than a regression), zero new
  failures. `swift format lint --strict` clean (after an auto-format pass + one manual
  line-length fix). `tuist generate` regenerated the pbxproj for the 7 new files.
- Own worktree `backlog/phrase-grouper-phase2`. Committed `ad5aa19`, merged to `main`
  `973b1d9`.
- Notable friction (environment, not code): the sandbox's git repeatedly left stale lock
  files (`index.lock`, `HEAD.lock`, ref locks) it couldn't unlink due to a permission quirk
  on this session's bind-mounted `.git`, blocking every subsequent git command until the
  lock was removed from the REAL Mac side (via Desktop Commander) immediately before the
  next sandbox git command, with zero intervening git calls (even a read-only `git status`
  recreated a fresh stale lock). The final merge itself was done directly on the Mac
  checkout instead of through the worktree, since the worktree's own `.git` metadata has
  sandbox-only paths baked in (per `songworkbench-verify-on-mac` memory) but the shared
  object database is visible fine from the main checkout on either side.
