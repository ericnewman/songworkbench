import Foundation
import XCTest

@testable import SongWorkbench

final class TranscriptionTests: XCTestCase {
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

    private func assertSendable<T: Sendable>(_ value: T) {}

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
