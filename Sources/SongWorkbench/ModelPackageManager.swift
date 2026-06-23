import CryptoKit
import Foundation

struct ModelPackageComponent: Codable, Equatable, Sendable {
    let relativePath: String
    let downloadURL: URL
    let expectedSizeBytes: Int64
    let sha256: String
}

enum ModelPackageSource: Codable, Equatable, Sendable {
    case files([ModelPackageComponent])
    case zip(ModelPackageComponent)
}

struct ModelPackageDescriptor: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let purpose: String
    let version: String
    let minimumOSVersion: String
    let license: ModelArtifactLicense
    let source: ModelPackageSource
    let entryPointRelativePath: String

    var expectedDownloadBytes: Int64 {
        switch source {
        case .files(let components):
            components.reduce(0) { $0 + $1.expectedSizeBytes }
        case .zip(let archive):
            archive.expectedSizeBytes
        }
    }
}

struct InstalledModelPackage: Equatable, Sendable {
    let descriptorID: String
    let version: String
    let packageDirectoryURL: URL
    let entryPointURL: URL
    let sizeBytes: Int64
}

enum ModelPackageStatus: Equatable, Sendable {
    case available
    case installed(InstalledModelPackage)
    case invalid(reason: String)
}

protocol ModelArchiveExtracting: Sendable {
    func extract(zipURL: URL, to destinationDirectoryURL: URL) async throws
}

struct DittoModelArchiveExtractor: ModelArchiveExtracting {
    func extract(zipURL: URL, to destinationDirectoryURL: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destinationDirectoryURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelPackageError.archiveExtractionFailed(process.terminationStatus)
        }
        try Task.checkCancellation()
    }
}

enum ModelPackageError: LocalizedError, Equatable {
    case invalidPath(String)
    case emptyPackage
    case archiveExtractionFailed(Int32)
    case missingEntryPoint(String)
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            "Invalid model package path: \(path)"
        case .emptyPackage:
            "The model package contains no files."
        case .archiveExtractionFailed(let status):
            "Model archive extraction failed with status \(status)."
        case .missingEntryPoint(let path):
            "The installed model entry point is missing: \(path)"
        case .invalidManifest:
            "The installed model package failed integrity verification."
        }
    }
}

actor ModelPackageManager {
    private struct Manifest: Codable {
        let files: [ManifestFile]
    }

    private struct ManifestFile: Codable {
        let relativePath: String
        let sizeBytes: Int64
        let sha256: String
    }

    private static let manifestFileName = ".installation-manifest.json"

    private let directoryURL: URL
    private let downloader: any ModelArtifactDownloading
    private let extractor: any ModelArchiveExtracting
    private let fileManager: FileManager

    init(
        directoryURL: URL,
        downloader: any ModelArtifactDownloading,
        extractor: any ModelArchiveExtracting = DittoModelArchiveExtractor(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.downloader = downloader
        self.extractor = extractor
        self.fileManager = fileManager
    }

    func install(
        _ descriptor: ModelPackageDescriptor,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledModelPackage {
        try validate(descriptor)
        if case .installed(let installed) = status(for: descriptor) {
            progress(1)
            return installed
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stagingURL = directoryURL.appendingPathComponent(
            ".package-\(UUID().uuidString)",
            isDirectory: true
        )
        let downloadURL = directoryURL.appendingPathComponent(
            ".download-\(UUID().uuidString)",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: downloadURL)
        }
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        switch descriptor.source {
        case .files(let components):
            let totalBytes = max(descriptor.expectedDownloadBytes, 1)
            var completedBytes: Int64 = 0
            for component in components {
                try Task.checkCancellation()
                let completedBeforeDownload = completedBytes
                try await downloadAndVerify(component, to: downloadURL) { fraction in
                    progress(
                        min(
                            max(
                                (Double(completedBeforeDownload)
                                    + fraction * Double(component.expectedSizeBytes))
                                    / Double(totalBytes),
                                0
                            ),
                            0.95
                        ))
                }
                let destinationURL = stagingURL.appendingPathComponent(component.relativePath)
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: downloadURL, to: destinationURL)
                completedBytes += component.expectedSizeBytes
            }
        case .zip(let archive):
            try await downloadAndVerify(archive, to: downloadURL) { fraction in
                progress(fraction * 0.8)
            }
            try await extractor.extract(zipURL: downloadURL, to: stagingURL)
            progress(0.9)
        }

        try requireEntryPoint(for: descriptor, packageDirectoryURL: stagingURL)
        let manifest = try makeManifest(in: stagingURL)
        guard !manifest.files.isEmpty else { throw ModelPackageError.emptyPackage }
        try JSONEncoder().encode(manifest).write(
            to: stagingURL.appendingPathComponent(Self.manifestFileName),
            options: .atomic
        )

        let parentURL = directoryURL.appendingPathComponent(descriptor.id, isDirectory: true)
        let installedURL = parentURL.appendingPathComponent(descriptor.version, isDirectory: true)
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installedURL.path) {
            try fileManager.removeItem(at: installedURL)
        }
        try fileManager.moveItem(at: stagingURL, to: installedURL)
        progress(1)
        return try installedPackage(for: descriptor, packageDirectoryURL: installedURL)
    }

    func status(for descriptor: ModelPackageDescriptor) -> ModelPackageStatus {
        do {
            try validate(descriptor)
            let packageURL = installedDirectoryURL(for: descriptor)
            guard fileManager.fileExists(atPath: packageURL.path) else { return .available }
            try requireEntryPoint(for: descriptor, packageDirectoryURL: packageURL)
            let manifestURL = packageURL.appendingPathComponent(Self.manifestFileName)
            let manifest = try JSONDecoder().decode(
                Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
            for file in manifest.files {
                let url = packageURL.appendingPathComponent(file.relativePath)
                guard
                    try fileSize(at: url) == file.sizeBytes,
                    try sha256(of: url).caseInsensitiveCompare(file.sha256) == .orderedSame
                else {
                    throw ModelPackageError.invalidManifest
                }
            }
            return .installed(
                try installedPackage(for: descriptor, packageDirectoryURL: packageURL))
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
    }

    func remove(_ descriptor: ModelPackageDescriptor) throws {
        try validate(descriptor)
        let packageURL = installedDirectoryURL(for: descriptor)
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
    }

    private func downloadAndVerify(
        _ component: ModelPackageComponent,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? fileManager.removeItem(at: destinationURL)
        try await downloader.download(
            from: component.downloadURL,
            to: destinationURL,
            progress: progress
        )
        let actualSize = try fileSize(at: destinationURL)
        guard actualSize == component.expectedSizeBytes else {
            throw ModelArtifactError.invalidExpectedSize(
                expected: component.expectedSizeBytes,
                actual: actualSize
            )
        }
        let actualDigest = try sha256(of: destinationURL)
        guard actualDigest.caseInsensitiveCompare(component.sha256) == .orderedSame else {
            throw ModelArtifactError.invalidDigest(
                expected: component.sha256,
                actual: actualDigest
            )
        }
    }

    private func validate(_ descriptor: ModelPackageDescriptor) throws {
        for component in [descriptor.id, descriptor.version] {
            guard isSafePathComponent(component) else {
                throw ModelPackageError.invalidPath(component)
            }
        }
        if !descriptor.entryPointRelativePath.isEmpty {
            try validateRelativePath(descriptor.entryPointRelativePath)
        }
        let components: [ModelPackageComponent]
        switch descriptor.source {
        case .files(let files): components = files
        case .zip(let archive): components = [archive]
        }
        guard !components.isEmpty else { throw ModelPackageError.emptyPackage }
        for component in components {
            try validateRelativePath(component.relativePath)
            guard component.expectedSizeBytes > 0, component.sha256.count == 64 else {
                throw ModelPackageError.invalidPath(component.relativePath)
            }
        }
    }

    private func validateRelativePath(_ path: String) throws {
        let components = NSString(string: path).pathComponents
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !components.contains(".."),
            !components.contains("."),
            !components.contains("")
        else {
            throw ModelPackageError.invalidPath(path)
        }
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains(":")
    }

    private func requireEntryPoint(
        for descriptor: ModelPackageDescriptor,
        packageDirectoryURL: URL
    ) throws {
        let entryPointURL = entryPointURL(
            for: descriptor,
            packageDirectoryURL: packageDirectoryURL
        )
        guard fileManager.fileExists(atPath: entryPointURL.path) else {
            throw ModelPackageError.missingEntryPoint(descriptor.entryPointRelativePath)
        }
    }

    private func installedPackage(
        for descriptor: ModelPackageDescriptor,
        packageDirectoryURL: URL
    ) throws -> InstalledModelPackage {
        InstalledModelPackage(
            descriptorID: descriptor.id,
            version: descriptor.version,
            packageDirectoryURL: packageDirectoryURL,
            entryPointURL: entryPointURL(
                for: descriptor,
                packageDirectoryURL: packageDirectoryURL
            ),
            sizeBytes: try directorySize(at: packageDirectoryURL)
        )
    }

    private func installedDirectoryURL(for descriptor: ModelPackageDescriptor) -> URL {
        directoryURL
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent(descriptor.version, isDirectory: true)
    }

    private func entryPointURL(
        for descriptor: ModelPackageDescriptor,
        packageDirectoryURL: URL
    ) -> URL {
        descriptor.entryPointRelativePath.isEmpty
            ? packageDirectoryURL
            : packageDirectoryURL.appendingPathComponent(descriptor.entryPointRelativePath)
    }

    private func makeManifest(in directoryURL: URL) throws -> Manifest {
        guard
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { throw ModelPackageError.emptyPackage }
        let resolvedDirectoryPath = directoryURL.resolvingSymlinksInPath().path
        var files: [ManifestFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let resolvedFilePath = url.resolvingSymlinksInPath().path
            guard resolvedFilePath.hasPrefix(resolvedDirectoryPath + "/") else {
                throw ModelPackageError.invalidPath(resolvedFilePath)
            }
            let relativePath = String(
                resolvedFilePath.dropFirst(resolvedDirectoryPath.count + 1)
            )
            files.append(
                ManifestFile(
                    relativePath: relativePath,
                    sizeBytes: try fileSize(at: url),
                    sha256: try sha256(of: url)
                ))
        }
        return Manifest(files: files.sorted { $0.relativePath < $1.relativePath })
    }

    private func directorySize(at directoryURL: URL) throws -> Int64 {
        guard
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
