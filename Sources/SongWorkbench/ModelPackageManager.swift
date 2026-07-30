import CryptoKit
import Foundation

struct ModelPackageComponent: Codable, Equatable, Sendable {
    let relativePath: String
    let downloadURL: URL
    let expectedSizeBytes: Int64
    let sha256: String
    /// When true, the downloaded file is a zip archive whose own top-level entry is
    /// `relativePath`'s last path component — it is extracted into the parent of
    /// `relativePath` rather than moved into place as a plain file. Lets a `.files`
    /// package mix plain files with an in-place-extracted companion (e.g. a ggml model
    /// next to its zipped Core ML encoder), unlike the whole-package `.zip` source.
    var isArchive: Bool = false
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
    /// When set, on iOS this package ships INSIDE the app bundle as `<name>.onnx` instead of
    /// being downloaded (the shorter-segment iPad stem model). Such a package counts as
    /// always-installed on iOS and is never offered for download. No effect on macOS.
    var bundledResourceNameiOS: String? = nil

    /// Whether this package is shipped in the app bundle on the RUNNING platform.
    var isBundledOnCurrentPlatform: Bool {
        #if os(macOS)
            return false
        #else
            return bundledResourceNameiOS != nil
        #endif
    }

    /// URL of the bundled model file on the current platform, if any.
    var bundledResourceURL: URL? {
        #if os(macOS)
            return nil
        #else
            guard let name = bundledResourceNameiOS else { return nil }
            return Bundle.main.url(forResource: name, withExtension: "onnx")
        #endif
    }

    var expectedDownloadBytes: Int64 {
        switch source {
        case .files(let components):
            components.reduce(0) { $0 + $1.expectedSizeBytes }
        case .zip(let archive):
            archive.expectedSizeBytes
        }
    }

    /// Whether any part of this package needs zip extraction to install. Extraction is
    /// macOS-only (`DittoModelArchiveExtractor` shells out to `/usr/bin/ditto`; the iOS
    /// branch throws `extractionUnsupportedOnPlatform`), so archive-bearing packages
    /// (Whisper's Core ML encoder) can't install on iPad and shouldn't be offered there.
    var requiresArchiveExtraction: Bool {
        switch source {
        case .files(let components): components.contains(where: \.isArchive)
        case .zip: true
        }
    }

    /// Whether this package can actually be installed on the RUNNING platform — the UI
    /// should hide (not just fail) packages that can't.
    var isInstallableOnCurrentPlatform: Bool {
        #if os(macOS)
            return true
        #else
            return !requiresArchiveExtraction
        #endif
    }

    /// Whether this package must be DOWNLOADED and installed on the running platform — i.e.
    /// installable here and not already shipped in the bundle. The first-run onboarding gate,
    /// the required-set check, and the Models popover all offer exactly these.
    var requiresDownloadOnCurrentPlatform: Bool {
        isInstallableOnCurrentPlatform && !isBundledOnCurrentPlatform
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
        #if os(macOS)
            // `Process` (NSTask) is macOS-only. On iPadOS this needs an in-process
            // unzip (e.g. Apple Archive / a small zip reader) — tracked in the iPad
            // port plan; model-zip installs are unavailable there until then.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, destinationDirectoryURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ModelPackageError.archiveExtractionFailed(process.terminationStatus)
            }
            try Task.checkCancellation()
        #else
            throw ModelPackageError.extractionUnsupportedOnPlatform
        #endif
    }
}

enum ModelPackageError: LocalizedError, Equatable {
    case invalidPath(String)
    case emptyPackage
    case archiveExtractionFailed(Int32)
    case extractionUnsupportedOnPlatform
    case archiveComponentMissing(String)
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
        case .extractionUnsupportedOnPlatform:
            "Model archive extraction isn\u{2019}t supported on this platform yet."
        case .archiveComponentMissing(let path):
            "Archive component did not produce the expected contents at \(path)."
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
    private var analysisStatusCache: [String: ModelPackageStatus] = [:]

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
                if component.isArchive {
                    let extractParentURL = destinationURL.deletingLastPathComponent()
                    try fileManager.createDirectory(
                        at: extractParentURL,
                        withIntermediateDirectories: true
                    )
                    try await extractor.extract(zipURL: downloadURL, to: extractParentURL)
                    guard fileManager.fileExists(atPath: destinationURL.path) else {
                        throw ModelPackageError.archiveComponentMissing(component.relativePath)
                    }
                } else {
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: downloadURL, to: destinationURL)
                }
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
        let installed = try installedPackage(
            for: descriptor,
            packageDirectoryURL: installedURL
        )
        analysisStatusCache[cacheKey(for: descriptor)] = .installed(installed)
        return installed
    }

    func status(for descriptor: ModelPackageDescriptor) -> ModelPackageStatus {
        let resolvedStatus: ModelPackageStatus
        do {
            try validate(descriptor)
            let packageURL = installedDirectoryURL(for: descriptor)
            if fileManager.fileExists(atPath: packageURL.path) {
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
                resolvedStatus = .installed(
                    try installedPackage(for: descriptor, packageDirectoryURL: packageURL))
            } else {
                resolvedStatus = .available
            }
        } catch {
            resolvedStatus = .invalid(reason: error.localizedDescription)
        }
        analysisStatusCache[cacheKey(for: descriptor)] = resolvedStatus
        return resolvedStatus
    }

    /// Returns the package status most recently established by a full integrity
    /// verification. Pipeline assembly calls this repeatedly (including once per
    /// Lyric Blend mode), so re-hashing hundreds of megabytes here would dominate
    /// every run. Startup/status refresh still calls `status(for:)` and therefore
    /// performs the complete manifest verification at least once per process.
    func statusForAnalysis(for descriptor: ModelPackageDescriptor) -> ModelPackageStatus {
        if let cached = analysisStatusCache[cacheKey(for: descriptor)] {
            return cached
        }
        return status(for: descriptor)
    }

    func remove(_ descriptor: ModelPackageDescriptor) throws {
        try validate(descriptor)
        let packageURL = installedDirectoryURL(for: descriptor)
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        analysisStatusCache[cacheKey(for: descriptor)] = .available
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

    private func cacheKey(for descriptor: ModelPackageDescriptor) -> String {
        "\(descriptor.id)|\(descriptor.version)"
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
