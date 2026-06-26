import Foundation

/// A song discovered in the macOS Music app library via the iTunesLibrary
/// framework. `location` is the track's local file URL when one exists; it is
/// nil for cloud-only / not-downloaded tracks. `isProtected` marks Apple Music
/// / FairPlay DRM assets, which the OS forbids decoding, analyzing, or exporting.
struct MusicLibraryItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let location: URL?
    let isProtected: Bool

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// Whether a library item can be handed to the local-file analysis pipeline.
/// Only `.openable` tracks ever reach the decoder; everything else is a friendly
/// dead end surfaced to the user.
enum MusicLibraryItemOpenability: Equatable, Sendable {
    case openable(URL)
    case drmProtected
    case notDownloaded
    case missingFile
    case unsupportedFormat

    var canOpen: Bool {
        if case .openable = self { return true }
        return false
    }
}

extension MusicLibraryItem {
    /// Classifies the item using only OS-provided signals plus a filesystem
    /// existence check, so DRM/cloud tracks never reach the decoder. The
    /// `fileExists` seam keeps the rule unit-testable without a real library.
    func openability(
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> MusicLibraryItemOpenability {
        if isProtected { return .drmProtected }
        guard let location, location.isFileURL else { return .notDownloaded }
        guard fileExists(location) else { return .missingFile }
        guard SongImportPolicy.accepts(location) else { return .unsupportedFormat }
        return .openable(location)
    }

    /// A friendly explanation shown when the track cannot be analyzed, or nil
    /// when it is openable.
    var unopenableReason: String? {
        switch openability() {
        case .openable:
            return nil
        case .drmProtected:
            return "Protected by Apple Music DRM — only DRM-free local files can be analyzed."
        case .notDownloaded:
            return "Not downloaded locally (Apple Music / iCloud). Download it in Music first."
        case .missingFile:
            return "The track's file is no longer on disk."
        case .unsupportedFormat:
            return "This audio format isn't supported."
        }
    }
}

/// Reads the macOS Music app library. Behind a protocol so the UI/model layer
/// is testable with a fake and the iTunesLibrary dependency stays at the edge.
protocol MusicLibraryProviding: Sendable {
    func fetchSongs() throws -> [MusicLibraryItem]
}

#if canImport(iTunesLibrary)
    import iTunesLibrary

    /// Concrete provider backed by `ITLibrary`. Constructing `ITLibrary` triggers
    /// the macOS "Media & Apple Music" (TCC) authorization prompt gated by
    /// `NSAppleMusicUsageDescription`; it is created lazily inside `fetchSongs()` so
    /// no prompt appears until the user opens the picker.
    struct ITunesMusicLibrary: MusicLibraryProviding {
        func fetchSongs() throws -> [MusicLibraryItem] {
            let library = try ITLibrary(apiVersion: "1.1")
            return
                library.allMediaItems
                .filter { $0.mediaKind == .kindSong }
                .map { item in
                    MusicLibraryItem(
                        id: String(item.persistentID.uint64Value, radix: 16),
                        title: item.title,
                        artist: item.artist?.name ?? "",
                        album: item.album.title ?? "",
                        location: item.location,
                        isProtected: Self.isProtected(item)
                    )
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        /// FairPlay/DRM detection that compiles against the public `ITLibMediaItem`
        /// header: protected purchases are `.m4p`, and protected items report a
        /// "Protected" file `kind` string (e.g. "Protected AAC audio file").
        private static func isProtected(_ item: ITLibMediaItem) -> Bool {
            if item.location?.pathExtension.lowercased() == "m4p" { return true }
            if let kind = item.kind, kind.localizedCaseInsensitiveContains("protected") {
                return true
            }
            return false
        }
    }
#endif

/// Fallback used only where iTunesLibrary is unavailable (non-macOS toolchains).
struct EmptyMusicLibrary: MusicLibraryProviding {
    func fetchSongs() throws -> [MusicLibraryItem] { [] }
}

enum DefaultMusicLibrary {
    static func make() -> any MusicLibraryProviding {
        #if canImport(iTunesLibrary)
            ITunesMusicLibrary()
        #else
            EmptyMusicLibrary()
        #endif
    }
}
