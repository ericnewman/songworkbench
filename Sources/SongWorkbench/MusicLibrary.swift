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
    /// iOS only: the item exists in the on-device Music library but iOS does not
    /// expose a local file URL for it, so it can't enter the file-copy import
    /// pipeline. See `MediaPlayerMusicLibrary`.
    case platformUnavailable

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
        guard let location, location.isFileURL else {
            // On iOS, Music-library items never carry a file URL (see
            // `MediaPlayerMusicLibrary`); on macOS a non-file/nil location means a
            // cloud track that isn't downloaded locally.
            #if os(iOS)
                return .platformUnavailable
            #else
                return .notDownloaded
            #endif
        }
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
        case .platformUnavailable:
            return
                "On iPad, tracks in your Music library can't be analyzed directly — iOS doesn't expose their audio files. Import the audio through the Files app instead."
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

#if os(iOS) && canImport(MediaPlayer)
    import MediaPlayer

    enum MusicLibraryAccessError: LocalizedError {
        case notAuthorized
        var errorDescription: String? {
            "Music library access is off. Enable it in Settings › Privacy › Media & Apple Music."
        }
    }

    /// iOS provider backed by `MPMediaQuery`. It enumerates the on-device Music
    /// library so the picker is populated instead of empty.
    ///
    /// Honest limitation: iOS does NOT hand out a local file URL for library
    /// tracks. `MPMediaItem.assetURL` is an `ipod-library://` URL that is only
    /// readable through AVFoundation (an async export), never the file-copy import
    /// path this app uses. So every item is reported with `location: nil` and
    /// classifies as `.platformUnavailable` — browsable, but not analyzable
    /// directly. DRM tracks are still flagged via `hasProtectedAsset`.
    ///
    /// The read relies on the system Media-library prompt that `MPMediaQuery`
    /// presents when `NSAppleMusicUsageDescription` is set (mirrors how the macOS
    /// provider relies on `ITLibrary` triggering TCC); we throw only on an explicit
    /// prior denial. ponytail: no manual requestAuthorization dance until a build
    /// shows the auto-prompt isn't firing.
    struct MediaPlayerMusicLibrary: MusicLibraryProviding {
        func fetchSongs() throws -> [MusicLibraryItem] {
            switch MPMediaLibrary.authorizationStatus() {
            case .denied, .restricted:
                throw MusicLibraryAccessError.notAuthorized
            default:
                break
            }
            return (MPMediaQuery.songs().items ?? [])
                .map { item in
                    MusicLibraryItem(
                        id: String(item.persistentID, radix: 16),
                        title: item.title ?? "",
                        artist: item.artist ?? "",
                        album: item.albumTitle ?? "",
                        location: nil,
                        isProtected: item.hasProtectedAsset
                    )
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
#endif

/// Fallback used only where no platform library provider is available.
struct EmptyMusicLibrary: MusicLibraryProviding {
    func fetchSongs() throws -> [MusicLibraryItem] { [] }
}

enum DefaultMusicLibrary {
    static func make() -> any MusicLibraryProviding {
        #if canImport(iTunesLibrary)
            ITunesMusicLibrary()
        #elseif os(iOS) && canImport(MediaPlayer)
            MediaPlayerMusicLibrary()
        #else
            EmptyMusicLibrary()
        #endif
    }
}
