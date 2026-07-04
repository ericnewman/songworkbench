# Design: Phrase-Structure Lyric Grouper (backlog #9)

Status: Design / scope only. No code in this pass.
Author: design session, 2026-07-04. Batch C, item #9.
Builds on an already-approved sketch in `tasks/todo.md:374-395` (2026-07-01) — this doc
fleshes that sketch out against the current pipeline (concurrency, versioning, and the
`SongStructureAnalyzer` coupling risk it didn't originally account for) before any code
lands.

---

## 1. Summary

Today, lyric lines are formed by `TimedLyricSegmentGrouper` (`Transcription.swift:191-669`)
purely from ASR signals: capitalization, silence gaps, punctuation, and the transcriber's
own segment boundaries. It has no notion of the song's *musical* structure — two lines
sung over an identical repeating chord phrase can end up different lengths, split at
different points, or drift out of alignment with the bar grid, purely because Whisper/
Parakeet's word timings jittered slightly between the two passes.

**Goal:** add a `LyricPhraseGrouper`, a **post-pass** that re-segments a song's lines using
musical structure — repeating bar-period, and (later) rhyme/syllable-count similarity —
so that verse lines read as musically even, bar-aligned phrases, matching how a musician
would actually write them out. It runs **after** both transcription and harmony finish
(see §2 for why this must be a post-pass, not a change inside `TranscriptionStage`), only
when a confident musical period is found, and always falls back to the existing lexical
grouping when it isn't.

This does **not** replace `TimedLyricSegmentGrouper` — it consumes its output and can
further re-segment it. The existing grouper's hallucination gates, phrase-repair, and
anti-orphan merges (tuned over several sessions per `lyric-grouping-and-analysis-cache`
project memory) stay exactly as they are; this pass never undoes them (§4 guards).

---

## 2. Why this must be a post-pass (not inside `TranscriptionStage`)

`SongAnalysisPipeline.swift:253-254` dispatches transcription and harmony as **sibling
concurrent tasks over the same document snapshot**:

```swift
async let transcriptionOutcome = TranscriptionStage().run(transcriptionContext)
async let harmonyOutcome = HarmonyStage().run(harmonyContext)
let (transcription, harmony) = await (transcriptionOutcome, harmonyOutcome)
```

`document.beatTimes`/`document.chords` are only populated by `HarmonyStage`, which
`TranscriptionStage` cannot see mid-run — they run at the same time, not one after the
other. So a bar-period-aware grouper cannot live inside `TranscriptionStage` as written
today; it must run **after** both stages complete, consuming their combined output. This
matches the original note's own instinct ("applied in `AppModel.applyAnalysis` AFTER
regroup when beats+chords exist") and matches the codebase's existing pattern for
"beat-aware lyric logic" — `ChorusChordConsensus` and `LyricLineDiagnostics` are both
already post-pass consumers of finished lyrics + finished harmony, not stage-internal
logic. `LyricPhraseGrouper` follows the same shape, not a novel one.

---

## 3. Architecture

### 3.1 New component

| New type | Role |
| --- | --- |
| `LyricPhraseGrouper` (pure, `Sendable`, fully unit-tested) | Takes already-grouped `[TimedLyricSegment]` (post `TimedLyricSegmentGrouper`/`regroup`) + `beatTimes` + `tempo` + `[EditableChordEvent]`, returns a possibly-re-segmented `[TimedLyricSegment]`. No-ops (returns input unchanged) when no confident period is found. |
| `PhrasePeriodDetector` (private to the grouper, or a nested type) | Bar-period autocorrelation over per-bar chord labels — Stage 1 below. |
| `RhymeSyllableScorer` (Stage 2, later phase) | Scores candidate boundary cuts by end-rhyme + syllable-count similarity to sibling lines. |

### 3.2 Where it's invoked

`AppModel.applyAnalysis` (the same place `TimedLyricSegmentGrouper.regroup(...)` already
runs as a migration/regroup step per `lyric-grouping-and-analysis-cache` memory) gains one
more step, run immediately after the existing regroup and gated on `document.beatTimes`/
`document.chords`/`document.estimatedBPM` all being non-empty:

```
TimedLyricSegmentGrouper.regroup(...)          // existing, unchanged
  → LyricPhraseGrouper.regroup(                 // NEW
        lyrics: document.lyrics,
        beatTimes: document.beatTimes,
        tempo: document.estimatedBPM,
        chords: document.chords)
  → rebuildGeneratedChordProDraft() (skips user-reviewed charts, as today)
```

Called both on fresh analysis and on-load migration (same dual entry point
`TimedLyricSegmentGrouper.regroup` already has), so existing songs adopt this the next
time they're opened — no forced re-analysis.

### 3.3 Stage 1 (this pass): bar-period re-segmentation

1. **Detect the repeating phrase period**, in bars, from the song's per-bar chord label
   sequence (reuse `MeasureGrid` to bucket `document.chords` events into bars). Try
   candidate periods {2, 4, 8} bars via autocorrelation of the bar-label sequence (highest
   self-similarity at a lag wins; default to 4 bars if no candidate clears a confidence
   floor — most pop/rock verses are 4- or 8-bar phrases).
2. **Lay phrase boundaries** at `section downbeat + k * period * barSeconds` for each
   contiguous *vocal section* (using `SongStructureAnalyzer.vocalSections` output as the
   section spans to operate within — see §4 for why section boundaries are a hard fence,
   never crossed).
3. **Re-segment each section's words** into one line per phrase cell: take the union of
   all `TimedLyricWord`s already inside that section (from the existing grouper's lines),
   and re-cut them at the word GAP nearest each computed phrase boundary (never mid-word;
   snap to the nearest existing inter-word silence within the section).
4. Only apply within a section when its confidence (period autocorrelation score AND
   enough bars to judge, e.g. ≥2 full periods) clears a floor; otherwise leave that
   section's lines exactly as the existing grouper produced them. This is a per-SECTION
   decision, not all-or-nothing for the whole song — a song can have some sections
   re-segmented and others left alone.

### 3.4 Stage 2 (refinement, later phase): rhyme + syllable scoring

Once Stage 1 places candidate boundaries, score nearby alternative cut points (within
roughly ±1 beat of the bar-period boundary) by:
- **End-rhyme** — does the line ending at this cut rhyme with sibling lines' endings in
  the same section? (Needs a rhyme model — see §5, this is new subsystem weight.)
- **Syllable-count similarity** — is this line's syllable count close to its siblings'
  median? (Needs a syllable counter — also new, §5.)

Nudge the boundary to the locally-best-scoring nearby word gap. This is explicitly framed
as a *refinement* on top of Stage 1's bar-period cut, not a replacement — Stage 1 alone
already delivers the primary value (musically-even, bar-aligned lines) with materially
less new code and no new linguistic subsystem. Recommend shipping Stage 1 first and
evaluating whether Stage 2 is worth its cost afterward (§7).

---

## 4. Guards — do not regress the existing, already-tuned pipeline

This is the most important section of this doc; the existing grouping pipeline has been
tuned incident-by-incident over multiple sessions (anti-orphan merges, phrase-repair,
hallucination gates, trailing-tail pruning — `lyric-grouping-and-analysis-cache` memory),
and a naive post-pass could silently undo any of it.

- **Never cross a vocal-section boundary.** Re-segmentation happens strictly WITHIN one
  `SongStructureAnalyzer.VocalSection` at a time. A phrase-period cut is never allowed to
  merge material across a verse/chorus boundary.
- **`SongStructureAnalyzer` chorus detection depends on line-boundary determinism across
  repeats.** It flags "chorus" via whole-line word-set Jaccard similarity (≥0.7) between
  occurrences (`ChordProDraftBuilder.swift:777-844`). If `LyricPhraseGrouper` re-segments
  two musically-identical chorus repeats slightly differently (e.g. due to beat-grid
  jitter between the two sung passes), their word sets diverge and chorus detection can
  silently regress for songs that used to detect correctly. **Concrete guard: run
  `LyricPhraseGrouper` on each chorus's constituent sections using ONE shared computed
  period + phase (derived from the section with the highest confidence, or a song-wide
  period if sections agree), not independently per-occurrence** — so repeats of the same
  chorus get identical relative cut points whenever their underlying bar counts match. Add
  a regression test: two near-identical chorus occurrences with slightly different word
  timings must still re-segment to matching line counts/boundaries (relative to their own
  section start), and `SongStructureAnalyzer.vocalSections` must still detect them as the
  same `Chorus` kind after regrouping.
- **Never undo the existing grouper's hallucination/garbage-line removal.** Everything in
  `TranscriptionStage.run` (`VocalHallucinationGate`, `TrailingLyricTailPruner`,
  `TrailingDuplicateLineCollapser`, `TrailingEarlierLyricRepeater`,
  `IntraLinePauseSplitter`, `RepeatedLyricCorrector`) has already run and produced the
  `[TimedLyricSegment]` this grouper receives. It must only re-cut WHERE words already
  exist — it cannot resurrect removed material, and it cannot re-merge a line
  `IntraLinePauseSplitter` deliberately split at a real unvoiced pause (re-segmentation
  works within a section's existing word set, not by re-running earlier gates).
  Regression tests should include a fixture combining a hallucination-gated section with
  an adjacent real section, confirming the gated content stays gone after regrouping.
- **Bound line length by the existing caps** (`maximumDuration`=15s, `maximumTokens`=32,
  from `TimedLyricSegmentGrouper.Configuration`) so a mis-detected period can't produce a
  degenerate line.
- **No-op, loudly, on low confidence.** When no section clears the confidence floor, the
  song's lines are returned completely unchanged from the existing grouper's output —
  this is the safe default and should be the common case for songs without a clean,
  regular bar structure (live recordings, rubato passages, spoken-word sections).

---

## 5. New subsystem weight: syllable counting + rhyme detection

Confirmed via repo-wide search: **no syllable, rhyme, or phoneme code exists anywhere in
this codebase today.** Stage 1 (bar-period only) needs neither and should be built first
for exactly this reason — it delivers the primary value with zero new linguistic
dependencies. Stage 2 requires:

- **Syllable counting** — realistically a vowel-cluster heuristic (count vowel groups,
  adjust for silent trailing "e", diphthongs) rather than a full dictionary; English
  heuristics get "close enough" accuracy (~85-90%) for a *relative similarity* score,
  which is all Stage 2 needs (we're comparing lines to their siblings' median, not
  reporting an exact count to the user).
- **Rhyme detection** — needs at minimum a phonetic-ending comparison. Options range from
  a bundled CMUdict-derived table (accurate, adds a resource file + lookup) to a crude
  orthographic-suffix heuristic (free, much less accurate — English spelling doesn't
  reliably encode rhyme). This is a real scope/quality trade-off to make explicitly before
  Stage 2 starts, not something to decide implicitly while coding.

Recommendation: treat Stage 2 as a separate, later decision point (§7) once Stage 1 has
shipped and been used on real songs — evaluate whether bar-period alone already produces
good enough lines before taking on rhyme/syllable subsystem weight.

---

## 6. Versioning / migration

Follow the exact existing pattern (`AnalysisStage.swift:332-348`): the raw ASR
transcription cache stays keyed independent of grouping-rule changes (never re-transcribe
just because grouping changed); the STAGE RECORD's version string gets a suffix bump
(current tag: `grouping-41-keep-voiced-tail`) whenever grouping rules change, so existing
songs re-derive their lines from the cached raw transcription on next open.

**New wrinkle this item introduces:** `LyricPhraseGrouper` depends on TWO other stages'
outputs (lyrics AND chords/beats), and there is no existing precedent in
`AnalysisStage.swift` for a stage/pass whose staleness depends on more than one upstream
stage's version. Concretely: if only `HarmonyStage`'s chord-detection logic changes (not
transcription), does the persisted lyric-grouping stage record need to be treated as stale
too, since `LyricPhraseGrouper`'s bar-period detection would produce different results
against the new chords? **This needs an explicit decision before implementation**: either
(a) fold a harmony-derived digest (e.g. a hash of `document.chords`) into the lyric stage
record's version alongside the grouping-tag suffix, so a harmony change also triggers
lyric re-derivation, or (b) accept that a harmony-only re-analysis won't retroactively
re-run phrase-structure grouping until the next lyric-affecting change, documented as a
known limitation. Recommend (a) for correctness, flagged here since it's new plumbing, not
a copy-paste of the existing single-stage-version pattern.

---

## 7. Phased implementation plan

**Phase 1 — Stage 1 only (bar-period re-segmentation).** Recommended first and possibly
only phase pending real-song evaluation.
- `LyricPhraseGrouper` + `PhrasePeriodDetector`, wired into `AppModel.applyAnalysis` as
  described in §3.2, with all §4 guards and regression tests (chorus-determinism,
  hallucination-gate non-regression, section-boundary fence, low-confidence no-op).
- Unit tests: period autocorrelation on synthetic ABAB/AABB chord-bar sequences,
  re-segmentation at computed boundaries, fallback on no-period, the chorus-determinism
  regression test from §4.
- Verify on a real song analyzed in Accuracy mode (per the original note): re-analyze,
  eyeball verse lines for even length + bar alignment, confirm ChordPro draft regenerates
  cleanly, confirm `SongStructureAnalyzer` still labels the same sections the same way
  before/after.
- Bump the grouping version tag (`grouping-42-phrase-structure` or similar) per §6,
  resolving the two-stage-dependency versioning question from §6 before landing.

**Phase 2 — Stage 2 (rhyme/syllable refinement).** *Only after Phase 1 ships and is
evaluated on real songs* — decide then whether the added linguistic-subsystem weight
(§5) is worth it versus Stage 1 alone.
- `RhymeSyllableScorer`, nudging Stage 1's boundaries within a bounded window.
- Requires an explicit choice on rhyme-detection approach (bundled phonetic table vs.
  orthographic heuristic) before starting — not a decision to make implicitly mid-build.

**Recommended first step: Phase 1 alone**, in its own Batch C worktree, independent of
items #10 and #11.

---

## 8. Open questions for Eric before Phase 1 starts

1. Confirm the versioning approach for §6 (fold a chords-digest into the lyric stage
   record's version, vs. accept the documented limitation).
2. Confirm Phase 1 (bar-period only) is the right scope to ship first, with Phase 2
   explicitly deferred pending real-song evaluation — matches the "Stage 1 now, Stage 2
   later" framing above, but worth confirming before committing.

---

## 9. Review — Phase 2 done (2026-07-04, own worktree `backlog/phrase-grouper-phase2`)

Eric asked to proceed with Phase 2 directly (ahead of the "wait for real-song evaluation"
recommendation in §7) and confirmed the rhyme-detection approach: **bundled phonetic table**
(CMUdict-derived), not the orthographic-suffix heuristic.

- `Resources/cmudict_rhyme.tsv` (126,052 entries, 2.4 MB): word → rhyme part (phonemes from the
  last PRIMARY-stressed vowel to the end, stress digits stripped), derived from
  `cmudict.dict` (cmusphinx/cmudict, Carnegie Mellon University, BSD-style license — full notice
  in the file header). Only the first-listed pronunciation per word is kept; variant markers like
  `word(2)` fold into the base word.
- `SyllableCounter` (new, pure): vowel-cluster + silent-trailing-"e" heuristic, no bundled data.
  §5's predicted ~85-90% accuracy confirmed against a curated word list; one known miss
  ("smile" → 2, not 1) is locked in by an explicit test rather than silently accepted.
- `RhymeDetector` (new, pure lookup + `Bundle.main`-backed `.shared` singleton): `rhymePart(for:)`,
  `rhymes(_:_:)`, and `bestRhymeScore(for:against:)` — the last distinguishes "confirmed non-rhyme"
  (`0.0`) from "no evidence" (`nil`, when either word is out-of-vocabulary) so Stage 2 never lets
  missing data masquerade as a real signal. Degrades to an empty table (never crashes) if the
  bundled resource is missing/unreadable, including inside the unit-test host (which has no app
  bundle to read `Resources/` from).
- `RhymeSyllableScorer` (new, pure): given Stage 1's boundary and a caller-supplied set of nearby
  real word-gap candidates (plus the section's OTHER cells' endings/syllable counts as siblings),
  picks the best-scoring candidate — weighted end-rhyme (0.6) + syllable-count similarity to the
  sibling median (0.4), only moving away from the nearest-in-time candidate when it clears a
  `minimumImprovement` margin (0.05 default). Ties, missing sibling data, or a total absence of
  rhyme/syllable signal all keep Stage 1's own choice.
- Wired into `LyricPhraseGrouper.resegmented`: Stage 1's per-boundary nearest-gap snap is computed
  first (unchanged), then Stage 2 nudges each boundary independently within a `nudgeWindowInBeats`
  (1 beat default, bounded by the existing half-period max-snap-distance) window, fenced strictly
  between the neighboring boundaries' BASELINE (not post-nudge) cuts — guarantees cells stay
  ordered/non-overlapping regardless of how any individual boundary moves. A defensive collision/
  inversion check falls back to the unmodified Stage 1 cut set if that invariant were ever
  violated (should be unreachable given the fencing, kept as a belt-and-suspenders net). The
  trailing cell (after the last real cut, running to the section's end) is always included as a
  sibling for every OTHER boundary's decision, even though it never has a decision of its own.
- New `LyricPhraseGrouper.Configuration` fields: `refinementEnabled` (default `true`),
  `nudgeWindowInBeats` (default `1`), `rhymeSyllableConfiguration`. `regroup` gained a
  `rhymeDetector: RhymeDetector = .shared` parameter — existing call sites (incl.
  `AppModel.applyAnalysis`) are unaffected by the new defaults.
- **No version-tag bump needed.** `LyricPhraseGrouper.regroup` is still the same unconditional
  post-pass Phase 1 already made version-tag-free (§6 resolved by "always rerun," not by digest
  plumbing) — Phase 2 is new logic inside the SAME always-rerun call, so every song picks it up
  automatically the next time it's opened, with zero additional plumbing.
- Tests: `SyllableCounterTests` (6), `RhymeDetectorTests` (11), `RhymeSyllableScorerTests` (7),
  plus 3 new `LyricPhraseGrouperTests` integration cases on a hand-timed 3-cell fixture proving:
  (a) Stage 2 nudges to a farther-but-better-scoring real word gap using the full rhyme+syllable
  table, (b) `refinementEnabled: false` reproduces exactly Stage 1's original cut, (c) syllable
  evidence ALONE (empty rhyme table) is sufficient to nudge, isolating that signal from rhyme.
  All existing Phase 1 tests are unaffected because every one of their fixtures has exactly one
  internal boundary per section (Stage 2's `>= 2 boundaries` gate keeps it a no-op there).
- Verification: see `tasks/todo.md` "Phrase-structure lyric grouper Phase 2" entry for the real
  `xcodebuild test` results (Mac toolchain, via Desktop Commander).
