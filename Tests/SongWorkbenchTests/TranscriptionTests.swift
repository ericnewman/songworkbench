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

        assertSegments(
            TimedLyricSegmentGrouper.group(tokens: tokens, configuration: configuration),
            equal: [
                ("one two", 0, 0.9),
                ("three", 1, 1.4),
                ("four", 3, 3.4),
                ("five", 4, 5.5),
            ]
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
