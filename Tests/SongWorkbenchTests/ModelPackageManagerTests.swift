import CryptoKit
import Foundation
import XCTest

@testable import SongWorkbench

final class ModelPackageManagerTests: XCTestCase {
    func testProductionCatalogContainsThreeCompleteVersionedPackages() {
        XCTAssertEqual(
            Set(ModelCatalog.all.map(\.id)),
            Set([
                "htdemucs-6s-onnx",
                "parakeet-tdt-0.6b-v3-coreml-int8",
                "whisper-large-v3-turbo-q5-0",
            ])
        )
        XCTAssertTrue(
            ModelCatalog.all.allSatisfy {
                !$0.version.isEmpty
                    && !$0.minimumOSVersion.isEmpty
                    && !$0.license.name.isEmpty
                    && !$0.license.attribution.isEmpty
                    && $0.expectedDownloadBytes > 0
            }
        )
        guard case .files(let components) = ModelCatalog.parakeetFastDraft.source else {
            return XCTFail("Expected managed Parakeet component set")
        }
        XCTAssertEqual(components.count, 21)
        XCTAssertTrue(components.allSatisfy { $0.sha256.count == 64 })
    }

    func testMultiFilePackageInstallsAtomicallyAndDetectsTampering() async throws {
        let first = Data("first model file".utf8)
        let second = Data("second model file".utf8)
        let firstURL = URL(string: "https://example.invalid/first.bin")!
        let secondURL = URL(string: "https://example.invalid/second.bin")!
        let descriptor = ModelPackageDescriptor(
            id: "multi-model",
            displayName: "Multi Model",
            purpose: "Test",
            version: "1",
            minimumOSVersion: "14.0",
            license: ModelArtifactLicense(name: "MIT", attribution: "Test"),
            source: .files([
                component(path: "Model.mlmodelc/model.mil", url: firstURL, data: first),
                component(path: "Model.mlmodelc/weights/weight.bin", url: secondURL, data: second),
            ]),
            entryPointRelativePath: "Model.mlmodelc"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelPackageManager(
            directoryURL: directory,
            downloader: PackageStubDownloader(payloads: [firstURL: first, secondURL: second])
        )

        let installed = try await manager.install(descriptor) { _ in }

        XCTAssertEqual(
            try Data(contentsOf: installed.entryPointURL.appendingPathComponent("model.mil")), first
        )
        let installedStatus = await manager.status(for: descriptor)
        guard case .installed = installedStatus else {
            return XCTFail("Expected verified installed package, got \(installedStatus)")
        }

        try Data("tampered".utf8).write(
            to: installed.entryPointURL.appendingPathComponent("model.mil")
        )
        guard case .invalid = await manager.status(for: descriptor) else {
            return XCTFail("Expected tampered package to be invalid")
        }
    }

    func testZipPackageUsesExtractorBeforeAtomicPublication() async throws {
        let archive = Data("fake zip".utf8)
        let archiveURL = URL(string: "https://example.invalid/model.zip")!
        let descriptor = ModelPackageDescriptor(
            id: "zip-model",
            displayName: "ZIP Model",
            purpose: "Test",
            version: "1",
            minimumOSVersion: "14.0",
            license: ModelArtifactLicense(name: "MIT", attribution: "Test"),
            source: .zip(component(path: "model.zip", url: archiveURL, data: archive)),
            entryPointRelativePath: "Extracted.mlpackage"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ModelPackageManager(
            directoryURL: directory,
            downloader: PackageStubDownloader(payloads: [archiveURL: archive]),
            extractor: PackageStubExtractor()
        )

        let installed = try await manager.install(descriptor) { _ in }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.entryPointURL.appendingPathComponent("model.mil").path
            )
        )
        let installedStatus = await manager.status(for: descriptor)
        guard case .installed = installedStatus else {
            return XCTFail("Expected verified extracted package, got \(installedStatus)")
        }
    }

    private func component(
        path: String,
        url: URL,
        data: Data
    ) -> ModelPackageComponent {
        ModelPackageComponent(
            relativePath: path,
            downloadURL: url,
            expectedSizeBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}

private struct PackageStubDownloader: ModelArtifactDownloading {
    let payloads: [URL: Data]

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let data = payloads[sourceURL] else { throw PackageStubError.missingPayload }
        try data.write(to: destinationURL)
        progress(1)
    }
}

private struct PackageStubExtractor: ModelArchiveExtracting {
    func extract(zipURL: URL, to destinationDirectoryURL: URL) async throws {
        let output =
            destinationDirectoryURL
            .appendingPathComponent("Extracted.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("extracted model".utf8).write(to: output.appendingPathComponent("model.mil"))
    }
}

private enum PackageStubError: Error {
    case missingPayload
}
