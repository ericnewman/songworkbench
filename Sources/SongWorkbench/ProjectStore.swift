import Foundation

protocol ProjectStore: Sendable {
    func load() async throws -> ProjectLibraryDocument
    func save(_ document: ProjectLibraryDocument) async throws
}

actor JSONProjectStore: ProjectStore {
    static let standard = JSONProjectStore(fileURL: defaultFileURL)

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        migrateLegacyStoreIfNeeded(in: base)
        return
            base
            .appendingPathComponent("SongWorkbench", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    private static func migrateLegacyStoreIfNeeded(in base: URL) {
        let newDirectory = base.appendingPathComponent("SongWorkbench", isDirectory: true)
        let oldDirectory = base.appendingPathComponent("CCSSongWorkbench", isDirectory: true)
        guard
            !FileManager.default.fileExists(atPath: newDirectory.path),
            FileManager.default.fileExists(atPath: oldDirectory.path)
        else { return }
        try? FileManager.default.moveItem(at: oldDirectory, to: newDirectory)
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> ProjectLibraryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProjectLibraryDocument()
        }
        let document = try decoder.decode(
            ProjectLibraryDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard (1...ProjectLibraryDocument.currentVersion).contains(document.version) else {
            throw ProjectStoreError.unsupportedVersion(document.version)
        }
        return ProjectLibraryDocument(
            version: ProjectLibraryDocument.currentVersion, songs: document.songs)
    }

    func save(_ document: ProjectLibraryDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum ProjectStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported project library version: \(version)."
        }
    }
}
