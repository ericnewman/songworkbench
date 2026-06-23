import CryptoKit
import Foundation
import XCTest

@testable import SongWorkbench

final class ModelArtifactManagerTests: XCTestCase {
    func testInstallPublishesVerifiedArtifactAndReportsInstalledState() async throws {
        let payload = Data("model payload".utf8)
        let descriptor = ModelArtifactDescriptor(
            id: "test-model",
            displayName: "Test Model",
            version: "1.0",
            downloadURL: URL(string: "https://example.invalid/model.bin")!,
            expectedSizeBytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            license: ModelArtifactLicense(name: "MIT", attribution: "Test attribution"),
            installedFileName: "model.bin"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ModelArtifactManager(
            directoryURL: directory,
            downloader: StubModelArtifactDownloader(payload: payload)
        )

        let installed = try await manager.install(descriptor) { _ in }

        XCTAssertEqual(installed.descriptorID, descriptor.id)
        XCTAssertEqual(installed.version, descriptor.version)
        XCTAssertEqual(try Data(contentsOf: installed.fileURL), payload)
        let status = await manager.status(for: descriptor)
        XCTAssertEqual(
            status,
            .installed(fileURL: installed.fileURL, sizeBytes: Int64(payload.count))
        )
    }

    func testRemoveDeletesInstalledArtifactAndReturnsToAvailableState() async throws {
        let payload = Data("removable model".utf8)
        let descriptor = ModelArtifactDescriptor(
            id: "removable-model",
            displayName: "Removable Model",
            version: "2.0",
            downloadURL: URL(string: "https://example.invalid/removable.bin")!,
            expectedSizeBytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            license: ModelArtifactLicense(name: "MIT", attribution: "Test attribution"),
            installedFileName: "model.bin"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelArtifactManager(
            directoryURL: directory,
            downloader: StubModelArtifactDownloader(payload: payload)
        )

        let installed = try await manager.install(descriptor) { _ in }
        try await manager.remove(descriptor)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.fileURL.path))
        let status = await manager.status(for: descriptor)
        XCTAssertEqual(status, .available)
    }

    func testStorageUsageCountsOnlyInstalledVerifiedArtifacts() async throws {
        let payload = Data("installed bytes".utf8)
        let installedDescriptor = descriptor(
            id: "installed-model",
            version: "1",
            payload: payload
        )
        let availableDescriptor = descriptor(
            id: "available-model",
            version: "1",
            payload: Data("not downloaded".utf8)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelArtifactManager(
            directoryURL: directory,
            downloader: StubModelArtifactDownloader(payload: payload)
        )
        _ = try await manager.install(installedDescriptor) { _ in }

        let usage = await manager.storageUsage(
            for: [installedDescriptor, availableDescriptor]
        )

        XCTAssertEqual(usage.totalBytes, Int64(payload.count))
        XCTAssertEqual(usage.bytesByDescriptorID, [installedDescriptor.id: Int64(payload.count)])
    }

    private func descriptor(
        id: String,
        version: String,
        payload: Data
    ) -> ModelArtifactDescriptor {
        ModelArtifactDescriptor(
            id: id,
            displayName: id,
            version: version,
            downloadURL: URL(string: "https://example.invalid/\(id).bin")!,
            expectedSizeBytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            license: ModelArtifactLicense(name: "MIT", attribution: "Test attribution"),
            installedFileName: "model.bin"
        )
    }
}

private struct StubModelArtifactDownloader: ModelArtifactDownloading {
    let payload: Data

    func download(
        from _: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(0)
        try payload.write(to: destinationURL)
        progress(1)
    }
}
