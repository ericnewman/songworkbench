import Foundation
import XCTest

@testable import SongWorkbench

final class AnalysisResultDiskCacheTests: XCTestCase {
    private struct Result: Codable, Equatable, Sendable {
        let beatsPerMinute: Double
        let label: String
    }

    func testRoundTripsCodableResult() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalysisResultDiskCache(directoryURL: directory)
        let source = Data("audio bytes".utf8)
        let engine = AnalysisEngineVersion(identifier: "tempo", version: "2.1")
        let result = Result(beatsPerMinute: 123.5, label: "detected")

        try await cache.store(result, for: source, engine: engine)
        let loaded = try await cache.value(for: source, engine: engine, as: Result.self)

        XCTAssertEqual(loaded, result)
    }

    func testKeyUsesSourceContentAndEngineIdentity() async {
        let cache = AnalysisResultDiskCache(directoryURL: temporaryDirectory())
        let engine = AnalysisEngineVersion(identifier: "chords", version: "1")

        let first = await cache.key(for: Data("first".utf8), engine: engine)
        let second = await cache.key(for: Data("second".utf8), engine: engine)
        let upgraded = await cache.key(
            for: Data("first".utf8),
            engine: AnalysisEngineVersion(identifier: "chords", version: "2")
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, upgraded)
        XCTAssertEqual(first.sourceSHA256.count, 64)
    }

    func testDifferentEngineOrSchemaVersionDoesNotReuseResult() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Data("same source".utf8)
        let engine = AnalysisEngineVersion(identifier: "waveform", version: "1")
        let cacheV1 = AnalysisResultDiskCache(directoryURL: directory, schemaVersion: 1)

        try await cacheV1.store(
            Result(beatsPerMinute: 90, label: "v1"), for: source, engine: engine)

        let otherEngine: Result? = try await cacheV1.value(
            for: source,
            engine: AnalysisEngineVersion(identifier: "waveform", version: "2")
        )
        let cacheV2 = AnalysisResultDiskCache(directoryURL: directory, schemaVersion: 2)
        let otherSchema: Result? = try await cacheV2.value(for: source, engine: engine)
        XCTAssertNil(otherEngine)
        XCTAssertNil(otherSchema)
    }

    func testOverwriteLeavesOneDecodableAtomicResultFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalysisResultDiskCache(directoryURL: directory)
        let source = Data("source".utf8)
        let engine = AnalysisEngineVersion(identifier: "pitch", version: "3")

        try await cache.store(
            Result(beatsPerMinute: 100, label: "old"), for: source, engine: engine)
        try await cache.store(
            Result(beatsPerMinute: 101, label: "new"), for: source, engine: engine)

        let loaded = try await cache.value(for: source, engine: engine, as: Result.self)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(loaded, Result(beatsPerMinute: 101, label: "new"))
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.pathExtension, "json")
    }

    func testCorruptEntryIsRemovedAndTreatedAsCacheMiss() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalysisResultDiskCache(directoryURL: directory)
        let source = Data("source".utf8)
        let engine = AnalysisEngineVersion(identifier: "engine", version: "1")
        try await cache.store(
            Result(beatsPerMinute: 120, label: "cached"),
            for: source,
            engine: engine
        )
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first
        )
        try Data("not-json".utf8).write(to: file)

        let value: Result? = try await cache.value(for: source, engine: engine)

        XCTAssertNil(value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnalysisResultDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    }
}
