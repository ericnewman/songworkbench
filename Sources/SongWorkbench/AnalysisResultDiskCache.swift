import CryptoKit
import Foundation

struct AnalysisEngineVersion: Hashable, Codable, Sendable {
    let identifier: String
    let version: String
}

struct AnalysisResultCacheKey: Hashable, Codable, Sendable {
    let sourceSHA256: String
    let engine: AnalysisEngineVersion
}

actor AnalysisResultDiskCache {
    private struct Envelope<Value: Codable>: Codable {
        let schemaVersion: Int
        let key: AnalysisResultCacheKey
        let value: Value
    }

    let directoryURL: URL
    let schemaVersion: Int

    init(directoryURL: URL, schemaVersion: Int = 1) {
        precondition(schemaVersion > 0, "Cache schema version must be positive")
        self.directoryURL = directoryURL
        self.schemaVersion = schemaVersion
    }

    func key(for sourceData: Data, engine: AnalysisEngineVersion) -> AnalysisResultCacheKey {
        key(forSourceHash: Self.sha256Hex(sourceData), engine: engine)
    }

    func key(forSourceHash sourceSHA256: String, engine: AnalysisEngineVersion)
        -> AnalysisResultCacheKey
    {
        AnalysisResultCacheKey(
            sourceSHA256: sourceSHA256,
            engine: engine
        )
    }

    func value<Value: Codable & Sendable>(
        for sourceData: Data,
        engine: AnalysisEngineVersion,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        try value(forSourceHash: Self.sha256Hex(sourceData), engine: engine, as: type)
    }

    func value<Value: Codable & Sendable>(
        forSourceHash sourceSHA256: String,
        engine: AnalysisEngineVersion,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        let cacheKey = key(forSourceHash: sourceSHA256, engine: engine)
        let fileURL = fileURL(for: cacheKey)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let envelope: Envelope<Value>
        do {
            let data = try Data(contentsOf: fileURL)
            envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard envelope.schemaVersion == schemaVersion, envelope.key == cacheKey else {
            return nil
        }
        return envelope.value
    }

    func store<Value: Codable & Sendable>(
        _ value: Value,
        for sourceData: Data,
        engine: AnalysisEngineVersion
    ) throws {
        try store(value, forSourceHash: Self.sha256Hex(sourceData), engine: engine)
    }

    func store<Value: Codable & Sendable>(
        _ value: Value,
        forSourceHash sourceSHA256: String,
        engine: AnalysisEngineVersion
    ) throws {
        let cacheKey = key(forSourceHash: sourceSHA256, engine: engine)
        let envelope = Envelope(schemaVersion: schemaVersion, key: cacheKey, value: value)
        let data = try JSONEncoder().encode(envelope)

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL(for: cacheKey), options: .atomic)
    }

    private func fileURL(for key: AnalysisResultCacheKey) -> URL {
        let identity = [
            "schema=\(schemaVersion)",
            "source=\(key.sourceSHA256)",
            "engine-id=\(key.engine.identifier.utf8.count):\(key.engine.identifier)",
            "engine-version=\(key.engine.version.utf8.count):\(key.engine.version)",
        ].joined(separator: "\n")
        let filename = Self.sha256Hex(Data(identity.utf8)) + ".json"
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
