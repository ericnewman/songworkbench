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

    func testFilteringDropsModesOutsideCapabilityProfile() {
        let factory = TranscriptionEngineFactory(
            fast: StubTranscriptionEngine(name: "fast"),
            balanced: StubTranscriptionEngine(name: "balanced"),
            accuracy: StubTranscriptionEngine(name: "accuracy")
        )

        let filtered = factory.filtered(to: .profile(for: .iPad))

        XCTAssertEqual(filtered.availableModes(), [.fastDraft, .balancedDraft])
        XCTAssertNil(filtered.engine(for: .accuracy))
    }

    func testCapabilityProfilesEncodeDesktopAndIPadProductTiers() {
        let desktop = AnalysisCapabilityProfile.profile(for: .desktop)
        XCTAssertEqual(desktop.displayName, "Desktop Full")
        XCTAssertEqual(desktop.stemSeparationTier, .fullSixStem)
        XCTAssertTrue(desktop.allowsTranscriptionMode(.accuracy))
        XCTAssertEqual(desktop.executionPolicy, .concurrentIndependentStages)
        XCTAssertTrue(desktop.supportsPerformanceTrack(.leadVocals))
        XCTAssertTrue(desktop.supportsPerformanceTrack(.drumPieces))

        let iPad = AnalysisCapabilityProfile.profile(for: .iPad)
        XCTAssertEqual(iPad.displayName, "iPad Reduced")
        XCTAssertEqual(iPad.stemSeparationTier, .reducedSixStem)
        XCTAssertFalse(iPad.allowsTranscriptionMode(.accuracy))
        XCTAssertEqual(iPad.executionPolicy, .serialHeavyStages)
        XCTAssertFalse(iPad.supportsPerformanceTrack(.leadVocals))
        XCTAssertFalse(iPad.supportsPerformanceTrack(.drumPieces))
        XCTAssertTrue(iPad.supportsPerformanceTrack(.chordTimeline))

        let advanced = AnalysisCapabilityProfile.desktopAdvanced
        XCTAssertEqual(advanced.displayName, "Desktop Advanced")
        XCTAssertEqual(advanced.stemSeparationTier, .advancedDesktop)
        XCTAssertTrue(advanced.allowsTranscriptionMode(.accuracy))
        XCTAssertTrue(advanced.supportsPerformanceTrack(.leadVocals))
        XCTAssertTrue(advanced.supportsPerformanceTrack(.drumPieces))
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
