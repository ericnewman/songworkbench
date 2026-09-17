import AVFoundation
import Foundation
import XCTest

@testable import SongWorkbench

final class TranscriptionTests: XCTestCase {
    func testSparseOpeningRescueRequestsBoundedRetryForLongIntroDecode() {
        let result = transcriptionResult(
            segments: [
                transcriptionSegment("Amen.", start: 0, end: 1),
                transcriptionSegment("Whiskey in trouble", start: 30, end: 33),
            ],
            sourceDuration: 299
        )

        XCTAssertEqual(
            SparseOpeningTranscriptionRescuer.retryRange(
                for: result,
                vocalOnset: 25.38
            ),
            17.38...31
        )
    }

    func testSparseOpeningRescueReplacesOnlySparseLeadWithRicherOffsetRetry() {
        let primary = transcriptionResult(
            segments: [
                transcriptionSegment("Amen.", start: 0, end: 1),
                transcriptionSegment("Whiskey in trouble", start: 30, end: 33),
            ],
            sourceDuration: 299
        )
        let retry = transcriptionResult(
            segments: [
                transcriptionSegment(
                    "The saloon door swung open", start: 6.8, end: 10.7),
                transcriptionSegment("Whiskey", start: 12.8, end: 13.0),
            ],
            sourceDuration: 14
        )

        let merged = SparseOpeningTranscriptionRescuer.merged(
            primary: primary,
            retry: retry,
            retryStart: 17.38,
            replacementEnd: 30
        )

        XCTAssertEqual(
            merged.segments.map(\.text),
            ["The saloon door swung open", "Whiskey in trouble"]
        )
        XCTAssertEqual(merged.segments[0].startTime, 24.18, accuracy: 1e-9)
        XCTAssertEqual(merged.segments[0].tokens[0].startTime, 24.18, accuracy: 1e-9)
        XCTAssertEqual(merged.sourceDuration, primary.sourceDuration)
    }

    func testSparseOpeningRescueKeepsPrimaryWhenRetryIsNotRicher() {
        let primary = transcriptionResult(
            segments: [
                transcriptionSegment("Amen.", start: 0, end: 1),
                transcriptionSegment("Next line", start: 20, end: 22),
            ],
            sourceDuration: 60
        )
        let retry = transcriptionResult(
            segments: [transcriptionSegment("Amen.", start: 4, end: 5)],
            sourceDuration: 10
        )

        XCTAssertEqual(
            SparseOpeningTranscriptionRescuer.merged(
                primary: primary,
                retry: retry,
                retryStart: 10,
                replacementEnd: 20
            ),
            primary
        )
    }

    func testWordlessGapRescueFindsTheSungStretchBeforeALine() {
        let primary = transcriptionResult(
            segments: [
                transcriptionSegment("Earlier words", start: 10, end: 11),
                transcriptionSegment("me and you", start: 19.6, end: 20.5),
            ],
            sourceDuration: 60
        )

        let gaps = WordlessVocalGapRescuer.gaps(in: primary, sungIntervals: [13...20.5])

        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.lowerBound ?? 0, 13, accuracy: 1e-9)
        XCTAssertEqual(gaps.first?.upperBound ?? 0, 19.35, accuracy: 1e-9)
    }

    func testWordlessGapRescueAddsOnlyWordsInsideTheGap() {
        let primary = transcriptionResult(
            segments: [
                transcriptionSegment("Earlier words", start: 10, end: 11),
                transcriptionSegment("me and you", start: 19.6, end: 20.5),
            ],
            sourceDuration: 60
        )
        // A clip from 12 s: the missing phrase, then the already-placed line again.
        let retry = transcriptionResult(
            segments: [
                transcriptionSegment("the end you", start: 1, end: 2.5),
                transcriptionSegment("me and you", start: 7.6, end: 8.5),
            ],
            sourceDuration: 9
        )

        let merged = WordlessVocalGapRescuer.merged(
            primary: primary, retry: retry, retryStart: 12, gap: 13...19.35)

        XCTAssertEqual(merged.segments.map(\.text), ["Earlier words", "the end you", "me and you"])
        XCTAssertEqual(merged.segments[1].tokens[0].startTime, 13, accuracy: 1e-9)
        XCTAssertEqual(merged.segments[2], primary.segments[1])
    }

    func testWordlessGapRescueIgnoresALoneHallucinatedWord() {
        let primary = transcriptionResult(
            segments: [transcriptionSegment("me and you", start: 19.6, end: 20.5)],
            sourceDuration: 60
        )
        let retry = transcriptionResult(
            segments: [transcriptionSegment("Thanks.", start: 2, end: 3)],
            sourceDuration: 9
        )

        XCTAssertEqual(
            WordlessVocalGapRescuer.merged(
                primary: primary, retry: retry, retryStart: 12, gap: 13...19.35),
            primary
        )
    }

    func testMetadataAndTimestampedResultRoundTripThroughCodable() throws {
        let result = makeResult(segments: [
            TimedTranscriptionSegment(
                text: "Hello.",
                startTime: 0.25,
                endTime: 0.75,
                tokens: [token("Hello.", 0.25, 0.75, confidence: 0.9)],
                confidence: 0.9
            )
        ])

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)

        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.engine.modelSizeBytes, 1_500_000_000)
        XCTAssertEqual(decoded.engine.license.name, "MIT")
        XCTAssertEqual(decoded.completedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testTranscriptionDomainValuesAreSendable() {
        assertSendable(TranscriptionRequest(audioURL: URL(fileURLWithPath: "/tmp/song.wav")))
        assertSendable(token("word", 0, 1))
        assertSendable(makeResult())
        assertSendable(TimedLyricSegment(start: 0, end: 1, text: "word"))
    }

    func testProgressFractionIsNormalized() {
        XCTAssertEqual(progress(completed: -1, total: 10).fractionCompleted, 0)
        XCTAssertEqual(progress(completed: 4, total: 10).fractionCompleted, 0.4)
        XCTAssertEqual(progress(completed: 20, total: 10).fractionCompleted, 1)
        XCTAssertEqual(progress(completed: 0, total: 0).fractionCompleted, 0)
    }

    func testGroupingSortsTokensStablyAndRendersPunctuationDeterministically() {
        let tokens = [
            token("world", 0.5, 0.9),
            token("  Hello  ", 0, 0.4),
            token("!", 0.9, 1),
            token("We're", 1.1, 1.4),
            token("here", 1.1, 1.6),
            token("   ", 2, 3),
        ]

        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)

        assertSegments(
            grouped,
            equal: [("Hello world!", 0, 1), ("We're here", 1.1, 1.6)]
        )
        XCTAssertEqual(grouped, TimedLyricSegmentGrouper.group(tokens: tokens))
    }

    func testGroupingAveragesTokenConfidenceIntoTheLineSegment() {
        // backlog #15: the Review tab colors lines by confidence, computed as the mean of the
        // line's own tokens' confidence at grouping time (not carried at the word level yet).
        let tokens = [
            token("hello", 0.0, 0.4, confidence: 0.9),
            token("world", 0.5, 0.9, confidence: 0.7),
        ]
        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].confidence ?? -1, 0.8, accuracy: 0.0001)
    }

    func testGroupingLeavesConfidenceNilWhenNoTokenReportsOne() {
        // The common case in these tests: the default `token(...)` helper passes no confidence,
        // matching engines/paths that never report per-token confidence.
        let tokens = [token("hello", 0.0, 0.4), token("world", 0.5, 0.9)]
        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertNil(grouped[0].confidence)
    }

    func testRegroupReSplitsStoredSegmentsUsingCurrentRules() {
        // A single stored segment that merged two lines (an old over-merge); its words
        // carry the capitalization + timing needed to re-split into two lines.
        let merged = TimedLyricSegmentGrouper.group(tokens: [
            token("I", 0.0, 0.2),
            token("walk", 0.3, 0.6),
            token("alone", 0.6, 1.0),
            token("Down", 1.6, 1.9),
            token("the", 2.0, 2.1),
            token("road", 2.2, 2.6),
        ])
        XCTAssertEqual(merged.count, 2)

        // Re-grouping is stable (idempotent) for already-current lyrics.
        let regrouped = TimedLyricSegmentGrouper.regroup(merged)
        assertSegments(
            regrouped,
            equal: [("I walk alone", 0.0, 1.0), ("Down the road", 1.6, 2.6)]
        )
    }

    func testRegroupIsIdempotentWhenAnOpenOrphanBridgesAGapAndAForcedBreak() {
        // Storm Warning (2026-09-15 corpus, stem-whisper85), words anonymized, timings and case
        // kept. "the" sits alone between a 5.2 s gap and the forced line start at 91.100. It was
        // glued back onto "Lift high" as a function-word orphan, then "the" (which cannot end a
        // line) pulled the next line forward across the forced break: one 8-word line. Regrouping
        // THAT loses the forced break, so "the" is no longer an orphan and the gap break stands —
        // AnalysisTimingPostPasses moved the line on its second run.
        let stored = [
            storedLine([
                ("Lift", 81.073, 83.249), ("high", 83.320, 84.703), ("the", 89.878, 90.878),
            ]),
            storedLine([
                ("wagons", 91.100, 91.987), ("we", 91.987, 92.183), ("left", 92.183, 92.378),
                ("behind", 92.350, 92.965), ("today", 92.870, 93.364),
            ]),
            storedLine([("Sing", 93.364, 93.814), ("along", 93.814, 94.588)]),
        ]
        let regrouped = TimedLyricSegmentGrouper.regroup(stored)
        assertSegments(
            regrouped,
            equal: [
                ("Lift high", 81.073, 84.703),
                ("the wagons we left behind today", 89.878, 93.364),
                ("Sing along", 93.364, 94.588),
            ])
        XCTAssertEqual(
            TimedLyricSegmentGrouper.regroup(regrouped).map(\.words), regrouped.map(\.words))
        let starts = Set(regrouped.compactMap { $0.words.first?.start })
        XCTAssertEqual(
            TimedLyricSegmentGrouper.regroup(stored, lineStartOnsets: starts).map(\.words),
            regrouped.map(\.words))
    }

    func testConjunctionMergeDoesNotChainPastDurationCap() {
        // A dense run of lines each ending on the open word "and" a beat apart — the exact shape
        // that used to chain through the conjunction-merge into one over-long line. The merge must
        // respect the same 15s duration cap the base grouper obeys, so no monster line survives.
        var tokens: [TimedTranscriptionToken] = []
        for i in 0..<14 {
            let base = Double(i) * 1.3
            tokens.append(token("Line\(i)", base, base + 0.3))
            tokens.append(token("and", base + 0.4, base + 0.7))
        }
        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)
        XCTAssertGreaterThan(grouped.count, 1, "must not collapse into one giant line")
        for segment in grouped {
            XCTAssertLessThanOrEqual(
                segment.end - segment.start, 15.0 + 1e-6,
                "no merged line may exceed the duration cap")
        }
    }

    func testConjunctionMergeDoesNotCrossOverlappingSegmentBoundary() {
        // Doc Holiday, at the source. Whisper reports the opening couplet as two segments whose
        // spans OVERLAP: "He walks in" 27.563-30.483 then "Whiskey ..." 30.000-36.620. The first
        // line ends on "in" (a continuation word), so the conjunction merge wanted to rejoin them
        // — and its `gap <= 1.0` guard was satisfied by a NEGATIVE gap (-0.483), i.e. vacuously,
        // not because the next line followed closely. The engine's own boundary must win.
        let tokens = [
            token("He", 27.563, 28.213),
            token("walks", 28.213, 29.863),
            token("in", 29.863, 30.483),
            token("Whiskey", 30.000, 32.000),
            token("in", 32.240, 33.238),
            token("trouble,", 33.238, 33.900),
            token("every", 34.800, 35.487),
            token("father's", 35.500, 36.100),
            token("sin.", 36.100, 36.620),
        ]
        let grouped = TimedLyricSegmentGrouper.group(
            tokens: tokens, lineStartOnsets: [27.563, 30.000])
        XCTAssertEqual(grouped.count, 2, grouped.map(\.text).joined(separator: " | "))
        XCTAssertEqual(grouped[0].text, "He walks in")
        XCTAssertTrue(
            grouped[1].text.hasPrefix("Whiskey in trouble"),
            grouped.map(\.text).joined(separator: " | "))
    }

    func testConjunctionMergeStillJoinsAcrossASmallPositiveGap() {
        // Control for the rule above: the merge is narrowed only for OVERLAPPING segments. The
        // same shape with a real, small, positive gap is still one sung line split mid-phrase,
        // and must still rejoin — otherwise the guard would have gutted the merge entirely.
        let tokens = [
            token("He", 27.563, 28.213),
            token("walks", 28.213, 29.863),
            token("in", 29.863, 30.483),
            token("Whiskey", 30.700, 31.400),
            token("trouble", 31.500, 32.100),
        ]
        let grouped = TimedLyricSegmentGrouper.group(
            tokens: tokens, lineStartOnsets: [27.563, 30.700])
        XCTAssertEqual(grouped.count, 1, grouped.map(\.text).joined(separator: " | "))
    }

    func testRegroupLeavesLyricsWithoutWordTimingsUntouched() {
        // Older analyses store segments without per-word data; re-grouping must not
        // collapse them into atomic tokens or merge lines.
        let stored = [
            TimedLyricSegment(start: 0, end: 4, text: "No plans no problem"),
            TimedLyricSegment(start: 4, end: 8, text: "just good friends and a beer"),
        ]
        XCTAssertEqual(TimedLyricSegmentGrouper.regroup(stored), stored)
    }

    func testGroupingDoesNotOrphanASingleCapitalizedWord() {
        // "Charcoal" then "Crackle" (both capitalized, sung together with a small gap) must
        // stay on one line rather than orphaning "Charcoal" onto its own line.
        let tokens = [
            token("Charcoal", 0.0, 0.6),
            token("Crackle", 0.84, 1.2),  // capitalized, 0.24s gap
            token("sparks", 1.3, 1.7),
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("Charcoal Crackle sparks", 0.0, 1.7)]
        )
    }

    func testGroupingStartsNewLineAtCapitalizedWordAfterGap() {
        // "Down" is capitalized and follows a 0.6s gap, so it starts a new line;
        // the lowercase continuation stays on its line.
        let tokens = [
            token("I", 0.0, 0.2),
            token("walk", 0.3, 0.6),
            token("alone", 0.6, 1.0),
            token("Down", 1.6, 1.9),
            token("the", 2.0, 2.1),
            token("road", 2.2, 2.6),
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("I walk alone", 0.0, 1.0), ("Down the road", 1.6, 2.6)]
        )
    }

    func testGroupingKeepsMidLineCapitalizedWordWithoutGap() {
        // Capitalized "I" mid-phrase (no real gap before it) must not break the line.
        let tokens = [
            token("Here", 0.0, 0.3),
            token("I", 0.35, 0.5),
            token("am", 0.55, 0.8),
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("Here I am", 0.0, 0.8)]
        )
    }

    func testGroupingSplitsAtGapDurationAndTokenLimits() {
        let configuration = TimedLyricGroupingConfiguration(
            maximumGap: 1,
            maximumDuration: 2,
            maximumTokens: 2
        )
        let tokens = [
            token("one", 0, 0.4),
            token("two", 0.5, 0.9),
            token("three", 1, 1.4),
            token("four", 3, 3.4),
            token("five", 4, 5.5),
        ]

        // The caps split the run, then the anti-orphan pass rejoins single lowercase words that
        // are contiguous with the previous line: "three" (0.1s after "two") rejoins, but "four"
        // is fenced off by a real 1.6s gap, and "five" (0.6s after "four") rejoins it.
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens, configuration: configuration),
            equal: [
                ("one two three", 0, 1.4),
                ("four five", 3, 5.5),
            ]
        )
    }

    func testGroupingDepadsAnOverlongLeadingWordPreservingTheWord() {
        // Real Whisper failure mode (from "Flip Flops and Barbeque"): the first word "Grass" is
        // padded to span the whole 20s instrumental intro before the vocal enters. It must be
        // re-timed (kept, not dropped) so it rejoins its line and the intro gap reappears.
        let tokens = [
            token("Grass", 0.0, 20.0),  // padded across the intro
            token("between", 20.12, 20.90),
            token("my", 20.90, 21.09),
            token("toes", 21.19, 21.76),
        ]

        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].text, "Grass between my toes")
        // "Grass" survives and is re-timed to a normal span just before "between"; the 0–19s
        // intro gap is restored (the line no longer starts at 0).
        XCTAssertEqual(grouped[0].start, 19.0, accuracy: 0.001)
        XCTAssertEqual(grouped[0].words.first?.text, "Grass")
    }

    func testGroupingBreaksAtCapitalizedSegmentLineStartsWithoutAGap() {
        // Whisper packs words back-to-back (≈0 inter-word gap) but emits one segment per sung
        // line. The segment line-start onsets must drive the breaks even though the gap-based
        // capitalization rule can't fire.
        let tokens = [
            token("between", 20.12, 20.90),
            token("my", 20.90, 21.09),
            token("toes", 21.19, 21.76),
            token("Smoke", 21.76, 22.30),  // new line, no gap before it
            token("curls", 22.30, 22.80),
            token("Laugh", 22.80, 23.30),  // new line, no gap before it
            token("the", 23.30, 23.70),
        ]
        let onsets: Set<TimeInterval> = [20.12, 21.76, 22.80]

        // Without the segment hints the zero-gap stream runs on into one line (the reported bug).
        XCTAssertEqual(TimedLyricSegmentGrouper.group(tokens: tokens).count, 1)

        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens, lineStartOnsets: onsets),
            equal: [
                ("between my toes", 20.12, 21.76),
                ("Smoke curls", 21.76, 22.80),
                ("Laugh the", 22.80, 23.70),
            ]
        )
    }

    func testGroupingBreaksAtLowercaseSegmentLineStartWithoutRequiringCapitalization() {
        // Field case (Settle Down, Task #37/#38, 2026-07-07): two clean, independently-agreed
        // lines — "She makes me want to settle down," and "trading my rowdy friends for a
        // one-horse town." — were welded back into one run-on line on every reload because the
        // second line's first word ("trading") is lowercase, and the forced-break rule for a
        // known existing line-start onset used to ALSO require capitalization. The 2.2s gap
        // between them is real but under `maximumGap` (3s) once segment structure is present, so
        // only the onset-match rule (not the gap) can save this boundary.
        let tokens = [
            token("She", 54.4, 54.7), token("makes", 55.43, 56.11), token("me", 56.12, 56.37),
            token("want", 56.32, 56.9), token("to", 56.8, 57.16), token("settle", 57.11, 57.95),
            token("down,", 57.84, 58.12),
            token("trading", 60.35, 61.24), token("my", 61.37, 61.5), token("rowdy", 61.53, 62.16),
            token("friends", 62.18, 62.9), token("for", 63.39, 63.81), token("a", 63.81, 63.94),
            token("one-horse", 63.97, 65.12), token("town.", 65.18, 65.78),
        ]
        let onsets: Set<TimeInterval> = [54.4, 60.35]

        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens, lineStartOnsets: onsets),
            equal: [
                ("She makes me want to settle down,", 54.4, 58.12),
                ("trading my rowdy friends for a one-horse town.", 60.35, 65.78),
            ]
        )
    }

    func testGroupViaResultBreaksWhisperStyleZeroGapSegments() {
        // End-to-end through group(result:): two zero-gap Whisper-style segments must become two
        // lines (exercises lineStartOnsets(of:) derivation + the de-pad path).
        let seg1 = TimedTranscriptionSegment(
            text: "Grass between toes", startTime: 0, endTime: 1.5,
            tokens: [token("Grass", 0, 0.5), token("between", 0.5, 1.0), token("toes", 1.0, 1.5)],
            confidence: 0.9)
        let seg2 = TimedTranscriptionSegment(
            text: "Smoke curls up", startTime: 1.5, endTime: 3.0,
            tokens: [token("Smoke", 1.5, 2.0), token("curls", 2.0, 2.5), token("up", 2.5, 3.0)],
            confidence: 0.9)
        let result = makeResult(segments: [seg1, seg2])

        assertSegments(
            TimedLyricSegmentGrouper.group(result: result),
            equal: [("Grass between toes", 0, 1.5), ("Smoke curls up", 1.5, 3.0)]
        )
    }

    func testGroupingMergesLowercaseTrailingOrphanIntoItsLine() {
        // A line pushed just over the duration cap strands its last lowercase word ("you.")
        // onto its own line; it must rejoin the line it continues.
        let configuration = TimedLyricGroupingConfiguration(maximumDuration: 2)
        let tokens = [
            token("being", 0.0, 0.5),
            token("here", 0.6, 1.0),
            token("with", 1.2, 1.8),
            token("you.", 2.4, 2.9),  // would orphan: line duration would exceed the 2s cap
        ]

        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens, configuration: configuration),
            equal: [("being here with you.", 0.0, 2.9)]
        )
    }

    func testGroupingMergesFunctionWordOrphanAcrossALongPause() {
        // "It's a party going" then a ~10s sung pause, then a lone "on." — a function word that is
        // never a real one-word line, so it rejoins its line even across the large gap.
        let tokens = [
            token("It's", 50.0, 50.3),
            token("a", 50.3, 50.5),
            token("party", 50.5, 50.9),
            token("going", 50.9, 51.0),
            token("on.", 60.8, 61.0),  // 9.8s gap, function word
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("It's a party going on.", 50.0, 61.0)]
        )
    }

    func testGroupingKeepsNonFunctionWordOrphanAfterALargeGapSeparate() {
        // A real one-word line that is NOT a function word stays separate across a big gap.
        let tokens = [
            token("Dance", 0.0, 0.5),  // capitalized line
            token("alone", 10.0, 10.6),  // lowercase, but not a function word; big gap
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("Dance", 0.0, 0.5), ("alone", 10.0, 10.6)]
        )
    }

    func testGroupingBreaksAtCommasWithoutSegmentStructure() {
        // Parakeet returns one segment (no line-start onsets) but punctuates its run-on text with
        // commas at the sung-line ends — so break there to avoid one giant line.
        let tokens = [
            token("Grab", 0.0, 0.3), token("a", 0.3, 0.5), token("chair,", 0.5, 0.9),
            token("grab", 1.0, 1.3), token("a", 1.3, 1.5), token("grin", 1.5, 1.9),
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("Grab a chair,", 0.0, 0.9), ("grab a grin", 1.0, 1.9)]
        )
    }

    func testGroupingDoesNotBreakAtMidLineCommaWhenSegmentStructurePresent() {
        // Whisper segments per line, so a mid-line comma must NOT split the line.
        let tokens = [
            token("Grab", 0.0, 0.3), token("a", 0.3, 0.5), token("chair,", 0.5, 0.9),
            token("grab", 1.0, 1.3), token("a", 1.3, 1.5), token("grin", 1.5, 1.9),
        ]
        let onsets: Set<TimeInterval> = [0.0, 5.0]  // 2+ onsets => segment structure present
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens, lineStartOnsets: onsets),
            equal: [("Grab a chair, grab a grin", 0.0, 1.9)]
        )
    }

    func testGroupingMergesLeadingCapitalizedWordIntoLowercaseContinuation() {
        // "Friday" then a long gap, then "night is coming" (lowercase continuation): the transcriber
        // split a single line after its first word. They rejoin.
        let tokens = [
            token("Friday", 10.87, 11.87),
            token("night", 20.78, 21.2),  // lowercase, 8.9s gap
            token("is", 21.2, 21.5),
            token("coming", 21.5, 22.5),
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("Friday night is coming", 10.87, 22.5)]
        )
    }

    func testGroupingKeepsLoneCapitalizedWordBeforeACapitalizedLine() {
        // A lone capitalized word before a CAPITALIZED next line is a real one-word line, not a
        // split continuation, so it stays separate.
        let tokens = [
            token("Stop", 0.0, 0.5),
            token("Dance", 5.0, 5.5),  // capitalized next line (gap forces the break)
            token("along", 5.6, 6.0),
        ]
        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("Stop", 0.0, 0.5), ("Dance along", 5.0, 6.0)]
        )
    }

    func testGroupingKeepsACapitalizedOneWordLineSeparate() {
        // The anti-orphan merge must not swallow a legitimate capitalized one-word line.
        let tokens = [
            token("go.", 0.0, 0.4),
            token("Stop", 1.0, 1.6),  // capitalized new line after a gap
        ]

        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens),
            equal: [("go.", 0.0, 0.4), ("Stop", 1.0, 1.6)]
        )
    }

    func testGroupingUsesTokensFromAllResultSegments() {
        let result = makeResult(segments: [
            segment(tokens: [token("first", 0, 0.5)]),
            segment(tokens: [token("second.", 0.6, 1)]),
        ])

        assertSegments(
            TimedLyricSegmentGrouper.group(result: result),
            equal: [("first second.", 0, 1)]
        )
    }

    func testGroupingNormalizesReversedTokenTimeAndConfigurationBounds() {
        let configuration = TimedLyricGroupingConfiguration(
            maximumGap: -1,
            maximumDuration: -1,
            maximumTokens: 0
        )

        XCTAssertEqual(configuration.maximumGap, 0)
        XCTAssertEqual(configuration.maximumDuration, 0)
        XCTAssertEqual(configuration.maximumTokens, 1)
        assertSegments(
            TimedLyricSegmentGrouper.group(
                tokens: [token("word", 2, 1)],
                configuration: configuration
            ),
            equal: [("word", 2, 2)]
        )
    }

    func testLineEndingInConjunctionMergesWithContinuation() {
        // "I pick her up and" | "I'm all cleaned up nice" — split at the capitalized "I'm" segment
        // start, but "and" can't end a phrase and the next line follows in 0.3s → one sung line.
        let tokens = [
            token("I", 0.0, 0.2), token("pick", 0.2, 0.4), token("her", 0.4, 0.6),
            token("up", 0.6, 0.8), token("and", 0.8, 1.0),
            token("I'm", 1.3, 1.5), token("all", 1.5, 1.7), token("cleaned", 1.7, 1.9),
            token("up", 1.9, 2.1), token("nice", 2.1, 2.3),
        ]
        let segs = TimedLyricSegmentGrouper.group(tokens: tokens, lineStartOnsets: [0.0, 1.3])
        XCTAssertEqual(segs.count, 1, segs.map(\.text).joined(separator: " | "))
        XCTAssertTrue(segs[0].text.contains("and I'm"), segs[0].text)
    }

    func testShortFragmentBeforeConnectiveLineMerges() {
        // "She talks" | "About living…" — the next line OPENS with the preposition "about", which
        // can't begin an independent line, so the short fragment joins it (even across a ~3.3s gap).
        let tokens = [
            token("She", 0.0, 0.3), token("talks", 0.3, 0.7),
            token("About", 4.0, 4.3), token("living", 4.3, 4.6),
        ]
        let segs = TimedLyricSegmentGrouper.group(tokens: tokens, lineStartOnsets: [0.0, 4.0])
        XCTAssertEqual(segs.count, 1, segs.map(\.text).joined(separator: " | "))
    }

    func testInterjectionFragmentBeforeConnectiveIsNotMerged() {
        // A standalone interjection ("Oh no") is a real short line, so it is NOT pulled into the
        // next line even though that line opens with "and".
        let tokens = [
            token("Oh", 0.0, 0.3), token("no", 0.3, 0.7),
            token("And", 4.0, 4.3), token("run", 4.3, 4.6),
        ]
        let segs = TimedLyricSegmentGrouper.group(tokens: tokens, lineStartOnsets: [0.0, 4.0])
        XCTAssertEqual(segs.count, 2, segs.map(\.text).joined(separator: " | "))
    }

    func testZeroDurationMultiwordLeadInMergesWithImmediateContinuation() {
        // Doc Holiday field case: Whisper assigned both lead-in words the same zero-duration
        // timestamp and opened another segment 50 ms later. "No" is normally protected as a
        // possible interjection, but impossible timing proves this is one broken phrase.
        let tokens = [
            token("Ain't", 65.84, 65.84), token("no", 65.84, 65.84),
            token("runner", 65.89, 66.75), token("from", 66.73, 67.32),
            token("the", 67.36, 67.74), token("debt", 67.66, 68.31),
            token("you", 68.29, 68.73), token("owe.", 68.62, 69.30),
        ]

        let segments = TimedLyricSegmentGrouper.group(
            tokens: tokens, lineStartOnsets: [65.84, 65.89])

        XCTAssertEqual(segments.map(\.text), ["Ain't no runner from the debt you owe."])
        XCTAssertEqual(segments[0].start, 65.84, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 69.30, accuracy: 1e-9)
    }

    func testGroupingPopulatesWordTimingsWithCharacterRangesIntoSegmentText() {
        let tokens = [
            token("  Hello  ", 0, 0.4),
            token("world", 0.5, 0.9),
            token("!", 0.9, 1),
        ]

        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)

        XCTAssertEqual(grouped.count, 1)
        let segment = grouped[0]
        XCTAssertEqual(segment.text, "Hello world!")
        XCTAssertEqual(segment.start, 0)
        XCTAssertEqual(segment.end, 1)

        // "Hello" is its own word; "world!" spans two tokens joined without a space.
        XCTAssertEqual(segment.words.map(\.text), ["Hello", "world!"])
        XCTAssertEqual(segment.words.map(\.start), [0, 0.5])
        XCTAssertEqual(segment.words.map(\.end), [0.4, 1])

        // Character ranges index back into segment.text to recover each word verbatim.
        let characters = Array(segment.text)
        for word in segment.words {
            XCTAssertEqual(String(characters[word.characterRange]), word.text)
        }
        XCTAssertEqual(segment.words.map(\.characterRange), [0..<5, 6..<12])
    }

    func testGroupingWordTimesAreAscendingAndTakenFromTokens() {
        let tokens = [
            token("We're", 1.1, 1.4),
            token("here", 1.5, 1.9),
            token("now", 2.0, 2.4),
        ]

        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)
        XCTAssertEqual(grouped.count, 1)
        let words = grouped[0].words

        XCTAssertEqual(words.map(\.text), ["We're", "here", "now"])
        // "We're" is a single token (contraction is whole here), so onset == token onset.
        XCTAssertEqual(words.map(\.start), [1.1, 1.5, 2.0])
        XCTAssertEqual(words.map(\.end), [1.4, 1.9, 2.4])
        // Ascending onsets.
        XCTAssertEqual(words.map(\.start), words.map(\.start).sorted())
    }

    func testGroupingWordSpansMultipleTokensForAttachedContraction() {
        // The contraction suffix arrives as its own token and attaches with no space.
        let tokens = [
            token("We", 0.0, 0.3),
            token("'re", 0.3, 0.5),
            token("home", 0.6, 1.0),
        ]

        let grouped = TimedLyricSegmentGrouper.group(tokens: tokens)
        XCTAssertEqual(grouped.count, 1)
        let segment = grouped[0]
        XCTAssertEqual(segment.text, "We're home")

        XCTAssertEqual(segment.words.map(\.text), ["We're", "home"])
        // The merged word's onset is the first token's start; offset is the last token's end.
        XCTAssertEqual(segment.words.map(\.start), [0.0, 0.6])
        XCTAssertEqual(segment.words.map(\.end), [0.5, 1.0])
        let characters = Array(segment.text)
        for word in segment.words {
            XCTAssertEqual(String(characters[word.characterRange]), word.text)
        }
    }

    func testEngineReceivesRequestScopedCancellation() async {
        let engine = RecordingTranscriptionEngine()
        let id = UUID()

        await engine.cancel(requestID: id)

        let cancelledIDs = await engine.cancelledIDs
        XCTAssertEqual(cancelledIDs, [id])
        XCTAssertEqual(engine.metadata.modelName, "Test Model")
    }

    private func progress(completed: Int, total: Int) -> TranscriptionProgress {
        TranscriptionProgress(
            phase: .transcribing,
            completedUnits: completed,
            totalUnits: total
        )
    }

    // MARK: - Reference lyric alignment

    func testReferenceAlignerBorrowsASRTimingsAndUsesReferenceLineBreaks() {
        // ASR produced one run-on line (one word mis-heard); the reference has the correct words
        // and two lines. Output uses the reference words/lines with ASR timings.
        let asr = [
            lyricSegment([
                lyricWord("grass", 19.0, 20.0), lyricWord("betwen", 20.1, 20.9),
                lyricWord("my", 20.9, 21.1), lyricWord("toes", 21.2, 21.8),
                lyricWord("smoke", 23.0, 23.6), lyricWord("curls", 23.6, 24.2),
            ])
        ]
        let lines = ReferenceLyricAligner.align(
            referenceText: "Grass between my toes\nSmoke curls", asrSegments: asr)

        XCTAssertEqual(lines.map(\.text), ["Grass between my toes", "Smoke curls"])
        XCTAssertEqual(lines[0].words.map(\.text), ["Grass", "between", "my", "toes"])
        XCTAssertEqual(lines[0].start, 19.0, accuracy: 0.001)  // borrowed from ASR "grass"
        XCTAssertEqual(lines[1].words[0].start, 23.0, accuracy: 0.001)  // "Smoke" -> ASR "smoke"
    }

    func testReferenceAlignerInterpolatesWordsTheASRMissed() {
        // ASR only timed "grass" and "toes"; the reference's "between my" are interpolated between.
        let asr = [lyricSegment([lyricWord("grass", 19.0, 20.0), lyricWord("toes", 22.0, 22.6)])]
        let lines = ReferenceLyricAligner.align(
            referenceText: "Grass between my toes", asrSegments: asr)

        let words = lines[0].words
        XCTAssertEqual(words.map(\.text), ["Grass", "between", "my", "toes"])
        XCTAssertEqual(words[0].start, 19.0, accuracy: 0.001)
        XCTAssertEqual(words[3].start, 22.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(words[1].start, 20.0)  // interpolated inside the gap
        XCTAssertLessThanOrEqual(words[2].end, 22.0001)
        XCTAssertLessThanOrEqual(words[1].start, words[2].start)  // monotonic
    }

    func testReferenceAlignerComputesCharacterRangesAndKeepsPunctuation() {
        let asr = [lyricSegment([lyricWord("hello", 0, 1), lyricWord("world", 1, 2)])]
        let lines = ReferenceLyricAligner.align(
            referenceText: "Hello, world!", asrSegments: asr)

        XCTAssertEqual(lines[0].text, "Hello, world!")
        XCTAssertEqual(lines[0].words[0].characterRange, 0..<6)  // "Hello,"
        XCTAssertEqual(lines[0].words[1].characterRange, 7..<13)  // "world!"
    }

    func testReferenceAlignerReturnsASRWhenReferenceBlank() {
        let asr = [lyricSegment([lyricWord("hi", 0, 1)])]
        XCTAssertEqual(
            ReferenceLyricAligner.align(referenceText: "  \n\n ", asrSegments: asr), asr)
    }

    func testReferenceAlignerDropsPastedSiteTimestamps() {
        // Lyrics pasted from a site carried a trailing "0:00" (Flip Flops regression): a
        // timestamp-only line must vanish entirely, and a timestamp token inside a line must
        // not become a word.
        let asr = [lyricSegment([lyricWord("hello", 0, 1), lyricWord("world", 1, 2)])]
        let lines = ReferenceLyricAligner.align(
            referenceText: "Hello world 0:00\n\n0:00\n1:23:45", asrSegments: asr)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.map(\.text), ["Hello", "world"])
    }

    private func lyricWord(_ text: String, _ start: TimeInterval, _ end: TimeInterval)
        -> TimedLyricWord
    {
        TimedLyricWord(text: text, start: start, end: end, characterRange: 0..<0)
    }

    private func lyricSegment(_ words: [TimedLyricWord]) -> TimedLyricSegment {
        TimedLyricSegment(
            start: words.first?.start ?? 0,
            end: words.last?.end ?? 0,
            text: words.map(\.text).joined(separator: " "),
            words: words)
    }

    private func token(
        _ text: String,
        _ startTime: TimeInterval,
        _ endTime: TimeInterval,
        confidence: Float? = nil
    ) -> TimedTranscriptionToken {
        TimedTranscriptionToken(
            text: text,
            startTime: startTime,
            endTime: endTime,
            confidence: confidence
        )
    }

    private func segment(tokens: [TimedTranscriptionToken]) -> TimedTranscriptionSegment {
        TimedTranscriptionSegment(
            text: tokens.map(\.text).joined(separator: " "),
            startTime: tokens.first?.startTime ?? 0,
            endTime: tokens.last?.endTime ?? 0,
            tokens: tokens,
            confidence: nil
        )
    }

    private func makeResult(
        segments: [TimedTranscriptionSegment] = []
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            languageCode: "en",
            sourceDuration: 120,
            completedAt: Date(timeIntervalSince1970: 1_000),
            segments: segments,
            engine: TranscriptionEngineMetadata(
                engineName: "Test Engine",
                modelName: "Test Model",
                modelVersion: "1.0",
                modelSizeBytes: 1_500_000_000,
                license: TranscriptionModelLicense(
                    name: "MIT",
                    url: URL(string: "https://opensource.org/license/mit")
                )
            )
        )
    }

    // MARK: - RepeatedLyricCorrector

    func testRepeatedLyricCorrectorFixesMinorityWordWithTwoThirdsMajority() {
        let segments = [
            lyricSegment("flip flops and barbecue"),
            lyricSegment("flip flops and barbecue"),
            lyricSegment("slip flops and barbecue"),
        ]

        let corrected = RepeatedLyricCorrector().corrected(segments)

        XCTAssertEqual(corrected.map(\.text), Array(repeating: "flip flops and barbecue", count: 3))
        XCTAssertEqual(
            corrected[2].words.map(\.text),
            ["flip", "flops", "and", "barbecue"]
        )
        // Timings unchanged: same word count, original starts/ends preserved.
        XCTAssertEqual(corrected[2].words.count, segments[2].words.count)
        XCTAssertEqual(corrected[2].words.map(\.start), segments[2].words.map(\.start))
        XCTAssertEqual(corrected[2].words.map(\.end), segments[2].words.map(\.end))
        // Idempotent.
        XCTAssertEqual(RepeatedLyricCorrector().corrected(corrected), corrected)
    }

    func testRepeatedLyricCorrectorLeavesColumnWithoutMajorityUnchanged() {
        let segments = [
            lyricSegment("red flops and barbecue"),
            lyricSegment("blue flops and barbecue"),
            lyricSegment("green flops and barbecue"),
        ]

        let corrected = RepeatedLyricCorrector().corrected(segments)

        XCTAssertEqual(corrected, segments)
    }

    func testRepeatedLyricCorrectorLeavesTwoLineClusterUnchanged() {
        let segments = [
            lyricSegment("flip flops and barbecue"),
            lyricSegment("slip flops and barbecue"),
        ]

        let corrected = RepeatedLyricCorrector().corrected(segments)

        XCTAssertEqual(corrected, segments)
    }

    func testRepeatedLyricCorrectorAlignsShiftedContentInsteadOfByIndex() {
        // Index-alignment would compare "rabbit" vs "grab" vs "grab" at column 0 and corrupt the
        // line. Sequence alignment recovers the shared run and only the genuine garble ("grin" →
        // "grim") is a minority, so it is the sole change.
        let segments = [
            lyricSegment("grab a chair grab a grim"),
            lyricSegment("grab a chair grab a grim"),
            lyricSegment("grab a chair grab a grin"),
        ]

        let corrected = RepeatedLyricCorrector().corrected(segments)

        XCTAssertEqual(
            corrected.map(\.text),
            Array(repeating: "grab a chair grab a grim", count: 3)
        )
    }

    func testRepeatedLyricCorrectorPreservesPunctuationAndCapitalization() {
        // The garbled member carries leading capitalization and trailing punctuation that must
        // survive the core swap: "Barbecue," → "Bruise,".
        let segments = [
            lyricSegment("flip flops and bruise"),
            lyricSegment("flip flops and bruise"),
            lyricSegment("flip flops and Barbecue,"),
        ]

        let corrected = RepeatedLyricCorrector().corrected(segments)

        XCTAssertEqual(corrected[2].text, "flip flops and Bruise,")
        XCTAssertEqual(corrected[2].words.last?.text, "Bruise,")
    }

    // MARK: - TranscriptionSilenceGate

    func testSilenceGateDropsSingleLowConfidenceWordIsolatedInSilence() {
        // A real opening line, a long instrumental gap, one stray low-confidence word alone in
        // that gap, another long gap, then a real closing line. The stray word is dropped.
        let tokens = [
            token("Hello", 0.0, 0.4, confidence: 0.95),
            token("world", 0.5, 0.9, confidence: 0.95),
            token("uh", 10.0, 10.3, confidence: 0.2),  // isolated low-confidence stray
            token("Goodbye", 20.0, 20.4, confidence: 0.95),
            token("now", 20.5, 20.9, confidence: 0.95),
        ]

        let filtered = TranscriptionSilenceGate.filtered(tokens)

        XCTAssertEqual(
            filtered.map(\.text),
            ["Hello", "world", "Goodbye", "now"]
        )
    }

    func testSilenceGateKeepsRealMultiWordLineEvenIfLowConfidence() {
        // A multi-word line whose words sit close together (no internal isolating silence) is one
        // island. With more than maxIslandTokens words it is kept even though all are low conf.
        let tokens = [
            token("Hello", 0.0, 0.4, confidence: 0.95),
            token("there", 0.5, 0.9, confidence: 0.95),
            token("whisper", 10.0, 10.3, confidence: 0.2),
            token("these", 10.4, 10.7, confidence: 0.2),
            token("quiet", 10.8, 11.1, confidence: 0.2),
            token("little", 11.2, 11.5, confidence: 0.2),
            token("words", 11.6, 11.9, confidence: 0.2),
            token("Goodbye", 20.0, 20.4, confidence: 0.95),
        ]

        let filtered = TranscriptionSilenceGate.filtered(tokens)

        XCTAssertEqual(filtered, tokens)
    }

    func testSilenceGateKeepsLowConfidenceWordAdjacentToHighConfidenceLine() {
        // The low-confidence word sits a small gap (0.1s) after a high-confidence line, so it is
        // part of that island — not isolated — and is kept.
        let tokens = [
            token("Hello", 10.0, 10.4, confidence: 0.95),
            token("world", 10.5, 10.9, confidence: 0.95),
            token("hmm", 11.0, 11.3, confidence: 0.2),  // small gap: not isolated
        ]

        let filtered = TranscriptionSilenceGate.filtered(tokens)

        XCTAssertEqual(filtered, tokens)
    }

    func testSilenceGateKeepsIslandContainingNilConfidenceToken() {
        // An isolated short island whose lone token has nil confidence could be a real word, so
        // it is kept.
        let tokens = [
            token("Hello", 0.0, 0.4, confidence: 0.95),
            token("mystery", 10.0, 10.3, confidence: nil),  // isolated but nil confidence
            token("Goodbye", 20.0, 20.4, confidence: 0.95),
        ]

        let filtered = TranscriptionSilenceGate.filtered(tokens)

        XCTAssertEqual(filtered, tokens)
    }

    func testSilenceGateKeepsHighConfidenceIsolatedWord() {
        // A confidently transcribed word alone in a gap is a real lyric (e.g. a held note) and is
        // kept.
        let tokens = [
            token("Hello", 0.0, 0.4, confidence: 0.95),
            token("yeah", 10.0, 10.3, confidence: 0.95),  // isolated but high confidence
            token("Goodbye", 20.0, 20.4, confidence: 0.95),
        ]

        let filtered = TranscriptionSilenceGate.filtered(tokens)

        XCTAssertEqual(filtered, tokens)
    }

    func testSilenceGatePassesThroughUnchangedWithNoQualifyingIslands() {
        // A normal continuous line with no isolated low-confidence strays is returned identically.
        let tokens = [
            token("just", 0.0, 0.3, confidence: 0.4),
            token("good", 0.4, 0.7, confidence: 0.4),
            token("friends", 0.8, 1.2, confidence: 0.4),
            token("and", 1.3, 1.5, confidence: 0.4),
            token("a", 1.6, 1.7, confidence: 0.4),
            token("beer", 1.8, 2.2, confidence: 0.4),
        ]

        XCTAssertEqual(TranscriptionSilenceGate.filtered(tokens), tokens)
        // Idempotent on its own output.
        let once = TranscriptionSilenceGate.filtered(tokens)
        XCTAssertEqual(TranscriptionSilenceGate.filtered(once), once)
        XCTAssertTrue(TranscriptionSilenceGate.filtered([]).isEmpty)
    }

    func testSilenceGateDropsTrailingIslandWhenSourceDurationProvided() {
        // Real lines early, then a long instrumental outro with one stray low-confidence word.
        let tokens = [
            token("Hello", 0.0, 0.4, confidence: 0.95),
            token("world", 0.5, 0.9, confidence: 0.95),
            token("uh", 55.0, 55.3, confidence: 0.2),
        ]

        let filtered = TranscriptionSilenceGate.filtered(tokens, sourceDuration: 60)

        XCTAssertEqual(filtered.map(\.text), ["Hello", "world"])
    }

    /// Builds a single lyric line (one segment) from a phrase, with real per-word timings and
    /// `characterRange`s produced by the production grouper. Tokens get small increasing
    /// timestamps so they stay in one group.
    private func lyricSegment(_ phrase: String) -> TimedLyricSegment {
        var time = 0.0
        let tokens = phrase.split(separator: " ").map { word -> TimedTranscriptionToken in
            let start = time
            time += 0.1
            return token(String(word), start, time - 0.02)
        }
        return TimedLyricSegmentGrouper.group(tokens: tokens)[0]
    }

    private func transcriptionSegment(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> TimedTranscriptionSegment {
        let words = text.split(separator: " ")
        let duration = max(end - start, 0)
        let step = words.isEmpty ? 0 : duration / Double(words.count)
        let tokens = words.enumerated().map { index, word in
            TimedTranscriptionToken(
                text: String(word),
                startTime: start + Double(index) * step,
                endTime: start + Double(index + 1) * step,
                confidence: 0.9
            )
        }
        return TimedTranscriptionSegment(
            text: text,
            startTime: start,
            endTime: end,
            tokens: tokens,
            confidence: 0.9
        )
    }

    private func transcriptionResult(
        segments: [TimedTranscriptionSegment],
        sourceDuration: TimeInterval
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            languageCode: "en",
            sourceDuration: sourceDuration,
            completedAt: Date(timeIntervalSince1970: 0),
            segments: segments,
            engine: TranscriptionEngineMetadata(
                engineName: "test",
                modelName: "test",
                modelVersion: "1",
                modelSizeBytes: 1,
                license: TranscriptionModelLicense(name: "test", url: nil)
            )
        )
    }

    private func assertSendable<T: Sendable>(_ value: T) {}

    private func storedLine(_ words: [(String, TimeInterval, TimeInterval)]) -> TimedLyricSegment {
        var offset = 0
        let timed = words.map { text, start, end in
            defer { offset += text.count + 1 }
            return TimedLyricWord(
                text: text, start: start, end: end, characterRange: offset..<(offset + text.count))
        }
        return TimedLyricSegment(
            start: words[0].1, end: words[words.count - 1].2,
            text: words.map(\.0).joined(separator: " "), words: timed)
    }

    private func assertSegments(
        _ actual: [TimedLyricSegment],
        equal expected: [(text: String, start: TimeInterval, end: TimeInterval)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.map(\.text), expected.map(\.text), file: file, line: line)
        XCTAssertEqual(actual.map(\.start), expected.map(\.start), file: file, line: line)
        XCTAssertEqual(actual.map(\.end), expected.map(\.end), file: file, line: line)
    }
}

private actor RecordingTranscriptionEngine: TranscriptionEngine {
    nonisolated let metadata = TranscriptionEngineMetadata(
        engineName: "Test Engine",
        modelName: "Test Model",
        modelVersion: nil,
        modelSizeBytes: 1,
        license: TranscriptionModelLicense(name: "Test", url: nil)
    )

    private(set) var cancelledIDs: [UUID] = []

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        throw CancellationError()
    }

    func cancel(requestID: UUID) async {
        cancelledIDs.append(requestID)
    }
}

final class StretchedWordRetimerTests: XCTestCase {
    /// "Flowing from that warm Louisiana breeze" in Back to New Orleans: "breeze" glued to the end
    /// of "Louisiana" and stretched to the next line; the vocals attack it at ~58.47 s.
    private func breezeLine(breezeStart: TimeInterval = 57.77, breezeEnd: TimeInterval = 60.65)
        -> TimedLyricSegment
    {
        TimedLyricSegment(
            start: 56.74, end: breezeEnd, text: "Louisiana breeze",
            words: [
                TimedLyricWord(text: "Louisiana", start: 56.74, end: 57.76, characterRange: 0..<9),
                TimedLyricWord(
                    text: "breeze", start: breezeStart, end: breezeEnd, characterRange: 10..<16),
            ])
    }

    /// Steady singing at -10 dB, with a 30 ms dip to -25 dB just before each `attack` — so the
    /// voice rises 15 dB into it.
    private func singing(attacks: [TimeInterval]) -> VocalAttackEnvelope {
        var decibels = [Float](repeating: -10, count: 6_200)
        for attack in attacks {
            let frame = Int((attack / 0.01).rounded())
            for dip in (frame - 3)..<frame { decibels[dip] = -25 }
        }
        return VocalAttackEnvelope(decibels: decibels, hopSeconds: 0.01)
    }

    func testAStretchedWordIsFlaggedButNeverMoved() {
        let line = breezeLine()
        let (segments, findings) = StretchedWordRetimer.retimed(
            [line], attacks: singing(attacks: [58.47]), beatLength: 0.5728)
        XCTAssertEqual(segments, [line], "word times never change")
        XCTAssertEqual(findings.map(\.kind), [.suspect])
    }

    func testWordsTheVocalsAlreadySupportAreLeftAlone() {
        // A strong attack at the transcribed start.
        XCTAssertEqual(
            StretchedWordRetimer.retimed(
                [breezeLine()], attacks: singing(attacks: [57.77, 58.47]), beatLength: 0.5728
            ).findings, [])
        // Not glued: a real gap before the word.
        XCTAssertEqual(
            StretchedWordRetimer.retimed(
                [breezeLine(breezeStart: 58.10)], attacks: singing(attacks: [58.9]),
                beatLength: 0.5728
            ).findings, [])
        // Too short to be stretched (under 2 beats).
        XCTAssertEqual(
            StretchedWordRetimer.retimed(
                [breezeLine(breezeEnd: 58.70)], attacks: singing(attacks: [58.30]),
                beatLength: 0.5728
            ).findings, [])
    }

    func testAStretchedWordWithNoClearAttackInsideIsOnlyFlagged() {
        let line = breezeLine()
        let (segments, findings) = StretchedWordRetimer.retimed(
            [line], attacks: singing(attacks: []), beatLength: 0.5728)
        XCTAssertEqual(segments, [line], "no timing changes without evidence")
        XCTAssertEqual(
            findings,
            [
                WordTimingFinding(
                    kind: .suspect, text: "breeze", start: 57.77, transcribedStart: 57.77)
            ])
    }
}

// MARK: - Missing phrases hidden by stretched tokens; evidence for recovered words

extension TranscriptionTests {
    private func token(
        _ text: String, _ start: TimeInterval, _ end: TimeInterval, _ confidence: Float?
    )
        -> TimedTranscriptionToken
    {
        TimedTranscriptionToken(text: text, startTime: start, endTime: end, confidence: confidence)
    }

    func testWordlessGapRescueFindsAPhraseHiddenInsideAStretchedToken() {
        // Whisper glued "hold" to the next line and stretched it 10.0-16.0 s; the singer sang a
        // whole phrase from 11 s that no token names.
        let stretched = TimedTranscriptionSegment(
            text: "hold on", startTime: 10, endTime: 16.4,
            tokens: [token("hold", 10, 16, 0.9), token("on", 16, 16.4, 0.9)], confidence: 0.9)
        let primary = transcriptionResult(segments: [stretched], sourceDuration: 60)

        let gaps = WordlessVocalGapRescuer.gaps(in: primary, sungIntervals: [10...16.4])

        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.lowerBound ?? 0, 10.85, accuracy: 1e-9)
        XCTAssertEqual(gaps.first?.upperBound ?? 0, 15.75, accuracy: 1e-9)
        // Raw spans called this stretch fully transcribed; supported word spans do not.
        let coverage = TranscriptionVoicedCoverage.fraction(
            of: primary, voicedIntervals: [10...16.4])
        XCTAssertEqual(coverage ?? 1, 1.5 / 6.4, accuracy: 1e-9)
    }

    func testWordlessGapRescueRejectsLowConfidenceAndUnsungRetryWords() {
        let primary = transcriptionResult(
            segments: [transcriptionSegment("me and you", start: 19.6, end: 20.5)],
            sourceDuration: 60)
        let unsure = TimedTranscriptionSegment(
            text: "the end you", startTime: 1, endTime: 2.5,
            tokens: [
                token("the", 1, 1.5, 0.2), token("end", 1.5, 2, 0.2), token("you", 2, 2.5, 0.2),
            ],
            confidence: 0.2)
        let lowConfidence = transcriptionResult(segments: [unsure], sourceDuration: 9)
        XCTAssertEqual(
            WordlessVocalGapRescuer.merged(
                primary: primary, retry: lowConfidence, retryStart: 12, gap: 13...19.35),
            primary)

        let confident = transcriptionResult(
            segments: [transcriptionSegment("the end you", start: 1, end: 2.5)],
            sourceDuration: 9)
        // Sung audio only from 17 s: the retry words at 13-14.5 s have no acoustic support.
        XCTAssertEqual(
            WordlessVocalGapRescuer.merged(
                primary: primary, retry: confident, retryStart: 12, gap: 13...19.35,
                sungIntervals: [17...19.35]),
            primary)
        let supported = WordlessVocalGapRescuer.merged(
            primary: primary, retry: confident, retryStart: 12, gap: 13...19.35,
            sungIntervals: [12.9...19.35])
        XCTAssertEqual(supported.segments.map(\.text), ["the end you", "me and you"])
    }

    /// Slowed decoding renders the audio at `rate` and scales timestamps back by `rate`. Clicks at
    /// known times must come back where they were: no constant offset from the time-stretch
    /// unit's latency, and no drift that grows through the song.
    func testSlowDecodeExportAndTimestampScalingNeitherOffsetNorDrift() async throws {
        let sampleRate: Double = 44_100
        var clickTimes: [TimeInterval] = []
        for index in 0..<40 {
            clickTimes.append(0.5 + Double(index) * 1.37 + Double(index % 3) * 0.11)
        }
        let duration: TimeInterval = clickTimes[clickTimes.count - 1] + 2
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let burstLength = Int(0.03 * sampleRate)
        for time in clickTimes {
            let first = Int(time * sampleRate)
            for index in 0..<burstLength {
                // A 1 kHz burst with a hard attack and short decay.
                let seconds = Double(index) / sampleRate
                let value: Double = sin(2 * Double.pi * 1_000 * seconds) * exp(-seconds / 0.008)
                samples[first + index] = Float(value * 0.8)
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("clicks.wav")
        let slowURL = directory.appendingPathComponent("slow.wav")
        try AVAudioFile(forWriting: sourceURL, settings: format.settings).write(from: buffer)

        // The stage quantizes the Accuracy decode rate to what the time-stretch really plays.
        let rate = OfflineExportSettings.timeStretchRate(0.85)
        try await OfflineAudioExporter().export(
            sourceURL: sourceURL, destinationURL: slowURL,
            settings: OfflineExportSettings(pitchSemitones: 0, tempoRate: rate))

        let slow = try AVAudioFile(forReading: slowURL)
        let slowBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: slow.processingFormat, frameCapacity: AVAudioFrameCount(slow.length)))
        try slow.read(into: slowBuffer)
        let slowSamples = try XCTUnwrap(slowBuffer.floatChannelData?[0])
        let slowRate = slow.processingFormat.sampleRate
        // Onsets: the first sample over 0.3 after half a second without one.
        var onsets: [TimeInterval] = []
        var lastLoud: TimeInterval = -1
        for index in 0..<Int(slowBuffer.frameLength) where abs(slowSamples[index]) > 0.3 {
            let time = Double(index) / slowRate
            if time - lastLoud > 0.5 { onsets.append(time) }
            lastLoud = time
        }
        XCTAssertEqual(onsets.count, clickTimes.count)
        guard onsets.count == clickTimes.count else { return }

        // The same mapping the transcription stage applies to slowed-decode timestamps.
        let tokens = onsets.map { token("x", $0, $0, nil) }
        let slowed = transcriptionResult(
            segments: [
                TimedTranscriptionSegment(
                    text: "x", startTime: onsets[0], endTime: onsets[onsets.count - 1],
                    tokens: tokens, confidence: nil)
            ],
            sourceDuration: Double(slow.length) / slowRate)
        let mapped = TranscriptionTimeScaler.scaled(slowed, by: rate).segments[0].tokens
        var errors: [Double] = []
        for (mappedToken, click) in zip(mapped, clickTimes) {
            errors.append(mappedToken.startTime - click)
        }
        let meanError = errors.reduce(0, +) / Double(errors.count)
        let meanTime = clickTimes.reduce(0, +) / Double(clickTimes.count)
        var covariance: Double = 0
        var variance: Double = 0
        for (time, error) in zip(clickTimes, errors) {
            covariance += (time - meanTime) * (error - meanError)
            variance += (time - meanTime) * (time - meanTime)
        }
        let drift = covariance / variance * duration
        let worst = errors.map { Swift.abs($0) }.max() ?? 0
        print(
            String(
                format: "slow decode: mean offset %.4f s, drift over song %.4f s, worst %.4f s",
                meanError, drift, worst))
        XCTAssertLessThan(Swift.abs(meanError), 0.02, "constant offset")
        XCTAssertLessThan(Swift.abs(drift), 0.02, "drift across the song")
        XCTAssertLessThan(worst, 0.04)
    }
}

// MARK: - MANUAL: slowed-decode timing sweep

extension TranscriptionTests {
    /// Measures where `OfflineAudioExporter`'s time-stretch puts known clicks, per rate, sample
    /// rate and length. `SW_SLOW_DECODE_SWEEP=1 swift test --filter testSlowDecodeTimingSweep`
    func testSlowDecodeTimingSweep() async throws {
        guard ProcessInfo.processInfo.environment["SW_SLOW_DECODE_SWEEP"] == "1" else {
            throw XCTSkip("manual sweep; set SW_SLOW_DECODE_SWEEP=1")
        }
        for sampleRate in [44_100.0, 48_000.0] {
            for seconds in [60.0, 240.0] {
                for rate in [0.75, 0.85, 0.95] {
                    let result = try await clickRoundTrip(
                        sampleRate: sampleRate, seconds: seconds, rate: rate)
                    print(
                        String(
                            format:
                                "sweep sr=%.0f len=%.0f rate=%.2f offset=%.4f slope=%.7f outLen/expected=%.7f",
                            sampleRate, seconds, rate, result.offset, result.slope,
                            result.lengthRatio))
                }
            }
        }
    }

    private func clickRoundTrip(sampleRate: Double, seconds: Double, rate: Double) async throws
        -> (offset: Double, slope: Double, lengthRatio: Double)
    {
        var clickTimes: [TimeInterval] = []
        var time = 0.5
        while time < seconds - 2 {
            clickTimes.append(time)
            time += 1.37
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for click in clickTimes {
            let first = Int(click * sampleRate)
            for index in 0..<Int(0.03 * sampleRate) {
                let t = Double(index) / sampleRate
                samples[first + index] = Float(
                    sin(2 * Double.pi * 1_000 * t) * exp(-t / 0.008) * 0.8)
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("clicks.wav")
        let slowURL = directory.appendingPathComponent("slow.wav")
        try AVAudioFile(forWriting: sourceURL, settings: format.settings).write(from: buffer)
        try await OfflineAudioExporter().export(
            sourceURL: sourceURL, destinationURL: slowURL,
            settings: OfflineExportSettings(pitchSemitones: 0, tempoRate: rate))
        let slow = try AVAudioFile(forReading: slowURL)
        let slowBuffer = AVAudioPCMBuffer(
            pcmFormat: slow.processingFormat, frameCapacity: AVAudioFrameCount(slow.length))!
        try slow.read(into: slowBuffer)
        let slowSamples = slowBuffer.floatChannelData![0]
        let slowRate = slow.processingFormat.sampleRate
        var onsets: [TimeInterval] = []
        var lastLoud: TimeInterval = -1
        for index in 0..<Int(slowBuffer.frameLength) where Swift.abs(slowSamples[index]) > 0.3 {
            let t = Double(index) / slowRate
            if t - lastLoud > 0.5 { onsets.append(t) }
            lastLoud = t
        }
        let count = min(onsets.count, clickTimes.count)
        var errors: [Double] = []
        for index in 0..<count { errors.append(onsets[index] * rate - clickTimes[index]) }
        let meanError = errors.reduce(0, +) / Double(max(count, 1))
        let meanTime = clickTimes.prefix(count).reduce(0, +) / Double(max(count, 1))
        var covariance = 0.0
        var variance = 0.0
        for index in 0..<count {
            covariance += (clickTimes[index] - meanTime) * (errors[index] - meanError)
            variance += (clickTimes[index] - meanTime) * (clickTimes[index] - meanTime)
        }
        let slope = covariance / max(variance, 1e-9)
        return (meanError - slope * meanTime, slope, Double(slow.length) / (Double(frames) / rate))
    }
}

// MARK: - Decode loops

extension TranscriptionTests {
    private func repeatedSegment(_ text: String, start: TimeInterval, duration: TimeInterval)
        -> TimedTranscriptionSegment
    {
        transcriptionSegment(text, start: start, end: start + duration)
    }

    func testDecodeLoopGuardRemovesUnsingableRepeatsAndReportsTheirSpan() {
        let phrase = "one two three four five six seven eight nine ten"
        let segments =
            [transcriptionSegment("before the loop", start: 90, end: 94)]
            + (0..<5).map { repeatedSegment(phrase, start: 94.7 + Double($0) * 0.5, duration: 0.5) }
        let looped = transcriptionResult(segments: segments, sourceDuration: 225)

        let guarded = DecodeLoopGuard.removingLoops(looped, vocalOnsets: [])

        XCTAssertEqual(guarded.result.segments.count, 2)
        XCTAssertEqual(guarded.removed.count, 1)
        XCTAssertEqual(guarded.removed.first?.lowerBound ?? 0, 95.2, accuracy: 1e-9)
        XCTAssertEqual(guarded.removed.first?.upperBound ?? 0, 97.2, accuracy: 1e-9)
    }

    func testDecodeLoopGuardKeepsARepeatedChorusLineTheVocalsSing() {
        let line = "hold me close tonight my dear"
        let chorus = transcriptionResult(
            segments: [
                repeatedSegment(line, start: 10, duration: 3),
                repeatedSegment(line, start: 13.2, duration: 3),
            ],
            sourceDuration: 60)
        let onsets = stride(from: 13.2, to: 16.2, by: 0.5).map { $0 }

        XCTAssertEqual(
            DecodeLoopGuard.removingLoops(chorus, vocalOnsets: onsets).result, chorus)
        // The same repeat with no vocal onsets under it on a stem is not sung.
        XCTAssertEqual(
            DecodeLoopGuard.removingLoops(chorus, vocalOnsets: [1, 2, 3]).result.segments.count, 1)
    }
}
