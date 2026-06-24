import Foundation
import XCTest

@testable import SongWorkbench

final class SeparationCachingPolicyTests: XCTestCase {
    private let engine = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-cpu-htdemucs-6s",
        engineVersion: "2",
        modelIdentifier: "htdemucs-6s-onnx",
        modelVersion: "125b3e0"
    )

    private var policy: SeparationCachingPolicy {
        SeparationCachingPolicy(currentEngine: engine)
    }

    // MARK: - isCurrentEngine

    func testIsCurrentEngineTrueWhenSucceededAndIdentityMatches() {
        XCTAssertTrue(policy.isCurrentEngine(record(state: .succeeded, provenance: provenance())))
    }

    func testIsCurrentEngineFalseOnEngineIdentifierMismatch() {
        let record = record(
            state: .succeeded,
            provenance: provenance(engineIdentifier: "some-other-engine")
        )
        XCTAssertFalse(policy.isCurrentEngine(record))
    }

    func testIsCurrentEngineFalseOnEngineVersionMismatch() {
        let record = record(state: .succeeded, provenance: provenance(engineVersion: "1"))
        XCTAssertFalse(policy.isCurrentEngine(record))
    }

    func testIsCurrentEngineFalseOnModelIdentifierMismatch() {
        let record = record(
            state: .succeeded,
            provenance: provenance(modelIdentifier: "different-model")
        )
        XCTAssertFalse(policy.isCurrentEngine(record))
    }

    func testIsCurrentEngineIgnoresModelVersion() {
        // modelVersion is intentionally not part of the identity check.
        let record = record(state: .succeeded, provenance: provenance(modelVersion: "deadbeef"))
        XCTAssertTrue(policy.isCurrentEngine(record))
    }

    func testIsCurrentEngineFalseOnNonSucceededStates() {
        for state in [AnalysisStageState.failed, .cancelled, .stale] {
            XCTAssertFalse(
                policy.isCurrentEngine(record(state: state, provenance: provenance())),
                "expected non-current for state \(state.rawValue)"
            )
        }
    }

    func testIsCurrentEngineFalseOnNilRecordOrNilProvenance() {
        XCTAssertFalse(policy.isCurrentEngine(nil))
        XCTAssertFalse(policy.isCurrentEngine(record(state: .succeeded, provenance: nil)))
    }

    // MARK: - isCacheHit

    func testIsCacheHitTrueWhenEverythingMatchesAndFilesExist() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StoredStemFiles(files: sixStemFiles(in: directory))

        XCTAssertTrue(
            policy.isCacheHit(
                record: record(state: .succeeded, provenance: provenance()),
                sourceDigest: "digest",
                storedStems: stems
            )
        )
    }

    func testIsCacheHitFalseWhenSourceDigestDiffers() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StoredStemFiles(files: sixStemFiles(in: directory))

        XCTAssertFalse(
            policy.isCacheHit(
                record: record(
                    state: .succeeded,
                    provenance: provenance(sourceDigest: "other-digest")
                ),
                sourceDigest: "digest",
                storedStems: stems
            )
        )
    }

    func testIsCacheHitFalseWhenEngineDiffers() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StoredStemFiles(files: sixStemFiles(in: directory))

        XCTAssertFalse(
            policy.isCacheHit(
                record: record(
                    state: .succeeded,
                    provenance: provenance(engineVersion: "1")
                ),
                sourceDigest: "digest",
                storedStems: stems
            )
        )
    }

    func testIsCacheHitFalseWhenNotSucceeded() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StoredStemFiles(files: sixStemFiles(in: directory))

        XCTAssertFalse(
            policy.isCacheHit(
                record: record(state: .stale, provenance: provenance()),
                sourceDigest: "digest",
                storedStems: stems
            )
        )
    }

    func testIsCacheHitFalseWhenNotSixSource() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            other: directory.appendingPathComponent("other.wav")
        )
        let stems = StoredStemFiles(files: legacy)

        XCTAssertFalse(
            policy.isCacheHit(
                record: record(state: .succeeded, provenance: provenance()),
                sourceDigest: "digest",
                storedStems: stems
            )
        )
    }

    func testIsCacheHitFalseWhenAStemFileIsMissing() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = sixStemFiles(in: directory)
        let stems = StoredStemFiles(files: files)

        // Delete one stem file so the existence check fails.
        try FileManager.default.removeItem(at: files.piano!)

        XCTAssertFalse(
            policy.isCacheHit(
                record: record(state: .succeeded, provenance: provenance()),
                sourceDigest: "digest",
                storedStems: stems
            )
        )
    }

    func testIsCacheHitFalseWhenStoredStemsNil() {
        XCTAssertFalse(
            policy.isCacheHit(
                record: record(state: .succeeded, provenance: provenance()),
                sourceDigest: "digest",
                storedStems: nil
            )
        )
    }

    func testIsCacheHitFalseWhenRecordNil() throws {
        let directory = try makeStemDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StoredStemFiles(files: sixStemFiles(in: directory))

        XCTAssertFalse(
            policy.isCacheHit(record: nil, sourceDigest: "digest", storedStems: stems)
        )
    }

    // MARK: - shouldMarkStale

    func testShouldMarkStaleTrueWhenRecordNil() {
        XCTAssertTrue(policy.shouldMarkStale(nil))
    }

    func testShouldMarkStaleFalseWhenAlreadyStale() {
        XCTAssertFalse(policy.shouldMarkStale(record(state: .stale, provenance: provenance())))
    }

    func testShouldMarkStaleFalseWhenCurrent() {
        XCTAssertFalse(policy.shouldMarkStale(record(state: .succeeded, provenance: provenance())))
    }

    func testShouldMarkStaleTrueWhenNotStaleAndNotCurrent() {
        let record = record(
            state: .succeeded,
            provenance: provenance(engineVersion: "1")
        )
        XCTAssertTrue(policy.shouldMarkStale(record))
    }

    // MARK: - markStale

    func testMarkStaleProducesExpectedStaleRecord() {
        let original = record(state: .succeeded, provenance: provenance())
        let stale = policy.markStale(original)

        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.provenance, original.provenance)
        XCTAssertEqual(stale.confidence, original.confidence)
        XCTAssertEqual(
            stale.errorMessage,
            "Saved stems were created by an older separator. Rerun Stems."
        )
    }

    func testMarkStaleHandlesNilRecord() {
        let stale = policy.markStale(nil)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertNil(stale.provenance)
        XCTAssertNil(stale.confidence)
        XCTAssertEqual(
            stale.errorMessage,
            "Saved stems were created by an older separator. Rerun Stems."
        )
    }

    // MARK: - Fixtures

    private func record(
        state: AnalysisStageState,
        provenance: AnalysisProvenance?
    ) -> AnalysisStageRecord {
        AnalysisStageRecord(
            state: state,
            provenance: provenance,
            confidence: AnalysisConfidenceSummary(
                average: 0.9,
                lowConfidenceCount: 0,
                totalCount: 6
            ),
            errorMessage: nil
        )
    }

    private func provenance(
        sourceDigest: String = "digest",
        engineIdentifier: String? = nil,
        engineVersion: String? = nil,
        modelIdentifier: String?? = nil,
        modelVersion: String?? = nil
    ) -> AnalysisProvenance {
        AnalysisProvenance(
            sourceDigest: sourceDigest,
            sourceKind: .recording,
            engineIdentifier: engineIdentifier ?? engine.engineIdentifier,
            engineVersion: engineVersion ?? engine.engineVersion,
            modelIdentifier: modelIdentifier ?? engine.modelIdentifier,
            modelVersion: modelVersion ?? engine.modelVersion,
            configurationIdentifier: "six-stem-44.1k-stereo",
            resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
            completedAt: Date(timeIntervalSince1970: 1),
            loadedFromCache: false
        )
    }

    private func makeStemDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in StemKind.allCases {
            let url = directory.appendingPathComponent("\(kind.rawValue).wav")
            try Data().write(to: url)
        }
        return directory
    }

    private func sixStemFiles(in directory: URL) -> StemFiles {
        StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            guitar: directory.appendingPathComponent("guitar.wav"),
            piano: directory.appendingPathComponent("piano.wav"),
            other: directory.appendingPathComponent("other.wav"),
            accompaniment: nil
        )
    }
}
