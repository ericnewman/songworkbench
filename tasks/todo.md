# Plan: Structure tab accuracy — Settle Down live review (Task #43, drafted 2026-07-07)

Eric live-reviewed the Structure tab on Settle Down and flagged 4 issues in one pass. All trace
to the same theme as Task #39 above: parts of `SongStructureOverviewBuilder`/`SongStructureAnalyzer`
lean on lyric-derived signals (line count, exact per-line text/chord equality) where a musically-
grounded, tolerant signal would be more robust.

## A. Verse 3/Verse 4 should be one Bridge — CONFIRMED by Eric, do first

Live data: FORM shows `Verse 3` (2:36-2:46, 2 lines: "thought I would slow down." / "But then I
saw her smile.") and `Verse 4` (2:46-2:55, 3 lines: "She turned my baby someday" / "I think" /
"I am gonna stay") as two separate sections, sandwiched between the 2nd Chorus and the
Instrumental. Every real verse/chorus in this song runs 6-9 lines / 20-50s; these two are 2-3
lines / ~10s each. Read together they're one continuous Bridge.

Root cause: `SongStructureAnalyzer.vocalSections` (ChordProDraftBuilder.swift) splits
unconditionally whenever `gap >= sectionGap` (4.0s) — the actual gap here is 4.38s, just over the
threshold, a natural mid-bridge breath, not a real section boundary. `reclassifyBridgeAndSolo`
(SongStructureOverviewBuilder) exists to relabel a verse-shaped section as Bridge by chord-pattern
mismatch, but never gets the chance because the two halves are never merged back into one section
first.

Eric confirmed target: Intro → Verse 1 → Chorus → Verse 2 → Chorus → **Bridge** → Instrumental →
Chorus → Outro.

Fix direction (not yet implemented): a gap-only split (no classification/kind mismatch) between
two ADJACENT same-kind, non-chorus blocks should require stronger evidence than a kind-change
split — kind changes carry their own independent evidence, a bare gap doesn't. Concretely: after
the existing block-flush loop, merge adjacent `.verse`-kind sections when the gap between them is
modest (not real Instrumental-scale) and at least one side is anomalously short vs. the song's
other verse-kind occurrences (reuse evidence already present in the computed `sections`, not a
fresh magic-number threshold). `sectionGap` itself must NOT simply move higher — that risks
merging genuinely separate verses in other songs (Key West Bar's "Yeah I need a break… in a Key
West bar" continuation test already covers the single-short-trailing-line case; this is the
sibling case of two-or-more short blocks each on their own line-count already, needs its own new
test). Needs a dedicated test fixture reproducing this exact 4-part shape (2 real verses, 1
fragmented-into-two bridge, gap = sectionGap + a hair) before landing.

## B. Chorus phrase pattern shows near-zero repetition (A B C D E F G H for 8-9 lines)

Eric: "the composition of the chorus lists many patterns A B C D E F G H etc. But there seem to
be a lot less than that, so maybe the criteria is off." Confirmed live: CHORUS TEMPLATE phrase
pattern is `A B C D E F G H` — essentially no two lines ever cluster as "the same phrase", which
doesn't match how a real chorus's melody works (a handful of repeating phrase shapes, e.g. AABA/
ABAB, not one-off letters per line).

Root cause: `MelodyPhraseProxy.phraseLetters` (SongStructureOverview.swift ~line 158) clusters
two lines as the same phrase only when their `chordSignatures` arrays are EXACTLY equal
(`$0.signature == signature`) and syllable count is within ±1. Real per-line chord windows
(`chords.filter { $0.time >= line.start && $0.time < line.end }`) pick up timing jitter/passing
chords, so two melodically-identical lines rarely produce byte-identical signature arrays — the
same brittleness `reclassifyBridgeAndSolo` already solved for section-level comparison via
`signaturesMatch` (Jaccard ≥ 0.75, tolerates one passing chord). Fix direction: make
`MelodyPhraseProxy.phraseLetters` cluster via the same tolerant `signaturesMatch`-style
comparison instead of exact `==`.

## C. Instrumental section chord patterns look noisy/ungrounded

Eric: "The chord patterns seem grounded in vocal melody, and go bad when it's instrumental." Live
data: Outro chord pattern alone lists ~19 chord symbols across 36s. Two possible root causes,
NOT yet distinguished:
  1. `buildInstrumentalSummaries`/`chordSignature` aggregation is fine, and the underlying chord-
     DETECTION itself (harmony analysis stage) is genuinely noisier without a vocal melody to
     anchor pitch tracking — a chord-detection-engine accuracy question, not a Structure-tab
     aggregation bug, and a much bigger separate investigation.
  2. Something in how instrumental-section chord windows are sliced/attributed IS a Structure-tab
     bug (distinct from A/B above).
Needs its own investigation pass (compare raw Chords-tab data for the Outro span against what's
displayed here) before deciding which. Do not conflate with A/B's fix.

## D. "Too much dependence on lyrics" in representative/canonical-length selection

Eric's broader callout, and the direct cause of a real bug already observed live: `buildTemplates`
picks each kind's canonical shape via `mostCommonInt(lineCounts)` (a lyric-line-count vote) and
`occurrences.first { $0.lines.count == canonicalLineCount }` for the representative. With Settle
Down's current (buggy, pre-A-fix) verse occurrences at line counts `[6, 4, 2, 3]` — all distinct,
no majority — `mostCommonInt` picks whichever key a Swift `Dictionary` iterates first on a
count-1 tie, which is UNSTABLE/unspecified order. Live-observed: this picked the 2-line Verse 3
fragment as the "representative" VERSE TEMPLATE (`Length: 2 lines`), corrupting the whole verse
template display. Once A is fixed the immediate symptom likely disappears (fewer/no ties), but
the underlying design smell remains: canonical-shape selection is keyed on a lyric-derived count,
not a musical one. Fix direction: prefer a musically-grounded tie-break (bar count/duration, or
matching the kind's majority CHORD pattern the way `reclassifyBridgeAndSolo` already does) over
lyric line count, or at minimum make the tie-break deterministic (e.g. longest duration, or
earliest occurrence) instead of dictionary-iteration-order.

## Suggested order

A first (confirmed, well-scoped, isolated to `SongStructureAnalyzer.vocalSections`) → D (small,
deterministic tie-break fix, verify A alone doesn't already resolve it) → B (isolated to
`MelodyPhraseProxy`) → C (separate investigation, likely bigger scope, decide after A/B/D whether
the symptom persists on a clean structure).

## Live verification (2026-07-07, Settle Down, commit `cd1aa74`, rebuilt app)

- **A confirmed working**: FORM now reads Intro → Verse 1 → Chorus → Verse 2 → Chorus →
  **Verse 3 (2:36–2:55, one continuous section)** → Instrumental → Chorus → Outro — the former
  Verse 3 (2:36–2:46) + Verse 4 (2:46–2:55) fragments merged into one, exactly as Eric confirmed
  he expected. Stayed labeled "Verse 3" rather than being promoted to "Bridge" by
  `reclassifyBridgeAndSolo` — expected/acceptable, since that promotion depends on this song's
  actual chord data clearing the signature-mismatch bar, which wasn't part of what Eric asked to
  fix (he confirmed the STRUCTURAL merge, not a guaranteed Bridge relabel).
- **D confirmed working**: VERSE TEMPLATE now reads `Length: 6 lines` (was `Length: 2 lines`,
  picking the anomalous fragment via an unstable line-count tie before this fix).
- **B mechanism correct but limited real-world impact on this song**: CHORUS TEMPLATE still shows
  `Phrase Pattern: A B C D E F G H` — unchanged. Unit tests confirm the tolerant (Jaccard >= 0.75)
  clustering works correctly on synthetic "one passing chord" jitter. Settle Down's REAL chorus
  chord pattern is far denser than that (~28 chord-signature entries across 9 lines, ~3 chords/
  line on average) — per-line signatures differ by MORE than one passing chord, so even the
  tolerant threshold can't bridge them. This is a strong signal that the underlying chord-
  DETECTION density/jitter itself (Task #46 / Issue C, already deferred as a separate
  investigation) is the deeper root cause behind BOTH the noisy instrumental chord patterns AND
  this residual chorus over-fragmentation — worth investigating together rather than raising
  `MelodyPhraseProxy`'s tolerance threshold in isolation (which would deviate from the
  `signaturesMatch` convention used elsewhere without addressing the real cause).

---
# Plan: music-structure-first lyric segmentation (Task #39, drafted 2026-07-07, NOT started)

Eric approved the direction ("1 Yes. 2 Yes. 3 Yes") — see
[[lyric-segmentation-music-first-direction]] in memory for the full quote/rationale. This is a
plan only. Confirm phasing before starting implementation (Eric's stated preference: plan first,
check in before implementing).

## Where things stand today (grounded in this session's reading, not assumption)

- `TimedLyricSegmentGrouper.group`/`.regroup` (Transcription.swift): text/gap/capitalization/
  comma-driven. Runs 3x independently per song (once per installed transcription mode) AND again
  unconditionally on every `AppModel.applyAnalysis` load. This is the ONLY grouping mechanism
  when just one transcription mode is installed (`runLyricBlendPasses` no-ops entirely when
  `otherModes` is empty — single-mode songs never touch the blend-row machinery at all).
- `LyricBlendRowBuilder` (backlog #11): clusters the (up to 3) modes' already-grouped lines into
  time-windowed rows; `onsetCorroboration`/`onsetPreferredMode` use REAL vocal-stem onsets
  (`InstrumentOnsetDetector.onsets(url:)` on the separated vocals stem) but ONLY to pick BETWEEN
  already-formed candidate rows' timing — never to cut a new boundary. This onset list is computed
  fresh inside `runLyricBlendPasses`'s Task and is NOT persisted in `SongAnalysisDocument` —
  needed for Phase B1 below.
- `LyricPhraseGrouper` (backlog #9 Phase 1): the ONE bar/rhythm-aware pass. Runs LAST, as an
  optional post-pass, gated behind `detectPeriod` finding >=2 full periods of >=0.75-confidence
  chord-per-bar autocorrelation WITHIN a single section OCCURRENCE. A section that occurs once
  (a lone Verse 2, a Bridge) can never produce that evidence and is left entirely to the
  text-driven grouper's output — exactly the gap that let the Settle Down bug through.
- `SongStructureOverviewBuilder` (Task #36, this session): ALREADY does cross-occurrence pooling,
  just for the Structure tab's display, not fed back into segmentation. `buildTemplates` takes the
  MAJORITY line count and a representative chord pattern across ALL occurrences of a kind
  (`mostCommonInt(lineCounts)`), and `reclassifyBridgeAndSolo` already compares each occurrence's
  chord signature against the kind's majority pattern (`chordSignature`/`signaturesMatch`, Jaccard
  >= 0.75). This is most of the "pool evidence across occurrences" machinery Phase B needs —
  reuse it rather than re-deriving cross-occurrence consensus from scratch in `LyricPhraseGrouper`.

## Phase A — done, committed (`9cd6f77`)

`segmentLineStart` capitalization-gate fix. Narrow, safe, ships regardless of everything below
since the text/gap grouper will still exist as the eventual fallback tier.

## Phase B — cross-section pooling + persisted vocal onsets

### Phase B2 — cross-section pooling — done, committed (`80a1f22`)

`LyricPhraseGrouper.regroup` now computes one pooled bar-label-self-similarity decision per
section KIND (verse, chorus) from every occurrence of that kind combined, instead of requiring
each occurrence prove its own period alone. Falls back to the old single-occurrence `detectPeriod`
only when the pool doesn't clear `minimumConfidence`. `totalBars` (not lag-period test-pair count)
gates `minimumFullPeriods`, so pooling is a strict superset of the old per-occurrence behavior when
a kind has only one occurrence (verified: all 11 pre-existing tests pass unchanged). New test
`testLoneVerseBorrowsThePeriodItsConfidentSiblingVersesEstablish` proves the actual new capability
end-to-end (a lone verse at 0.5 confidence alone borrows period 4 from siblings pooling to 0.833).
Full suite run: 600 tests, same 8 pre-existing failures (AppModelTests/MusicLibraryTests
song-library persistence/ordering — confirmed present identically with this change stashed out,
unrelated to lyric grouping) present with and without this change. Not yet live-verified against a
real song — planned alongside Phase B1/C live verification per the risks section below, since
pooling alone has limited visible effect until Phase C promotes it to primary.

### Phase B1 — persist vocal onsets in the schema (not started)

1. **Persist vocal onsets in the schema.** Add `SongAnalysisDocument.vocalOnsets: [TimeInterval]`
   (schemaVersion 12), computed via `InstrumentOnsetDetector.onsets(url:)` on the vocals stem once
   real stem separation completes (harmony/separation stage, wherever the stem file first becomes
   available — NOT recomputed on every load). Old songs: empty array until their next "Analyze
   Song" (or a lazy one-time backfill on load if a vocals stem file already exists on disk —
   decide which during implementation; lazy backfill avoids forcing a re-analysis just to gain
   this field, but adds load-time cost to every old song's first open).
2. **Feed `PhraseTemplate` (or an equivalent lighter derivation) into `LyricPhraseGrouper` as the
   period/line-count source of truth**, replacing `detectPeriod`'s single-occurrence-only
   autocorrelation. Concretely: for a section kind with >=2 worded occurrences, the majority line
   count (already computed by `SongStructureOverviewBuilder.buildTemplates`) implies a phrase
   period in bars (occurrence's own bar span / majority line count, rounded) — apply that period
   to EVERY occurrence of the kind, including ones with too little internal repetition to prove it
   alone (the exact Verse-2-borrows-from-Verse-1/3 case Eric asked for). A kind with only ONE
   occurrence ever (no cross-section evidence at all — a Bridge, most commonly) still falls back
   to `detectPeriod`'s existing single-occurrence autocorrelation, or to Phase C's fallback tier
   if that also fails.
3. New tests: a section that individually has zero repeat evidence but shares its kind with 2+
   confidently-periodic siblings gets segmented using the siblings' period. Regression coverage
   for the existing chorus-determinism guard (must still hold under pooled detection).

## Phase C — promote structure to primary, demote text grouping to fallback (not started)

1. **Boundary snapping switches from "nearest real ASR word gap" to "nearest real vocal onset."**
   `LyricPhraseGrouper.resegmented`'s Stage 1 currently snaps each computed phrase boundary to the
   nearest inter-WORD gap in the flattened ASR word stream (`gapMidpoint`, built from
   `lines.flatMap(\.words)`). Once vocal onsets are persisted (Phase B1), snap to the nearest real
   onset/silence instead — independent of whichever transcription mode's (possibly wrong) word
   timing happened to win the blend. Words still supply TEXT content; onsets supply WHERE a line
   starts. Existing Stage 2 rhyme/syllable nudge (`RhymeSyllableScorer`) still applies on top.
2. **Reorder the pipeline in `AppModel.applyAnalysis`**: run the (now pooled + onset-anchored)
   `LyricPhraseGrouper` pass FIRST wherever chord/beat/onset data exists for a section, and only
   fall back to `TimedLyricSegmentGrouper`'s text/gap/capitalization grouping for spans where beat
   structure genuinely can't be established (no chords/beats at all, or pooled+single-occurrence
   detection both fail confidence) — matches Eric's "lowest priority fallback when all else
   fails." This likely also changes where `TimedLyricSegmentGrouper.group` runs for the INITIAL
   per-mode transcription pass (right now every mode groups into lines before any music-structure
   input exists at all) — needs its own sub-design pass once B is proven out; flagged here so it
   isn't lost, not scoped in detail yet.
3. Word-to-cell assignment: once a phrase-cell's [start,end) is fixed by structure+onsets, bucket
   whichever transcription candidate's words fall in that time range into the cell (nearest-onset
   assignment, same fencing discipline `resegmented` already uses so cells stay non-overlapping) —
   replacing the current "trust the ASR engine's own line break, then just correct it after the
   fact" flow with "structure decides the box, ASR text fills it."

## Risks / open questions to resolve before Phase C lands

- Changing `LyricPhraseGrouper`'s trigger condition from "rare, high-confidence" to "primary,
  broadly-applied" means it will touch FAR more songs' lyrics than it does today — needs a wide
  live-verification pass (multiple real songs, not just Settle Down/Key West Bar) before treating
  it as done, per this project's established verify-live convention.
  `LyricBlendRowBuilder`/`LyricPhraseGrouper`/`TimedLyricSegmentGrouper` together have 100+
  existing tests; expect real churn there, not just additions.
- `TimedLyricSegment.reconciled`'s override/accepted-annotation carry-forward matches by time-
  window overlap — re-verify overrides still survive once cell boundaries move to onset-anchored
  positions (they'll shift slightly vs. today's word-gap-anchored positions).
- Onset detection quality varies by song (percussive/dense mixes vs. clean vocal stems) — decide
  a real confidence/fallback story for "onsets exist but are noisy" distinct from "no onsets at
  all," mirroring `LyricPhraseGrouper`'s existing "no-op, loudly, on low confidence" philosophy.

---
# Fix: segmentLineStart capitalization gate merges lowercase-starting lines (2026-07-07)

Task #37/#38. Eric: "In Settle Down, there are a lot of lines that contain multiple rhythmic
repeating patterns that should have been separate lines. Line 8 is a good example."

Root-caused via the real persisted analysis JSON (`~/Library/Containers/com.local.SongWorkbench/
.../songs/*.json`) and a temporary debug XCTest that called `TimedLyricSegmentGrouper.regroup`/
`LyricPhraseGrouper.regroup` directly on the real data (deleted after diagnosis, never committed):

- `lyricBlendRows` showed the raw candidates were CLEAN: "She makes me want to settle down,"
  [54.40,58.12] and "trading my rowdy friends for a one-horse town." [59.85/60.35,65.78/70.20]
  were two separate, multi-mode-agreed rows.
- `LyricBlendRowBuilder.effectiveLyrics(from:)` maps rows 1:1 to segments, so the ORIGINAL
  `document.lyrics` from a fresh analysis should have been 2 separate lines too.
- But `AppModel.applyAnalysis` unconditionally reruns `TimedLyricSegmentGrouper.regroup` (and then
  `LyricPhraseGrouper.regroup`) on `document.lyrics` on EVERY LOAD. Reconstructing the pre-merge
  2-segment state and feeding it through `TimedLyricSegmentGrouper.regroup` reproduced the exact
  merge live: `segmentLineStart` (the rule meant to force a break at an already-known line-start
  onset even across a short gap) ALSO required `beginsCapitalizedWord(token.text)`. The second
  line's first word, "trading", is lowercase, so the forced break silently didn't fire; the 2.2s
  gap is real but under `maximumGap` (3s) once segment structure is present, so nothing else
  caught it either — the two lines welded into one run-on line.
- This is why the bug is STICKY across reloads: once merged, the sub-boundary (60.35 as its own
  segment start) is gone from `lineStartOnsets` on the next regroup, so it can never self-heal —
  only a fresh "Analyze Song" (which rebuilds `document.lyrics` from `lyricBlendRows` via
  `effectiveLyrics`, bypassing the corrupted stored lyrics entirely) recovers the correct split.
- `LyricPhraseGrouper` (the one bar/rhythm-aware pass) never got a chance to help either: it
  requires >=2 full periods of confident (>=0.75) chord-per-bar autocorrelation WITHIN a single
  section occurrence, and this Verse 2 occurs once — no repetition evidence to detect a period
  from at all.

**Fix**: removed the `beginsCapitalizedWord` requirement from `segmentLineStart`
(`Transcription.swift`) — capitalization is not evidence either way for whether an exact
`lineStartOnsets` time match is a real boundary; requiring it defeated the rule's own purpose.
Added `testGroupingBreaksAtLowercaseSegmentLineStartWithoutRequiringCapitalization` reproducing
the exact field tokens/onsets as a permanent regression test.

**Verification**: `swift format lint --strict`, `swift build`, `swift test` (51/51
`TranscriptionTests` incl. the 3 tests that already exercised `segmentLineStart`-adjacent
behavior via other mechanisms — conjunction-continuation and leading-orphan merging, confirmed
unaffected since those fire regardless of this flag; full suite 599 tests, same pre-existing
8-failure baseline, nothing new). Rebuilt the macOS `.app`, re-ran "Analyze Song" live on Settle
Down (a stale already-merged song can't self-heal on load per the mechanism above — needed a
fresh analysis pass to rebuild `lyrics` from `lyricBlendRows`): both previously-merged lines now
render as clean separate lines ("She makes me want to settle down," / "trading my rowdy friends
for a one-horse town." at [54.40,58.12]/[60.35,65.78], and the analogous Verse 4 occurrence at
[128.08,133.76]/[133.89,138.44]).

## Bigger picture: this is a symptom, not the disease

Eric's follow-up, verbatim: "It still feels like we're adding structure to the found lyrics,
centering on the words as the most important factor. We need to prioritize the music, the beat,
the rhythm, and the structure, then find the most likely lyric for each beat of the song. The
Vocal track onset gives us strong clues as to where the words go, but [we should not let word-
level heuristics] ignore the structure. It has to be musical first and foremost."

Confirmed by this investigation: bar/rhythm structure (`LyricPhraseGrouper`) exists in this
codebase but is a weak, LATE, optional correction layer — gated behind strict per-occurrence
repetition evidence a single verse can never produce alone — while everything upstream (all 3
transcription modes' own line grouping, and the reload-time regroup) is purely text/punctuation/
gap-driven, and vocal onset (`LyricBlendRowBuilder.onsetCorroboration`) is only used to pick
BETWEEN already-formed candidates, never to cut a boundary from scratch.

Eric approved, verbatim ("1 Yes. 2 Yes. 3 Yes - lowest priority fallback when all else fails"):
1. Cross-section/cross-song pooling for bar-period detection (a lone Verse 2 borrows the phrase
   period its sibling verses establish, instead of requiring each occurrence prove its own).
2. Promote bar/beat grid + vocal onset to the PRIMARY line-boundary driver; demote the text/gap/
   capitalization grouper (`TimedLyricSegmentGrouper`) to a fallback used only where beat
   structure can't be established at all (rubato, spoken-word, no chord/beat data).
3. Ship this session's capitalization-gate fix now regardless (done, above) — it's the correct
   behavior for whatever the fallback ends up covering either way.

See Task #39 for the phased implementation plan (drafted, not yet started).

---
# Structure-alignment anomaly detection (2026-07-07)

Task #36. Eric: "I'm curious how we can tell performance with alignment to the established song
structure. It seems like enforcing some level of alignment would have caught these bugs sooner,"
followed by "When we have rhyming sentences, it seems like they would be separate lines, and not
concatenated. So there are other mechanisms we should use to validate the final version."

Added `StructureAlignmentDiagnostics` (`SongStructureOverview.swift`), a pure validation pass
that compares each section occurrence's actual lines against its established `PhraseTemplate`
(built earlier for the Structure tab from Meter/Rhyme/chord-pattern data already computed by
`SongStructureOverviewBuilder`):

- **Line-count mismatch**: if a section occurrence has a different number of lines than its
  template, position-by-position comparison isn't meaningful — flagged as a whole (on the first
  line) with the counts, since a mismatch is itself strong evidence a line was merged or split.
- **Meter + rhyme deviation**: when counts match, each line's syllable count (`SyllableCounter`,
  already exposed as `syllableCount(for:)`) and its established RHYME PARTNER (the other line
  position the template's `rhymeScheme` pairs it with) are checked independently. A line is only
  flagged when BOTH deviate — off-meter alone or a fresh rhyme alone is ordinary songwriting
  variation; both together is a strong tell something got merged, split, or mis-transcribed.
  Chord-event-count-per-line is folded in as a third, corroborating (non-required) signal.
- Rhyme comparison deliberately does NOT compare the letter LABELS in `PhraseTemplate.rhymeScheme`
  directly (`"A"`/`"B"`/…) — those are assigned positionally, fresh, on every call, so two
  independently-computed schemes can coincidentally collide on the same letter at the same index
  without meaning the same phonetic class. Instead it re-checks the actual current words at the
  template's established PARTNER positions via `RhymeDetector.rhymes(_:_:)` directly.
- `SongStructureOverviewBuilder.syllableCount(for:)` and `.rhymeScheme(for:lines:detector:)` were
  un-privated for reuse; `PhraseTemplate` gained a `chordCountPattern: [Int]` field (free from
  `buildTemplates`'s existing `perLineChordSignatures`).
- Wired into the Lyrics tab by MERGING into the existing `showSuspectFlags`/"Review Flags" review
  mechanism (`TimedLyricsEditor.suspectReasons` in `WorkspaceEditorsView.swift`) rather than
  building new UI — same toggle, same warning-triangle icon, same tooltip; a line flagged by both
  the acoustic beat-grid heuristic and the new structural one gets both reasons concatenated.
  Distinct from (and complementary to) `ReviewConfidenceTier`'s per-word ASR-confidence tint,
  which is an acoustic signal, not a structural/linguistic one.

**Testing note**: the SPM test bundle doesn't host the app target's `Resources/`, so
`RhymeDetector.shared` resolves every word to "no entry" in `swift test` (see the pre-existing
`RhymeDetectorTests`'s own hand-built-table workaround). Made `rhymeScheme(for:detector:)` and
`StructureAlignmentDiagnostics.anomalies(in:detector:)` accept an injectable `RhymeDetector`
(default `.shared`, zero production behavior change) so tests can supply a small hand-built table.
Also constructed `SongStructureOverview` test fixtures directly (`Section`/`PhraseTemplate`
struct literals) rather than round-tripping through the full builder pipeline — `Section`-
detection heuristics (`SongStructureAnalyzer`'s word-Jaccard chorus/verse classifier) misfire on
synthetic fixtures that intentionally repeat lines verbatim across occurrences (reads as a real
chorus repeat), which is already covered by `SongStructureOverviewBuilderTests` and isn't this
feature's job to re-verify.

## Live re-verification (incidentally re-covers Task #35)

Rebuilt the macOS `.app` (`xcodebuild`, not `swift build`) and toggled "Review Flags" live on Key
West Bar. The new diagnostic correctly flagged, with concrete reasons:
- Chorus at [118.14, 122.45): `"Line count (1) differs from the established Chorus shape (7
  lines) — a line may have been merged or split incorrectly."` — this is the "There's a a place
  with with no no worries, worries, no no racing racing" run-on line.
- Verse 3 at [126.82, 131.66): `"Line count (1) differs from the established Verse 3 shape (3
  lines)…"` — the "Just cars cars time and time, that's not my fault" run-on line.

This confirms the word-doubling bug **is still present** in Key West Bar's Chorus/Verse 3
sections even after this session's earlier `LyricBlendRowBuilder` overlap-merge fix and
`AnalysisStage.swift` cache-tag bump (still uncommitted — see git status). The tag bump's
effectiveness remains unconfirmed; Task #35 (re-verify/root-cause why re-analysis isn't picking
up the fix for this song) is still open. This diagnostic is a genuinely useful independent
detector of that open bug, not a fix for it.

## Verification

- `swift format lint --strict --recursive Sources Tests`, `swift build`, and `swift test --skip
  AudioPlaybackServiceTests --skip StemPlaybackServiceTests` (606 tests: 2 new
  `StructureAlignmentDiagnosticsTests` passing, same pre-existing 8-assertion
  `AppModelTests`/`MusicLibraryAppModelTests` baseline, nothing new broken) all clean.
- Rebuilt the macOS `.app` via `xcodebuild` and live-verified on Key West Bar as above.

---
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
# Structure tab first + exhaustive iPad/desktop test pass (2026-07-06)

## What shipped

- Moved `.structure` to the first position in `EditorTab` (enum order = tab order = ⌘-shortcut
  order) in `WorkspaceEditorsView.swift`; updated `ContentView.swift`'s doc comment.
- iPad landscape-only lock: `Project.swift`'s `SongWorkbenchiPad` target now declares only
  `UIInterfaceOrientationLandscapeLeft/Right` in `UISupportedInterfaceOrientations`. Confirmed
  by direct testing that portrait clips the 3-column desktop-style layout (columns/labels cut
  off); this was Eric's own suspicion going in, verified before fixing.
- Exhaustive per-song check, **macOS desktop**: all 4 songs (Key West Bar, Settle Down, Flip
  Flops and Barbeque, Summertime's her with you) render correctly across all 5 tabs.
- Exhaustive per-song check, **iPad Pro 13" simulator**, full pipeline from scratch (Eric's
  explicit choice: "All 4 songs, full pipeline, on iPad"): copied the 4 source audio files into
  the simulator's sandboxed container Documents folder via `simctl get_app_container`, imported
  each through the in-app Files picker, ran Stems → Transcribe → Tempo & Chords → ChordPro for
  all 4. All succeeded; Structure tab verified for each.
  - **Found + documented, not fixed**: Whisper Large V3 Turbo (Accuracy transcription) can't
    install on iPad — `ModelPackageManager.swift`'s `DittoModelArchiveExtractor` shells out to
    `/usr/bin/ditto` (`Process`/NSTask), which is macOS-only; the iOS `#else` branch throws
    `extractionUnsupportedOnPlatform`. This was already flagged in a code comment as tracked/
    known, not a new regression. Fast/Balanced (Parakeet, Core ML) installs and works fine on
    iPad and was used for all 4 songs. Fixing this needs an in-process unzip (Apple Archive
    framework) — real work, left for a dedicated pass.
  - One accidental song deletion during testing (mis-clicked a trash icon next to the "+"
    import button in the cramped iPad header) — re-imported, no lasting effect.

## UI polish requests that came up live during the iPad pass (all shipped + verified both platforms)

- Song list rows: dropped the MP3/M4A file-format caption line (title-only rows, tighter).
- Song list is now collapsible: chevron in the `SongSidebar` header toggles `@AppStorage
  "songSidebarExpanded"` (same key read in both `SongSidebar` and `PlayerView.mainColumns`, so
  the outer split-view frame shrinks too); collapsed state shows just the current song's title,
  tap to re-expand.
- `SongStructureView`'s own header no longer repeats the song title (already shown by the
  shared per-song title above the tab bar) — only the "Approximate" badge remains. This was the
  "wasted space at the top of the screen" Eric flagged; confirmed by reading the view's code.
- Background-activity status ("Ready" / in-progress spinner) moved from a dedicated footer bar
  at the bottom of the window into the `SongSidebar` header row; the footer bar is gone.
- Structure tab: added INTRO/INSTRUMENTAL/OUTRO SECTIONS cards (new
  `SongStructureOverview.InstrumentalSummary`: occurrence count, total time, representative
  chord pattern) alongside the existing VERSE/CHORUS/BRIDGE phrase templates — wordless
  sections previously only showed up as bare rows in the FORM list with no further detail.

## Verification

- `swift build`, `swift test` (601 tests, same 8 pre-existing `AppModelTests`/
  `MusicLibraryTests` baseline failures — confirmed via `git stash` that they fail identically
  on unmodified `main`, so not caused by this session's changes), and `swift format lint
  --strict --recursive Sources Tests` all clean after every batch of changes.
- Rebuilt + relaunched both the macOS app and the iPad simulator app after each change and
  live-verified via screenshots: collapsible list (both directions), tightened Structure
  header, inline "Songs · Ready" status with no footer, and the new instrumental section cards
  — on both platforms.
- Did not add an iOS unit-test target: `SongWorkbenchTests` in `Project.swift` is
  `destinations: .macOS` only and `SongWorkbenchiPad`'s scheme has no `testAction`. Live/manual
  verification on the simulator stood in for iOS-side unit tests this pass.

## Not done / left open

- Whisper-on-iPad archive extraction (see above) — needs an Apple Archive-based in-process
  unzip; `ModelPackageManager.swift` already has the seam (`ModelArchiveExtracting` protocol).
- Task #15 from an earlier session (word-doubling/timing-overlap fix in
  `LyricBlendRowBuilder.swift`, lost to a concurrent-process race) is still pending, untouched
  this session.

---
# Review pane width, iPad nav-bar chrome, ChordPro concatenation bug (2026-07-06, later same day)

Three follow-up reports that came in during/after the iPad testing pass above.

## Review pane forcing left/right panels off-screen

- `ChordProTabEditor`'s toolbar (title/badge/Import/mode picker/timing offset/View menu/Mark
  Reviewed/Transpose/Export/JustChords) is only used by the Review tab (`ChordProReviewTab`
  is the sole caller with `config: .chordPro`, which turns every optional control on) and had
  no width constraint — its summed ideal width exceeded the middle column, especially on iPad,
  pushing `SongSidebar`/`StemMixSidebar` out of the window.
- Fix: split the toolbar into its own `toolbar` computed view and wrap it in a horizontal
  `ScrollView` inside `body`, so it can only ever claim the width it's given instead of forcing
  its parent wider. Dropped the toolbar's trailing `Spacer()` (meaningless inside a horizontal
  ScrollView).
- Verified live on the iPad simulator: Review tab now shows the full toolbar plus both side
  panels, nothing off-screen.

## iPad "wasted space at the top of the screen" (second report, distinct from the Structure-tab one)

- Root cause: `SongSidebar`'s `.navigationTitle("Songs")` (inside `ContentView`'s single
  `NavigationStack`) renders iOS's large-title system nav bar above our own compact collapsible
  header — chrome macOS never shows, since `.navigationTitle` there just sets the window title.
- Fix: new `View.hideSystemNavigationBarCompat()` in `PlatformShims.swift`
  (`.toolbar(.hidden, for: .navigationBar)` on iOS, no-op on macOS), applied right after
  `.navigationTitle("Songs")`.
- Verified live on the iPad simulator: status bar sits directly above the compact header now,
  no large title banner.

## ChordPro lines rendering concatenated/scrambled on iPad ("Summertime's her with you")

Finally root-caused and fixed Task #15 (word-doubling/timing-overlap in
`LyricBlendRowBuilder.swift`), left pending across multiple earlier sessions.

- Root cause (confirmed against the iPad simulator's OWN persisted analysis JSON, pulled via
  `xcrun simctl get_app_container`): with only Parakeet available on iPad (no Whisper/accuracy
  model), `balancedDraft`'s own line grouper ran two-to-three real lyric lines together into a
  single run-on segment, while `fastDraft` split the SAME span into 2-3 clean, correctly-ordered
  segments. `LyricBlendRowBuilder.buildRows`'s clustering only pulled the FIRST of those clean
  segments into the run-on's cluster (the rest were more than `clusterWindow` away from its
  anchor), so the clean segments became separate `LyricBlendRow`s whose time spans nonetheless
  OVERLAPPED the run-on row. `ChordProDraftBuilder` has no concept of overlapping lyric lines
  (a single voice can't sing two spans at once), so it printed all of them, and their words read
  as scrambled/doubled on the chart.
- Fix: `LyricBlendRowBuilder.mergeCrossModeDuplicates` gained a second, fallback merge pass
  (`canMergeByOverlap`) that runs only when the existing exact-normalized-text pass finds
  nothing. It merges an earlier cluster with a later one when their time windows actually
  overlap AND the later cluster is a single-mode fragment (not already corroborated by 2+
  modes) AND no mode common to both contributes segments that themselves overlap in time. The
  single-mode-fragment condition is what keeps the existing `testRunOnDemotionTolerates…`
  field case (Settle Down: both balanced AND fast cleanly split the phrase's second half into
  their own 2-mode row) staying as 2 separate rows — that shape is independently trustworthy
  and is `runOnDuplicatesDemoted`'s job, not this merge.
- Added two regression tests reproducing the exact live iPad timestamps/text: a 2-cluster case
  and the full 3-fastDraft-segment case from the field data.
- Verified end-to-end: rebuilt the iPad app, re-ran "Analyze Song" on the live simulator for
  the same song, and confirmed via the freshly-written analysis JSON that the chorus now
  renders as ONE coherent line ("Laughter rising in the air It's just me and you right there
  sometimes here with you") instead of 3 overlapping/scrambled ones.

## Verification

- `swift build`, `swift test` (604 tests: the same pre-existing 5-failure/8-assertion
  `AppModelTests`/`MusicLibraryAppModelTests` baseline, nothing new), `swift build -c release`,
  and `swift format lint --strict --recursive Sources Tests` all clean.
- Rebuilt + reinstalled + relaunched the iPad simulator app after every change; visually
  confirmed all three fixes live (Review pane layout, nav-bar chrome, and a full live
  re-analysis of "Summertime's her with you" showing the corrected single-line chorus).

---
# (previous) Align to Reference Lyrics — done 2026-06-25, see git history for details

---
# Plan: W1 downbeat-aware chord switch penalty + pure-time row axis (Task #47, drafted 2026-07-08)

Eric approved both directions via quality review (tasks/quality-review-2026-07.md). Plan
written before implementation per workflow. NOT started.

## W1 — metric-position-dependent switch penalty (chord density root cause)

Grounding: `ChordTimelineDecoder.windowSwitchPenalties` currently charges `switchPenalty` (1.5)
× `onsetPenaltyFactor` (0.5) when a window start is within 0.12s of an instrument onset. No
metric-position awareness. `DownbeatEstimator.barPhase(beatStrengths:)` (MeasureGrid.swift:149)
already derives bar phase from drums+bass accent energy — NO lyrics needed, computable at
analysis time from the same drum-locked grid the decoder already receives.

- [ ] 1. AnalysisStage (HarmonyStage.run, ~:643-668): compute `beatsPerBar` via
      `DownbeatEstimator.estimateBeatsPerBar` and `barPhase` via `barPhase(beatStrengths:)`
      using drum-stem energy sampled at `resolvedBeatTimes`; pass both into the decoder.
- [ ] 2. ChordTimelineDecoder: optional `meter: (beatsPerBar: Int, barPhase: Int)?` param
      (nil = exact old behavior, all callers/tests unchanged). In `windowSwitchPenalties`,
      multiply base penalty by a metric factor per window index i:
      downbeat ≈0.7, half-bar ≈0.85, weak beats ≈1.3 (constants to tune offline).
      Clamp combined (metric × onset) discount to ≥0.35 × base so discounts don't stack to
      free. Keep the onset discount — genuine syncopation must stay reachable.
- [ ] 3. Bump harmony stage version tag (reduce-12 → reduce-13) so cached songs re-decode.
- [ ] 4. Offline validation BEFORE app verification, same harness as the decoder's doc header
      (ChordTimelineDecoder.swift:11-14): replay cached Analysis JSON for reference songs
      (Settle Down + the reference song). Metrics: event count, % non-diatonic, sub-beat
      count, chorus self-agreement, instrumental outro symbol count (currently ~19/36s),
      MelodyPhraseProxy chorus letters (currently A B C D E F G H — expect repeats to emerge).
      Guard: verify known-real mid-verse changes (the ones 2.5/2.0 lost) still detected.
- [ ] 5. Unit tests: synthetic windows where a passing chord on a weak beat is absorbed but
      the same evidence on a downbeat switches; nil-meter regression test.
- [ ] 6. Live verify on Mac (xcodebuild default DerivedData — NOT a repo-local
      -derivedDataPath, iCloud xattrs break CodeSign; see memory), re-analyze, check
      Structure tab chorus phrase pattern + outro chord pattern.

## Pure-time row axis (purple vs yellow width unification)

- [ ] 1. Measure first (verify-numerically lesson): from cached transcription JSON, compute
      per-word textWidth(9px/char) vs duration×100px/s across songs → quantify how often
      words would collide without the monospace floor, worst-case overlap px.
- [ ] 2. Based on data, pick mitigation: accept small overlaps (likely fine if rare), or
      derive global pixelsPerSecond from ~95th-pct char-rate (keeps ONE axis song-wide;
      chord-drag px↔s conversion must use the same constant), or per-row font shrink (last
      resort). Present numbers to Eric if ambiguous.
- [ ] 3. rhythmicWordXs (WorkspaceEditorsView.swift:3678-3691): drop cumulative
      max(desired, cursor) floor → x = metricX(word.start). totalWidth becomes
      duration-based + last-word glyph allowance. Verify strip/chords/dots/ball all follow
      (they map through rhythmicX/metricX, so they inherit the fix).
- [ ] 4. Fix outro chord-only lineDuration=0 fallback: resolve end bound from song/beat
      duration (as LyricSectionDeriver.resolvedSongEnd does) in chordOnlyLineWindow
      (~:2588-2593) so rows never collapse to char-count width.
- [ ] 5. Rebuild app + live verify: equal-elapsed purple and yellow rows render equal width;
      drag-to-retime chords still lands where dropped.

## Review (2026-07-08)

W1 LANDED. Decoder: `BarMeter` + metric-position switch-penalty factors (downbeat 0.7,
half-bar 0.85, weak 1.3, combined-discount floor 0.35x; nil meter = exact old behavior).
HarmonyStage: bar phase from drums-stem accent energy via new `DrumAccentProfile` +
`DownbeatEstimator.barPhase(beatStrengths:)`, gated on downbeatConfidence >= 0.08 (mirrors
preview refreshGrid). Version bump reduce-15 -> reduce-16-metric-switch-penalty. 4 new unit
tests; full suite 625 green.

Offline validation (new manual harness ChordDecoderOfflineValidationTests, run with
SW_OFFLINE_VALIDATION=1): 17 cached analyses, 13 with usable meter. Densest song 174->166
events (1.38->1.32/bar); per-beat flurries collapsed (e.g. 3 chords in 1.1s removed);
boundary moves of +/-1 beat onto downbeats; two songs +2 downbeat changes; nothing lost on
the flicker-suppression side. Factors deliberately conservative — if Structure-tab chorus
phrase letters remain fully distinct, raise weakBeatFactor toward 1.6 using the harness.

Pure-time axis: MEASURED, then DEFERRED by Eric. 74 cached transcriptions: at 100px/s, 53%
of adjacent sung-word pairs physically can't fit their time gap at 15pt (median required
102px/s, p95 270, melisma pairs ~0 gap); half the songs need no stretch at all. The
screenshot's narrow purple rows were likely the outro zero-duration fallback bug — FIXED
(chordOnlyLineWindow now falls back to beat-grid extent + one bar when no envelope is
loaded). Decision: rebuild + re-check visually before any axis rework; if still needed, the
per-song adaptive shared scale (clamp densest-line requirement to 100-250px/s) is the
agreed direction.

---

# HANDOFF (2026-07-08) — next session: iPad model-install crash

## Bug
On iPad, the app crashes shortly after prompting to install a missing model.

## Known facts (verified this session)
- `ModelPackageManager.swift:81-99` `DittoModelArchiveExtractor.extract` shells to
  `/usr/bin/ditto` via `Process` on macOS; on iOS it throws
  `ModelPackageError.extractionUnsupportedOnPlatform`. A THROW should alert, not
  crash → the crash is an unguarded failure path upstream in the install flow
  (try!, force-unwrap, or unchecked continuation) OR earlier in download handling.
- The old SongWorkbench-ipad worktree is GONE; iPad support now lives in main
  (repo /Users/ericnewman/Documents/SongWorkbench, HEAD fe8dade).
- No SongWorkbench crash logs in ~/Library/Logs/DiagnosticReports (device crash;
  user asked to pull the .ips from iPad Settings > Privacy & Security >
  Analytics Data, or via Xcode's Devices window).

## Plan
1. Read the .ips crash log if the user provided it (check repo root / chat).
2. Trace the install flow from the "install missing model" prompt to extract();
   find and fix the unguarded failure path (surface an alert instead).
3. Implement in-process zip extraction for iOS behind the existing
   `ModelArchiveExtracting` protocol seam (small zip reader; Apple Archive
   doesn't read .zip). Unit-test with a tiny fixture zip.
4. Verify on iOS Simulator + device build; keep the macOS ditto path unchanged.

## Also queued (user-requested)
- Long instrumental lines still render too wide in the ChordPro preview —
  split/cap instrumental rows to the same rendered width budget as sung lines
  (builder splits by typicalBars but the preview draws rows time-scaled at
  pixelsPerSecond; re-check against CURRENT code, it has moved past reduce-14).
- A3 repeated-section chord consensus (sim showed chorus agreement 80%→100%).
- Unresolved: macOS "failed model loading" message when starting analysis
  (Jul 8 report) — never reproduced; suspects: parakeet -int8 folder-name
  symlink staging, or a stale whisper model version folder (Models has "1" and "2").

## RESOLUTION (2026-07-08) — iPad model-install crash

Approach chosen: "just stop the crash" (not the deeper in-process-zip-extraction path in
step 3 above — that remains a scoped-out follow-up so Whisper/Accuracy can eventually
install on iPad).

Root fix = gate out the un-installable package everywhere on iPad instead of letting the
user reach Whisper's macOS-only `ditto` extraction:
- `ModelPackageManager.isInstallableOnCurrentPlatform` (false for archive-bearing packages
  on iOS).
- Both install entry points filter by it: the Models popover (`AnalysisWorkspaceView`) and
  the new first-run `ModelOnboardingSheet` (`ContentView`). There is no programmatic
  auto-install caller, and mode selection (`availableTranscriptionModes` /
  `primaryTranscriptionMode`) only READS installed status — so `extract()` is now
  unreachable on iPad.
- Onboarding gate blocks the app until all platform-installable models are present, so on
  iPad Parakeet is guaranteed installed and `primaryTranscriptionMode` never falls back to
  `.accuracy`.
Also bundled (separate iPad bug, was written but never committed): the iOS
security-scoped-URL import fix in `AppModel.importSongs` + import-error surfacing on the
no-song screen + `com.local.SongWorkbench` import Logger.

Verification: `xcodebuild` SongWorkbenchiPad Debug for iPad Pro 13" (M5) sim → BUILD
SUCCEEDED; installed + launched on that sim → runs the full analysis UI on a real analyzed
song with no crash; call-graph audit confirms every `installModelPackage` caller is
filtered. Committed as the iPad-fix commit; the unrelated chord-decoder / ChordPro-preview
WIP was intentionally left uncommitted in the working tree.
