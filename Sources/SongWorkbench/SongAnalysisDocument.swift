import Foundation

struct TimedLyricSegment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct EditableChordEvent: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var time: TimeInterval
    var chord: String
    var confidence: Float?
}

enum AnalysisReviewState: String, Codable, Equatable, Sendable {
    case draft
    case reviewed
}

enum SongAnalysisStage: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case separation
    case transcription
    case harmony
    case chordPro
}

enum AnalysisStageState: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case stale
}

enum AnalysisSourceKind: String, Codable, Equatable, Sendable {
    case recording
    case vocalsStem
    case stemSet
    case accompanimentStem
}

struct AnalysisProvenance: Codable, Equatable, Sendable {
    var sourceDigest: String
    var sourceKind: AnalysisSourceKind
    var engineIdentifier: String
    var engineVersion: String
    var modelIdentifier: String?
    var modelVersion: String?
    var configurationIdentifier: String
    var resultSchemaVersion: Int
    var completedAt: Date
    var loadedFromCache: Bool
}

struct AnalysisConfidenceSummary: Codable, Equatable, Sendable {
    var average: Float?
    var lowConfidenceCount: Int
    var totalCount: Int
}

struct AnalysisStageRecord: Codable, Equatable, Sendable {
    var state: AnalysisStageState
    var provenance: AnalysisProvenance?
    var confidence: AnalysisConfidenceSummary?
    var errorMessage: String?
}

struct SongAnalysisDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5

    var schemaVersion = currentSchemaVersion
    var lyrics: [TimedLyricSegment] = []
    var chords: [EditableChordEvent] = []
    var chordProSource = ""
    var estimatedBPM: Double?
    var beatTimes: [TimeInterval] = []
    var bassNotes: [BassNoteObservation] = []
    var estimatedKey: MusicalKey?
    var chordConfidenceThreshold: Float = 0.5
    var stems: StoredStemFiles?
    var stemMixer = StemMixerModel()
    var lyricReviewState = AnalysisReviewState.draft
    var chordReviewState = AnalysisReviewState.draft
    var chordProReviewState = AnalysisReviewState.draft
    var stageRecords: [SongAnalysisStage: AnalysisStageRecord] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lyrics
        case chords
        case chordProSource
        case estimatedBPM
        case beatTimes
        case bassNotes
        case estimatedKey
        case chordConfidenceThreshold
        case stems
        case stemMixer
        case lyricReviewState
        case chordReviewState
        case chordProReviewState
        case stageRecords
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        lyrics: [TimedLyricSegment] = [],
        chords: [EditableChordEvent] = [],
        chordProSource: String = "",
        estimatedBPM: Double? = nil,
        beatTimes: [TimeInterval] = [],
        bassNotes: [BassNoteObservation] = [],
        estimatedKey: MusicalKey? = nil,
        chordConfidenceThreshold: Float = 0.5,
        stems: StoredStemFiles? = nil,
        stemMixer: StemMixerModel = StemMixerModel(),
        lyricReviewState: AnalysisReviewState = .draft,
        chordReviewState: AnalysisReviewState = .draft,
        chordProReviewState: AnalysisReviewState = .draft,
        stageRecords: [SongAnalysisStage: AnalysisStageRecord] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.lyrics = lyrics
        self.chords = chords
        self.chordProSource = chordProSource
        self.estimatedBPM = estimatedBPM
        self.beatTimes = beatTimes
        self.bassNotes = bassNotes
        self.estimatedKey = estimatedKey
        self.chordConfidenceThreshold = min(max(chordConfidenceThreshold, 0), 1)
        self.stems = stems
        self.stemMixer = stemMixer
        self.lyricReviewState = lyricReviewState
        self.chordReviewState = chordReviewState
        self.chordProReviewState = chordProReviewState
        self.stageRecords = stageRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        lyrics = try container.decodeIfPresent([TimedLyricSegment].self, forKey: .lyrics) ?? []
        chords = try container.decodeIfPresent([EditableChordEvent].self, forKey: .chords) ?? []
        chordProSource = try container.decodeIfPresent(String.self, forKey: .chordProSource) ?? ""
        estimatedBPM = try container.decodeIfPresent(Double.self, forKey: .estimatedBPM)
        beatTimes = try container.decodeIfPresent([TimeInterval].self, forKey: .beatTimes) ?? []
        bassNotes =
            try container.decodeIfPresent([BassNoteObservation].self, forKey: .bassNotes) ?? []
        estimatedKey =
            try container.decodeIfPresent(MusicalKey.self, forKey: .estimatedKey)
            ?? MusicalKeyEstimator().estimate(from: chords)
        chordConfidenceThreshold = min(
            max(
                try container.decodeIfPresent(Float.self, forKey: .chordConfidenceThreshold) ?? 0.5,
                0
            ),
            1
        )
        stems = try container.decodeIfPresent(StoredStemFiles.self, forKey: .stems)
        stemMixer =
            try container.decodeIfPresent(StemMixerModel.self, forKey: .stemMixer)
            ?? StemMixerModel()
        lyricReviewState =
            try container.decodeIfPresent(AnalysisReviewState.self, forKey: .lyricReviewState)
            ?? .draft
        chordReviewState =
            try container.decodeIfPresent(AnalysisReviewState.self, forKey: .chordReviewState)
            ?? .draft
        chordProReviewState =
            try container.decodeIfPresent(AnalysisReviewState.self, forKey: .chordProReviewState)
            ?? .draft
        stageRecords =
            try container.decodeIfPresent(
                [SongAnalysisStage: AnalysisStageRecord].self,
                forKey: .stageRecords
            ) ?? [:]
    }
}

struct StoredStemFiles: Codable, Equatable, Sendable {
    let vocals: StoredAudioReference
    let drums: StoredAudioReference
    let bass: StoredAudioReference
    let guitar: StoredAudioReference?
    let piano: StoredAudioReference?
    let other: StoredAudioReference
    let accompaniment: StoredAudioReference?

    init(files: StemFiles) {
        vocals = StoredAudioReference(url: files.vocals)
        drums = StoredAudioReference(url: files.drums)
        bass = StoredAudioReference(url: files.bass)
        guitar = files.guitar.map(StoredAudioReference.init(url:))
        piano = files.piano.map(StoredAudioReference.init(url:))
        other = StoredAudioReference(url: files.other)
        accompaniment = files.accompaniment.map(StoredAudioReference.init(url:))
    }

    func resolved() -> StemFiles {
        StemFiles(
            vocals: vocals.resolvedURL(),
            drums: drums.resolvedURL(),
            bass: bass.resolvedURL(),
            guitar: guitar?.resolvedURL(),
            piano: piano?.resolvedURL(),
            other: other.resolvedURL(),
            accompaniment: accompaniment?.resolvedURL()
        )
    }
}

struct StoredAudioReference: Codable, Equatable, Sendable {
    let path: String
    let bookmarkData: Data?

    init(url: URL) {
        path = url.path
        bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolvedURL() -> URL {
        guard let bookmarkData else { return URL(fileURLWithPath: path) }
        var stale = false
        return
            (try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )) ?? URL(fileURLWithPath: path)
    }
}
