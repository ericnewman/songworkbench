import Foundation

struct LoopRegion: Codable, Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval

    func clamped(to duration: TimeInterval) -> LoopRegion? {
        let lower = min(max(start, 0), duration)
        let upper = min(max(end, 0), duration)
        guard upper - lower >= 0.1 else { return nil }
        return LoopRegion(start: lower, end: upper)
    }
}

struct PracticeSettings: Codable, Equatable, Sendable {
    var pitchSemitones = 0
    var tempoRate = 1.0
    var loopRegion: LoopRegion?

    mutating func normalize() {
        pitchSemitones = PitchShift.normalized(pitchSemitones)
        tempoRate = min(max(tempoRate, 0.5), 1.5)
    }
}

struct StoredSongProject: Codable, Equatable, Sendable {
    let sourcePath: String
    let bookmarkData: Data?
    var settings: PracticeSettings
    var analysis: SongAnalysisDocument?
    var lastOpenedAt: Date?

    init(
        url: URL,
        settings: PracticeSettings,
        analysis: SongAnalysisDocument? = nil,
        lastOpenedAt: Date? = nil
    ) {
        sourcePath = url.path
        bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        self.settings = settings
        self.analysis = analysis
        self.lastOpenedAt = lastOpenedAt
    }

    func resolvedURL() -> URL {
        resolvedURLWithStaleness().url
    }

    func resolvedURLWithStaleness() -> (url: URL, isStale: Bool) {
        guard let bookmarkData else {
            return (URL(fileURLWithPath: sourcePath), false)
        }

        var isStale = false
        let url =
            (try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )) ?? URL(fileURLWithPath: sourcePath)
        return (url, isStale)
    }
}

struct ProjectLibraryDocument: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version = currentVersion
    var songs: [StoredSongProject] = []
}
