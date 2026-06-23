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
