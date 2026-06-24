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
    /// Chord-chart transposition in semitones (shared by the ChordPro-style
    /// screens). Independent of audio pitch.
    var chordProTranspose = 0

    mutating func normalize() {
        pitchSemitones = PitchShift.normalized(pitchSemitones)
        tempoRate = min(max(tempoRate, 0.5), 1.5)
        chordProTranspose = min(max(chordProTranspose, -12), 12)
    }
}

extension PracticeSettings {
    // Custom decoding so projects saved before `chordProTranspose` existed still
    // load (the field defaults to 0). The memberwise/Encodable members stay
    // synthesized because this initializer lives in an extension.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pitchSemitones = try container.decodeIfPresent(Int.self, forKey: .pitchSemitones) ?? 0
        tempoRate = try container.decodeIfPresent(Double.self, forKey: .tempoRate) ?? 1.0
        loopRegion = try container.decodeIfPresent(LoopRegion.self, forKey: .loopRegion)
        chordProTranspose =
            try container.decodeIfPresent(Int.self, forKey: .chordProTranspose) ?? 0
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
