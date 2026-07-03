import CryptoKit
import Foundation

/// `ProjectStore` that persists ONE FILE PER SONG under `songs/<stableID>.json`, plus a small
/// `library.json` manifest holding the song order. Same Codable value types as the legacy
/// whole-library `projects.json` — this is a storage-layout change, not a schema change.
///
/// Why: the legacy store rewrote the entire library on every edit (`makeDocument` → atomic write
/// of all songs). Here, `save` receives the whole document but diffs it against disk and rewrites
/// only the song files whose bytes actually changed, plus the index when the order changes. So an
/// edit to one song touches one file, not O(library).
///
/// ponytail: diff-on-save keeps the existing whole-document `ProjectStore` protocol unchanged, so
/// `AppModel` wiring is untouched. A per-song `save(one:)` API would be leaner on paper but would
/// ripple through AppModel for no real gain — reading small JSON to byte-compare is far cheaper
/// than re-encoding + atomically rewriting the whole library.
actor SplitProjectStore: ProjectStore {
    static let standard = SplitProjectStore(directoryURL: defaultDirectoryURL)

    private static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let newDirectory = base.appendingPathComponent("SongWorkbench", isDirectory: true)
        let oldDirectory = base.appendingPathComponent("CCSSongWorkbench", isDirectory: true)
        if !FileManager.default.fileExists(atPath: newDirectory.path),
            FileManager.default.fileExists(atPath: oldDirectory.path)
        {
            try? FileManager.default.moveItem(at: oldDirectory, to: newDirectory)
        }
        return newDirectory
    }

    private let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    private var songsDirectory: URL {
        directoryURL.appendingPathComponent("songs", isDirectory: true)
    }
    private var indexURL: URL {
        directoryURL.appendingPathComponent("library.json")
    }
    private var legacyURL: URL {
        directoryURL.appendingPathComponent("projects.json")
    }

    // MARK: Load

    func load() throws -> ProjectLibraryDocument {
        let manager = FileManager.default
        // Best-effort one-time import of a legacy whole-library file. No round-trip proof: the
        // existing transcriptions are disposable, so a clean start on a corrupt file is acceptable.
        // We never destroy the legacy file — it's renamed aside as a backup.
        if !manager.fileExists(atPath: indexURL.path),
            manager.fileExists(atPath: legacyURL.path)
        {
            importLegacyBestEffort()
        }

        guard manager.fileExists(atPath: indexURL.path) else {
            return ProjectLibraryDocument()
        }

        let index = try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: indexURL))
        guard (1...ProjectLibraryDocument.currentVersion).contains(index.version) else {
            throw ProjectStoreError.unsupportedVersion(index.version)
        }
        let decoder = JSONDecoder()
        let songs = index.songs.compactMap { id -> StoredSongProject? in
            let url = songsDirectory.appendingPathComponent("\(id).json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(StoredSongProject.self, from: data)
        }
        return ProjectLibraryDocument(version: ProjectLibraryDocument.currentVersion, songs: songs)
    }

    private func importLegacyBestEffort() {
        guard
            let data = try? Data(contentsOf: legacyURL),
            let document = try? JSONDecoder().decode(ProjectLibraryDocument.self, from: data)
        else {
            // Undecodable legacy file: start clean, but keep the file aside rather than re-reading.
            try? FileManager.default.moveItem(
                at: legacyURL,
                to: directoryURL.appendingPathComponent("projects.json.premigration-backup"))
            return
        }
        try? writeDocument(document)
        try? FileManager.default.moveItem(
            at: legacyURL,
            to: directoryURL.appendingPathComponent("projects.json.premigration-backup"))
    }

    // MARK: Save

    func save(_ document: ProjectLibraryDocument) throws {
        try writeDocument(document)
    }

    /// Nonisolated so it can run synchronously from a termination handler. Uses only the immutable
    /// `directoryURL` plus local encoders, so it's safe outside the actor.
    nonisolated func saveBlocking(_ document: ProjectLibraryDocument) throws {
        try writeDocument(document)
    }

    private nonisolated func writeDocument(_ document: ProjectLibraryDocument) throws {
        let manager = FileManager.default
        let songsDir = directoryURL.appendingPathComponent("songs", isDirectory: true)
        try manager.createDirectory(at: songsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // ponytail: last-writer-wins on duplicate ids (same sourcePath). AppModel dedups songs by
        // standardized URL, so duplicates don't occur in practice.
        var order: [String] = []
        var keep = Set<String>()
        for song in document.songs {
            let id = Self.stableID(for: song.sourcePath)
            order.append(id)
            keep.insert(id)
            let fileURL = songsDir.appendingPathComponent("\(id).json")
            let data = try encoder.encode(song)
            // Skip identical files so an unchanged song's mtime/bytes stay put — this is what makes
            // a one-song edit touch exactly one file.
            if let existing = try? Data(contentsOf: fileURL), existing == data { continue }
            try data.write(to: fileURL, options: .atomic)
        }

        // Remove files for songs no longer in the library.
        if let existing = try? manager.contentsOfDirectory(
            at: songsDir, includingPropertiesForKeys: nil)
        {
            for url in existing where url.pathExtension == "json" {
                let id = url.deletingPathExtension().lastPathComponent
                if !keep.contains(id) { try? manager.removeItem(at: url) }
            }
        }

        // Write the index only when it actually changed (order add/remove/reorder).
        let indexURL = directoryURL.appendingPathComponent("library.json")
        let indexData = try encoder.encode(
            LibraryIndex(version: ProjectLibraryDocument.currentVersion, songs: order))
        if let existing = try? Data(contentsOf: indexURL), existing == indexData { return }
        try indexData.write(to: indexURL, options: .atomic)
    }

    /// Stable, filesystem-safe per-song identifier: SHA-256 of the source path.
    private static func stableID(for sourcePath: String) -> String {
        SHA256.hash(data: Data(sourcePath.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Ordered manifest of the split store. Content lives in per-song files; this just fixes order.
private struct LibraryIndex: Codable {
    var version: Int
    var songs: [String]
}
