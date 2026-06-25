import Foundation

struct Song: Identifiable, Hashable, Sendable {
    let url: URL

    var id: URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
}

enum SongImportPolicy {
    static let supportedExtensions: Set<String> = [
        "aif", "aiff", "flac", "m4a", "mp3", "wav",
    ]

    static func accepts(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Expands any directories in `urls` into the supported audio files they contain
    /// (recursively, skipping hidden files), and passes non-directory URLs through. Lets a
    /// drop of files and/or folders be bulk-imported.
    static func expandingDirectories(_ urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = manager.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let file = enumerator?.nextObject() as? URL {
                    if accepts(file) { result.append(file) }
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    static func songs(from urls: [URL]) -> [Song] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard accepts(normalized), seen.insert(normalized).inserted else {
                return nil
            }
            return Song(url: normalized)
        }
    }
}
