# Fix: missed chord changes + dropped end-of-song lyrics (2026-07-04)

# iPad device build smoke test (2026-07-06)

## Acceptance criteria

- [x] The active Xcode iPad destination builds without macOS-only AppKit import errors.
- [ ] If the build succeeds, launch the app on the connected iPad from Xcode.

## Review

- Updated shared SwiftUI files to use `#if os(macOS)` for AppKit imports/branches instead
  of `canImport(AppKit)`, keeping iPad builds on UIKit paths.
- Fast Xcode diagnostics: clean for `ChordProReadOnlyView.swift`, `ContentView.swift`,
  `WorkspaceEditorsView.swift`, and `PlatformShims.swift`.
- Xcode `BuildProject`: succeeded on 2026-07-06 using the active scheme/destination
  (7.366s). Launch/install still needs Xcode's Run action with the connected iPad selected.
- Follow-up: user reports the iPad is not listed in Xcode. `xcrun devicectl list devices`
  timed out waiting for `CoreDeviceService` to initialize, so current blocker is device
  discovery/trust/CoreDevice state rather than Swift compilation.

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

## Review: chord/vocal accuracy + timeline placement (2026-07-05)

Findings:
- [x] Harmony decode still windows raw chroma on the harmony engine's original
      `result.beat?.beatTimes`, even after deriving `resolvedBeatTimes` from
      drum onsets. This can pick labels and Viterbi switch discounts on a
      different grid than the one later used for snapping, duration filtering,
      chorus consensus, ChordPro, and playback.
- [x] `VocalWordOnsetAligner` lets multiple adjacent words snap to the same
      vocal onset because it only enforces nondecreasing starts. This can stack
      word anchors/ball timing and inflate onset-corroboration scores for
      candidates whose words are bunched near one energy burst.
- [x] Generated ChordPro still hard-codes `beatsPerBar = 4`, while the live
      preview estimates 3/4/5/6 from lyric-line spacing. Non-4 phrase grids can
      therefore render and persist chord-only rows/barlines differently from the
      preview timeline.

Verification basis:
- Static code review of `AnalysisStage`, `ChordTimelineDecoder`,
  `VocalWordOnsetAligner`, `ChordProDraftBuilder`, `WorkspaceEditorsView`,
  `MeasureGrid`, and associated tests. No implementation changes or test runs
  in this pass.

### Fixes landed (2026-07-05, night)

- **Harmony decode grid**: `ChordTimelineDecoder.events(from:key:bassNotes:instrumentOnsets:beatTimes:)`
  gained an optional `beatTimes` override (defaults to the old embedded-grid
  behavior when omitted, so every other caller is unaffected). `AnalysisStage`
  now passes `resolvedBeatTimes` (the drum-locked grid) explicitly, so chord
  decoding windows chroma on the SAME grid used downstream for snapping,
  duration filtering, chorus consensus, ChordPro, and playback. Reducer/cache
  stage tag bumped `"|reduce-14-bass-snap"` → `"|reduce-15-resolved-beatgrid"`
  to force cached analyses to re-decode. Regression:
  `testExplicitBeatTimesOverridesAnalysisEmbeddedGrid` (constructs a real chord
  change on a "true" grid while the analysis embeds a decoy grid, asserts the
  override wins).
- **VocalWordOnsetAligner stacked anchors**: `snapped(_:toOnsets:tolerance:minimumWordGap:)`
  gained a `minimumWordGap` (default 0.02s) and the nondecreasing clamp
  (`>=`) became a strict `+ minimumWordGap` floor, so adjacent words can no
  longer snap to the identical onset. Regression:
  `testVocalWordOnsetAlignerNeverStacksTwoWordsOnTheSameOnset` (same two-word/
  one-onset fixture as the existing nondecreasing test, strict `>` assertion).
- **ChordPro hard-coded beatsPerBar**: `ChordProDraftBuilder.measureGrid` took
  a `lyrics` parameter and now calls
  `DownbeatEstimator.estimateBeatsPerBar(beatTimes:onsets:)` with the lyric-line
  onsets — the same signal `WorkspaceEditorsView`'s live preview already uses —
  instead of a literal `4`. The doc comment's original justification ("the
  builder has no lyric-onset signal independent of the lyrics") was simply
  wrong: `lyrics: [TimedLyricSegment]` was already in scope. Regression:
  `testChordOnlyRowUsesEstimatedBeatsPerBarFromLyricSpacing` — a differential
  test (proved to fail without the fix, by temporarily hardcoding `4` and
  re-running) that builds the SAME outro chords twice, varying only whether
  the preceding lyric lines are spaced 5 beats or 4 beats apart, and asserts
  the rendered outro bar grid differs.
- Suite: 586 tests, same pre-existing `AppModelTests`/`MusicLibraryTests`
  environment failures (song-file-selection/persistence state, unrelated to
  these 3 fixes) — none in `ChordTimelineDecoderTests`,
  `ChordProDraftBuilderTests`, or the `VocalWordOnsetAligner` tests.
  `swift format lint --strict -r Sources Tests` clean.

## Review: instrumental-row width bug + Rhythmic Spacing always-on (2026-07-05, evening)

- **Instrumental line width** (Eric: "Intro and outro instrumental parts... compressed to
  roughly 1/3 the expected width"): three compounding bugs in `WorkspaceEditorsView.swift`,
  all in the chord-only (no lyric words) row path:
  1. `instrumentalTimeWidth` sized itself from the bar-grid TEXT's own character extent
     (`chordColumnExtent`), not from the row's real duration — a chord symbol is far more
     compact per bar than the words a singer fits into that bar, so a same-duration
     instrumental row rendered a fraction of a sung row's width. Fixed: keyed to
     `lineDuration * pixelsPerSecond` (the SAME scale rhythmic-mode sung lines use),
     falling back to the old character-extent sizing when rhythmic spacing is off.
  2. That fix initially did nothing: `lineStrip`'s `duration` was gated behind
     `instrumentalLane` (guitar/piano envelope) being loaded — an unrelated "is there a
     waveform to draw" concern bundled into the same guard, so it silently returned 0
     whenever no instrument stem was available/loaded at that call site. Decoupled: the
     row's time WINDOW resolves unconditionally; only the drawn peaks/color depend on a
     lane.
  3. Once width was time-based, chord glyphs (still positioned by column-fraction of the
     bar-grid text) clustered wrong. `lineStrip` now also returns the row's real start time;
     threaded through as `rowStartTime` on `ChordProPreviewBlockView`/`ChordProPreviewLineView`;
     `monospaceChordX` uses `(rowChordTimes[index] - rowStartTime) / lineDuration` when
     available. The flat "| . . |" bar-grid text can't stretch to the new width either, so
     it's hidden for instrumental rows once they're on the time-scaled axis (beat dots,
     already time-correct, remain as the structure indicator).
  - Verified live (Flip Flops, Settle Down): instrumental row widths now match/exceed
    adjacent vocal-line widths (previously ~65-90px vs ~230-515px); chords and beat dots
    spread across the full row instead of clustering left; no crash/regression.
- **Rhythmic Spacing toggle removed** (Eric: "always on"): `@AppStorage("rhythmicSpacing")`
  replaced with `private let rhythmicSpacing = true`; menu item deleted. Downstream code
  (three struct-level `var rhythmicSpacing = false` defaults + every conditional) left as-is
  since the parent always passes `true` now — minimal-impact, no behavior change to prune.
- Suite: same 568 tests, same 8 pre-existing AppModel env failures (verified twice, before
  and after this fix).
- **Build gotcha hit during this fix**: `xcodebuild build` via desktop-commander without
  `-derivedDataPath` wrote to a NEW DerivedData hash folder rather than the one the running
  app/Xcode.app uses — two rebuild+relaunch cycles showed zero visual change until caught by
  `stat`-ing the actual running binary's mtime. See tasks/lessons.md. Pin
  `-derivedDataPath` going forward.

## Fix: intro/outro bars rendering 2x too wide (2026-07-05, night)

- **Regression from the same evening's instrumental-row-width fix** (Eric, live: "Intro and
  outro bars are now twice as wide as they should be"), only now visible because that fix put
  chord-only rows on the real-duration `pixelsPerSecond` axis for the first time — the
  underlying bug existed before but was invisible under the old character-count sizing.
- **Root cause**: `WorkspaceEditorsView.chordOnlyLineWindow` splits a multi-row
  intro/instrumental/outro span into `1/rowCount` slices per row, counting `rowCount` by
  scanning `items` for consecutive chord-only rows via raw adjacent-index checks
  (`isChordOnlyRow(index - 1)` / `(index + 1)`). But `ChordProDraftBuilder` emits an
  `{x_chord_times: ...}` directive immediately before EVERY chord-only row (B5 round-trip
  carrier), so in `document.blocks`/`items` each row is actually 2 slots apart
  (directive, row, directive, row, ...), not 1. The raw adjacent check hit the directive and
  stopped immediately, collapsing every multi-row run to `rowCount == 1` — so each row
  claimed the ENTIRE gap instead of its slice.
- **Fix**: extracted the run-scan into a new, directly testable
  `ChordProPreviewIndexing.chordOnlyRunPosition(in:at:)` (`WorkspaceEditorsView.swift`) that
  walks past interleaved directive/comment blocks (anything that isn't a real sung lyric line
  or the array edge) instead of stopping at the first non-adjacent slot, and counts
  `position`/`rowCount` in actual-row hops rather than raw item-offset arithmetic (which would
  still overcount once directives are skipped). `chordOnlyLineWindow` now calls this shared
  function instead of inlining the (buggy) scan.
- Regression: `testChordOnlyRunPositionCountsConsecutiveRowsAcrossInterleavedDirectives`
  (3-row fixture mirroring the real directive/row/directive/row shape, asserts rowCount=3 and
  positions 0/1/2 — confirmed to fail with rowCount=[1,1,1] when reverted to the naive
  adjacent-index check) and `testChordOnlyRunPositionTreatsARealLyricLineAsARunBoundary` (two
  separate 1-row breaks either side of a sung line must not fuse into one false run of 2).
- Suite: 588 tests, same pre-existing `AppModelTests`/`MusicLibraryTests` environment
  failures. Lint clean. App rebuilt (pinned `-derivedDataPath`) and relaunched.

## Plan: "Structure" tab — Form / Harmony / Meter / Rhyme / Melody-proxy (2026-07-06)

Eric's proposal: separate a song's *structure* from its *content* — Form (section
order), Harmony (chord progression), Melody (phrase pattern e.g. AABA), Meter (lyric
syllable pattern), Rhyme (end-rhyme scheme), Lyrics (actual words) — then model each
recurring section as a reusable **Phrase Template** (chord pattern + meter + rhyme
scheme) that instances are checked against. Deviation from the fitted template is a
much stronger anomaly signal than today's per-subsystem heuristics, and would have
caught 2 of the 3 bugs found in the Key West Bar review by hand (short tag-line
misfire, run-on word-stealing) plus the word-doubling class of bug (a line running to
2x its section's normal syllable count is an obvious tell). Confirmed scope with Eric:
Phase 1 ships Form + Harmony + Meter + Rhyme together (not staged), Melody is an
approximate proxy (chord-pattern + meter + rhyme similarity across lines), clearly
labeled as approximate in the UI since there's no real pitch-contour pipeline.

Researched current architecture first (read-only subagent) so this plan targets real
code, not assumptions:

- `SongStructureAnalyzer.vocalSections(for:)` (`ChordProDraftBuilder.swift:795-926`)
  already gives Verse N / Chorus labels + `isProbableContinuation` (today's fix). Only
  `.verse`/`.chorus` kinds — no Intro/Bridge/Solo/Outro distinction.
- Intro/Instrumental/Outro detection is inline in `ChordProDraftBuilder.build(...)`
  (~lines 170-305), bars-based (`gapBars >= 4`), independent of `SongStructureAnalyzer`.
  **No merged whole-song ordered Form list exists yet** — must assemble one from both.
- **No Roman-numeral/scale-degree math exists anywhere.** `MusicalKey.swift` has the
  pitch-class name table (line 16-18) and a private `parseChord(_:)` (line 63-88) to
  reuse for chord-root/quality extraction.
- **Syllable counting and rhyme detection already exist and are unit-tested**:
  `SyllableCounter.swift`, `RhymeDetector.swift` (loads bundled
  `Resources/cmudict_rhyme.tsv`), `RhymeSyllableScorer.swift`, already consumed by
  `LyricPhraseGrouper.swift`. Meter/Rhyme layers reuse these directly — no new phonetic
  code needed.
- UI tabs are a `Picker` over `EditorTab` (`WorkspaceEditorsView.swift:10-35`), state in
  `ContentView.swift:230`, switched view in `WorkspaceEditorsView`. `ChordProReadOnlyView`
  is the closest sibling (read-only, takes a plain rendered string). `SongTimeline` is
  computed on demand by `ChordProDraftBuilder.buildResult(...)` and memoized in
  `AppModel` by source-string cache key (`AppModel.swift:2109`, `songTimelineForPreview()`
  at 2110-2134) — not persisted into the saved analysis JSON. Follow the same pattern:
  derive, don't persist.

### Steps
- [x] New `SongStructureOverview.swift`: `FormSection` (label, kind incl. new
      `.intro/.bridge/.solo/.outro/.instrumental` alongside existing verse/chorus,
      start/end), assembled by merging `SongStructureAnalyzer.vocalSections` with the
      existing bars-gap instrumental detection into one ordered list. Bridge/Solo rule
      (per Eric — "a word-less verse or chorus pattern is usually a solo"): an
      instrumental gap classifies as **Solo** when its chord progression matches an
      already-established Verse/Chorus template's chord pattern over the corresponding
      bar span (i.e. it's that section played wordless) — reuses the same
      chord-pattern-matching the Phrase Template step below needs, no separate
      duration heuristic required. A gap that matches no known template stays generic
      **Instrumental**. **Bridge** is a worded, non-repeating section that doesn't
      match the verse or chorus template. Ship as best-effort v1, expect retuning
      once checked against more real songs.
- [x] Roman-numeral mapping: new small function (on `MusicalKey` or a new
      `RomanNumeralMapper`) — chord root pitch class vs. key root → scale degree,
      quality-aware casing (upper/lower/°/+), reusing `MusicalKey.parseChord`. Chords
      that don't classify cleanly (secondary dominants etc.) fall back to bare
      chord-letter display rather than a wrong numeral.
- [x] Meter: per section, syllable count per lyric line via existing `SyllableCounter`.
- [x] Rhyme: per section, end-rhyme letters (A/B/C/D) per line via existing
      `RhymeDetector`/`RhymeSyllableScorer`.
- [x] Melody proxy: per section, build a per-line signature (chord-pattern hash +
      syllable count + rhyme letter, tolerant match not exact), assign phrase letters
      (A/A/B/A) by first-appearance order within the section. Label as approximate
      in the UI — this is not real melody analysis.
- [x] Phrase Template assembly: for each repeated section kind, pick a canonical
      occurrence and report {length in lines, phrase pattern, chord pattern, lyric
      meter, rhyme} — matches the shape of Eric's Key West Bar example (FORM +
      VERSE TEMPLATE + CHORUS TEMPLATE blocks).
- [x] New read-only `SongStructureView.swift` + `EditorTab.structure` case, wired into
      the same `Picker` as the Review tab; `AppModel.songStructureOverview()` memoized
      the same way as `songTimelineForPreview()` (derive on demand, no cache-migration
      concerns).
- [x] Tests: new `SongStructureOverviewTests.swift` — Roman-numeral cases (incl.
      secondary-dominant fallback), Form-list assembly (vocal + instrumental merge),
      melody-proxy phrase-letter assignment on a synthetic 4-line verse fixture,
      template assembly picking the canonical occurrence. Reuse existing
      `TimedLyricSegment`/`EditableChordEvent` fixture conventions.
- [x] Verify: build, full suite (expect only the pre-existing ~8 AppModelTests/
      MusicLibraryTests env failures), lint, rebuild+relaunch app, eyeball the tab
      against Key West Bar's real data.

## Review (2026-07-06)

Implemented as planned, in one new source file plus small additions:
- `SongStructureOverview.swift`: `SongStructureOverview`/`Section`/`PhraseTemplate`,
  `RomanNumeralMapper` (own small chord-root parser, deliberately separate from
  `MusicalKeyEstimator.parseChord` — didn't touch that already-tested internal),
  `MelodyPhraseProxy`, `SongStructureOverviewBuilder`. Form reuses
  `LyricSectionDeriver.sections` (already merges vocal + instrumental/intro/outro into
  one ordered list — no new merge logic needed there). Bridge/Solo reclassification
  and Phrase Template assembly share one `chordSignature`/`signaturesMatch` comparator
  (exact match, or ≥0.75 Jaccard set-overlap fallback for a single passing chord).
- `AppModel.songStructureOverview()`: cached by `chordProSource` like
  `songTimelineForPreview()`, but simpler (no byte-for-byte round-trip check needed).
- `EditorTab.structure` + `SongStructureView.swift`: read-only, mirrors
  `ChordProReadOnlyView`'s shape (plain scroll, no edit chrome), renders FORM plus a
  template card per repeated worded section kind.
- Tests: 11 new (`RomanNumeralMapperTests`, `MelodyPhraseProxyTests`,
  `SongStructureOverviewBuilderTests` — the last using a hand-built fixture with two
  matching-chord verses, a wordless gap reusing the verse pattern (→ Solo), and a
  worded section with an unrelated pattern (→ Bridge, not "Verse 3")). All passed on
  first run — no red/green needed since nothing existing was being changed.
- Suite: 601 tests, same 8 pre-existing `AppModelTests`/`MusicLibraryTests`
  environment failures, nothing new. Lint clean repo-wide.
- Live-verified on Key West Bar (real data, rebuilt app via `tuist generate` +
  pinned-`-derivedDataPath` `xcodebuild`): Form correctly lists Intro/Verse 1-4/
  Chorus×4/Instrumental/Outro matching the song's real structure, including the short
  ~4s "Verse 3" (the tag-line block task #14 fixed). VERSE/CHORUS templates render
  with real chord/meter/rhyme data. No Bridge/Solo triggered on this song's real
  (noisier) chord data — plausible given the exact/0.75-Jaccard match is tuned against
  clean synthetic data; flagged in the plan as expected v1 retuning territory, not
  treated as a bug.
- **Environment note**: `.build/checkouts` got corrupted mid-session (two ` 2`-suffixed
  duplicate checkout dirs, stale `workspace-state.json`) — almost certainly a
  concurrent process (the iPad-support work landing at the same time) touching the
  same SwiftPM cache. Fixed by removing the duplicates + `workspace-state.json` +
  `repositories` and re-running `swift package resolve`. See `tasks/lessons.md`.

---
# (previous) Align to Reference Lyrics — done 2026-06-25, see git history for details
