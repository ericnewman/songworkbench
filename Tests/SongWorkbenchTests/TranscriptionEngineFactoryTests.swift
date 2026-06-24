import Foundation
import XCTest

@testable import SongWorkbench

final class TranscriptionEngineFactoryTests: XCTestCase {
    func testEngineForModeReturnsMatchingEngine() {
        let fast = StubTranscriptionEngine(name: "fast")
        let balanced = StubTranscriptionEngine(name: "balanced")
        let accuracy = StubTranscriptionEngine(name: "accuracy")
        let factory = TranscriptionEngineFactory(
            fast: fast,
            balanced: balanced,
            accuracy: accuracy
        )

        XCTAssertEqual(engineName(factory.engine(for: .fastDraft)), "fast")
        XCTAssertEqual(engineName(factory.engine(for: .balancedDraft)), "balanced")
        XCTAssertEqual(engineName(factory.engine(for: .accuracy)), "accuracy")
    }

    func testEngineForModeReturnsNilWhenEngineAbsent() {
        let factory = TranscriptionEngineFactory(
            fast: StubTranscriptionEngine(name: "fast"),
            balanced: nil,
            accuracy: nil
        )

        XCTAssertNotNil(factory.engine(for: .fastDraft))
        XCTAssertNil(factory.engine(for: .balancedDraft))
        XCTAssertNil(factory.engine(for: .accuracy))
    }

    func testAvailableModesReflectsNonNilEngines() {
        XCTAssertEqual(TranscriptionEngineFactory().availableModes(), [])

        let onlyFast = TranscriptionEngineFactory(fast: StubTranscriptionEngine(name: "fast"))
        XCTAssertEqual(onlyFast.availableModes(), [.fastDraft])

        let fastAndAccuracy = TranscriptionEngineFactory(
            fast: StubTranscriptionEngine(name: "fast"),
            accuracy: StubTranscriptionEngine(name: "accuracy")
        )
        XCTAssertEqual(fastAndAccuracy.availableModes(), [.fastDraft, .accuracy])

        let all = TranscriptionEngineFactory(
            fast: StubTranscriptionEngine(name: "fast"),
            balanced: StubTranscriptionEngine(name: "balanced"),
            accuracy: StubTranscriptionEngine(name: "accuracy")
        )
        XCTAssertEqual(all.availableModes(), [.fastDraft, .balancedDraft, .accuracy])
    }

    private func engineName(_ engine: (any TranscriptionEngine)?) -> String? {
        (engine as? StubTranscriptionEngine)?.name
    }
}

private struct StubTranscriptionEngine: TranscriptionEngine {
    let name: String

    var metadata: TranscriptionEngineMetadata {
        TranscriptionEngineMetadata(
            engineName: name,
            modelName: "stub-model",
            modelVersion: "1",
            modelSizeBytes: 1,
            license: TranscriptionModelLicense(name: "Test", url: nil)
        )
    }

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        throw CancellationError()
    }

    func cancel(requestID: UUID) async {}
}
