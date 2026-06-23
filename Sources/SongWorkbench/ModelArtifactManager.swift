import CryptoKit
import Foundation

struct ModelArtifactLicense: Codable, Equatable, Sendable {
    let name: String
    let attribution: String
}

struct ModelArtifactDescriptor: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let downloadURL: URL
    let expectedSizeBytes: Int64
    let sha256: String
    let license: ModelArtifactLicense
    let installedFileName: String
}

struct InstalledModelArtifact: Equatable, Sendable {
    let descriptorID: String
    let version: String
    let fileURL: URL
    let sizeBytes: Int64
}

struct ModelStorageUsage: Equatable, Sendable {
    let totalBytes: Int64
    let bytesByDescriptorID: [String: Int64]
}

enum ModelArtifactStatus: Equatable, Sendable {
    case available
    case installed(fileURL: URL, sizeBytes: Int64)
    case invalid(reason: String)
}

protocol ModelArtifactDownloading: Sendable {
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

struct URLSessionModelArtifactDownloader: ModelArtifactDownloading {
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = ModelDownloadDelegate(
            destinationURL: destinationURL,
            progress: progress
        )
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await delegate.download(from: sourceURL, using: session)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let destinationURL: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completionError: Error?

    init(
        destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.destinationURL = destinationURL
        self.progress = progress
    }

    func download(from sourceURL: URL, using session: URLSession) async throws {
        progress(0)
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            session.downloadTask(with: sourceURL).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(
            min(
                max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0),
                1
            ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode)
            else {
                throw ModelArtifactDownloadError.invalidResponse
            }
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            lock.withLock { completionError = error }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let result: Result<Void, Error> = lock.withLock {
            let finalError = error ?? completionError
            return finalError.map(Result.failure) ?? .success(())
        }
        if case .success = result { progress(1) }
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

enum ModelArtifactDownloadError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The model server returned an invalid download response."
    }
}

enum ModelArtifactError: Error, Equatable, LocalizedError {
    case invalidPathComponent(String)
    case invalidExpectedSize(expected: Int64, actual: Int64)
    case invalidDigest(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidPathComponent(let component):
            "Invalid model artifact path component: \(component)"
        case .invalidExpectedSize(let expected, let actual):
            "Model artifact size mismatch: expected \(expected) bytes, found \(actual)."
        case .invalidDigest(let expected, let actual):
            "Model artifact checksum mismatch: expected \(expected), found \(actual)."
        }
    }
}

actor ModelArtifactManager {
    private let directoryURL: URL
    private let downloader: any ModelArtifactDownloading
    private let fileManager: FileManager

    init(
        directoryURL: URL,
        downloader: any ModelArtifactDownloading,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.downloader = downloader
        self.fileManager = fileManager
    }

    func install(
        _ descriptor: ModelArtifactDescriptor,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledModelArtifact {
        try validatePathComponents(of: descriptor)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        if case .installed(let fileURL, let sizeBytes) = status(for: descriptor) {
            progress(1)
            return InstalledModelArtifact(
                descriptorID: descriptor.id,
                version: descriptor.version,
                fileURL: fileURL,
                sizeBytes: sizeBytes
            )
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".download-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try await downloader.download(
            from: descriptor.downloadURL,
            to: temporaryURL,
            progress: progress
        )
        let sizeBytes = try fileSize(at: temporaryURL)
        guard sizeBytes == descriptor.expectedSizeBytes else {
            throw ModelArtifactError.invalidExpectedSize(
                expected: descriptor.expectedSizeBytes,
                actual: sizeBytes
            )
        }
        let digest = try sha256(of: temporaryURL)
        guard digest.caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
            throw ModelArtifactError.invalidDigest(expected: descriptor.sha256, actual: digest)
        }

        let parentURL =
            directoryURL
            .appendingPathComponent(descriptor.id, isDirectory: true)
        let installedDirectoryURL =
            parentURL
            .appendingPathComponent(descriptor.version, isDirectory: true)
        let stagingDirectoryURL = directoryURL.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectoryURL) }

        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )
        let stagedFileURL =
            stagingDirectoryURL
            .appendingPathComponent(descriptor.installedFileName, isDirectory: false)
        try fileManager.moveItem(at: temporaryURL, to: stagedFileURL)
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installedDirectoryURL.path) {
            try fileManager.removeItem(at: installedDirectoryURL)
        }
        try fileManager.moveItem(at: stagingDirectoryURL, to: installedDirectoryURL)

        let installedFileURL =
            installedDirectoryURL
            .appendingPathComponent(descriptor.installedFileName, isDirectory: false)
        progress(1)
        return InstalledModelArtifact(
            descriptorID: descriptor.id,
            version: descriptor.version,
            fileURL: installedFileURL,
            sizeBytes: sizeBytes
        )
    }

    func status(for descriptor: ModelArtifactDescriptor) -> ModelArtifactStatus {
        do {
            try validatePathComponents(of: descriptor)
            let fileURL = installedFileURL(for: descriptor)
            guard fileManager.fileExists(atPath: fileURL.path) else { return .available }
            let sizeBytes = try fileSize(at: fileURL)
            guard sizeBytes == descriptor.expectedSizeBytes else {
                return .invalid(
                    reason: ModelArtifactError.invalidExpectedSize(
                        expected: descriptor.expectedSizeBytes,
                        actual: sizeBytes
                    ).localizedDescription
                )
            }
            let digest = try sha256(of: fileURL)
            guard digest.caseInsensitiveCompare(descriptor.sha256) == .orderedSame else {
                return .invalid(
                    reason: ModelArtifactError.invalidDigest(
                        expected: descriptor.sha256,
                        actual: digest
                    ).localizedDescription
                )
            }
            return .installed(fileURL: fileURL, sizeBytes: sizeBytes)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
    }

    func remove(_ descriptor: ModelArtifactDescriptor) throws {
        try validatePathComponents(of: descriptor)
        let versionDirectoryURL =
            directoryURL
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent(descriptor.version, isDirectory: true)
        if fileManager.fileExists(atPath: versionDirectoryURL.path) {
            try fileManager.removeItem(at: versionDirectoryURL)
        }

        let modelDirectoryURL = versionDirectoryURL.deletingLastPathComponent()
        let remaining = try? fileManager.contentsOfDirectory(
            at: modelDirectoryURL,
            includingPropertiesForKeys: nil
        )
        if remaining?.isEmpty == true {
            try fileManager.removeItem(at: modelDirectoryURL)
        }
    }

    func storageUsage(for descriptors: [ModelArtifactDescriptor]) -> ModelStorageUsage {
        var bytesByDescriptorID: [String: Int64] = [:]
        for descriptor in descriptors {
            if case .installed(_, let sizeBytes) = status(for: descriptor) {
                bytesByDescriptorID[descriptor.id] = sizeBytes
            }
        }
        return ModelStorageUsage(
            totalBytes: bytesByDescriptorID.values.reduce(0, +),
            bytesByDescriptorID: bytesByDescriptorID
        )
    }

    private func installedFileURL(for descriptor: ModelArtifactDescriptor) -> URL {
        directoryURL
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent(descriptor.version, isDirectory: true)
            .appendingPathComponent(descriptor.installedFileName, isDirectory: false)
    }

    private func validatePathComponents(of descriptor: ModelArtifactDescriptor) throws {
        for component in [descriptor.id, descriptor.version, descriptor.installedFileName] {
            guard
                !component.isEmpty,
                component != ".",
                component != "..",
                !component.contains("/"),
                !component.contains(":")
            else {
                throw ModelArtifactError.invalidPathComponent(component)
            }
        }
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
