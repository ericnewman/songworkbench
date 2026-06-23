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
