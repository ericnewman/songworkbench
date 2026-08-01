import Foundation

/// One sung word within a `TimedLyricSegment`, preserving the transcription's per-word
/// onset/offset so the highlight and bouncing ball can land on the word actually being
/// sung. `characterRange` is the half-open Character-index range of the word within the
/// owning segment's `text`.
struct TimedLyricWord: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var characterRange: Range<Int>
    /// Lowest ASR token confidence among the tokens that render this word (a word is only as
    /// trustworthy as its least certain part). `nil` when the engine reported no per-token
    /// confidence, for reference-lyric-aligned words, and for documents saved before this field
    /// existed — `nil` means UNKNOWN, never "low", so it must not drive any negative signal.
    /// Consumed by `LyricConfidencePlaceholder`.
    var confidence: Float? = nil
}

/// One transcription mode's candidate text for a `LyricBlendRow`'s time window (backlog #11,
/// Lyric Blending). `words` carries that mode's own per-word timings for the window, used if this
/// candidate is chosen (so playback highlighting stays word-accurate regardless of which mode's
/// candidate wins).
struct LyricBlendCandidate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var mode: TranscriptionMode
    var text: String
    var words: [TimedLyricWord] = []
}

/// One time window across the song where at least one transcription mode produced a line, with
/// every mode's candidate for that window stacked together so the user can pick the best one
/// (backlog #11, Lyric Blending). Rows are model-agnostic: their boundaries come from clustering
/// all 3 modes' line starts together, not from any single mode's own line breaks — see
/// `LyricBlendRowBuilder`.
struct LyricBlendRow: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var candidates: [LyricBlendCandidate]
    /// The mode the user picked for this row. `nil` until the user makes a choice — the
    /// EFFECTIVE lyrics (what actually plays/exports) still need a candidate before that point,
    /// so callers fall back to `LyricBlendRow.effectiveCandidate`'s default-mode preference
    /// instead of leaving the row without text.
    var selectedMode: TranscriptionMode?
    /// A user-authored correction for a consistently misheard line — a "4th candidate" that
    /// isn't tied to any transcription mode. `nil`/empty means no override is set. When present,
    /// it takes precedence over every ASR candidate (see `effectiveText`), and it survives a
    /// fresh transcription pass rebuilding the rows from scratch: `LyricBlendRowBuilder
    /// .reconciled` carries it forward onto whichever newly-built row occupies the same time
    /// window, matched by start/end overlap.
    var overrideText: String? = nil

    /// The candidate currently in effect for this row: the user's `selectedMode` if they've
    /// chosen one (and it still has a candidate), else the first available candidate in
    /// `preferenceOrder`, else whichever candidate exists at all. `nil` only when the row somehow
    /// has zero candidates (shouldn't happen — `LyricBlendRowBuilder` never emits an empty row).
    /// Does NOT consider `overrideText` — see `effectiveText` for the text actually used for
    /// playback/export, which checks the override first.
    func effectiveCandidate(
        preferenceOrder: [TranscriptionMode] = [.accuracy, .balancedDraft, .fastDraft]
    ) -> LyricBlendCandidate? {
        if let selectedMode, let match = candidates.first(where: { $0.mode == selectedMode }) {
            return match
        }
        for mode in preferenceOrder {
            if let match = candidates.first(where: { $0.mode == mode }) { return match }
        }
        return candidates.first
    }

    /// The text actually used for playback/export: the user's `overrideText` if set (trimmed,
    /// non-empty), else `effectiveCandidate()`'s text. `nil` only when there's no override and no
    /// candidate at all.
    func effectiveText(
        preferenceOrder: [TranscriptionMode] = [.accuracy, .balancedDraft, .fastDraft]
    ) -> String? {
        if let overrideText {
            let trimmed = overrideText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return effectiveCandidate(preferenceOrder: preferenceOrder)?.text
    }
}

struct TimedLyricSegment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Per-word timings within `text`. Empty for documents saved before word timings
    /// were preserved; callers fall back to interpolation in that case.
    var words: [TimedLyricWord] = []
    /// Average ASR token confidence for this line (backlog #15, Review tab color-coding).
    /// `nil` for documents analyzed before this field existed, for lines rebuilt by a
    /// re-segmentation pass that can't attribute a single confidence to the new cut (e.g.
    /// `LyricPhraseGrouper`), and for reference-lyric-aligned lines (no ASR confidence to carry).
    var confidence: Float?
    /// Whether the user has explicitly accepted this line in the Review tab (backlog #15).
    /// Purely additive to the existing whole-song `lyricReviewState` — does not affect it.
    var accepted: Bool = false
    /// A user-authored correction typed directly into the Review chart (backlog #15 Phase 2
    /// consolidation), mirroring `LyricBlendRow.overrideText`. `nil`/empty means no override.
    /// When present, it — not `text` — is what displays/exports/plays, and it SURVIVES a fresh
    /// re-analysis rebuilding `lyrics` from scratch: reconciliation (see
    /// `TimedLyricSegment.reconciled(newSegments:against:)`) carries it forward onto whichever
    /// freshly-built segment occupies the same time window, matched by start/end overlap — same
    /// convention `LyricBlendRowBuilder.reconciled` already uses for lyric blend rows.
    var overrideText: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case text
        case words
        case confidence
        case accepted
        case overrideText
    }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [TimedLyricWord] = [],
        confidence: Float? = nil,
        accepted: Bool = false,
        overrideText: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.confidence = confidence
        self.accepted = accepted
        self.overrideText = overrideText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        words = try container.decodeIfPresent([TimedLyricWord].self, forKey: .words) ?? []
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        overrideText = try container.decodeIfPresent(String.self, forKey: .overrideText)
    }

    /// The text actually shown/exported/played: the user's `overrideText` if set (trimmed,
    /// non-empty), else the raw transcribed `text`. Mirrors `LyricBlendRow.effectiveText`.
    var effectiveText: String {
        if let overrideText {
            let trimmed = overrideText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return text
    }

    /// Carries `overrideText`/`accepted` forward from a PRIOR analysis's segments onto a freshly
    /// re-analyzed set, matched by greatest start/end-window overlap (falling back to nearest
    /// start when no window overlaps at all) — same reconciliation convention
    /// `LyricBlendRowBuilder.reconciled` already uses. Matching always compares the raw `start`/
    /// `end` a fresh transcription produced, never a manually-edited value, so an edit never
    /// poisons future reconciliation. Confidence/words/text always come from the NEW segment —
    /// only the user's own annotations carry forward.
    static func reconciled(
        newSegments: [TimedLyricSegment], against oldSegments: [TimedLyricSegment]
    ) -> [TimedLyricSegment] {
        guard !oldSegments.isEmpty else { return newSegments }
        return newSegments.map { fresh in
            guard let match = bestMatch(for: fresh, in: oldSegments) else { return fresh }
            var carried = fresh
            carried.overrideText = match.overrideText
            carried.accepted = match.accepted
            return carried
        }
    }

    private static func bestMatch(
        for fresh: TimedLyricSegment, in oldSegments: [TimedLyricSegment]
    ) -> TimedLyricSegment? {
        let freshWindow = min(fresh.start, fresh.end)...max(fresh.start, fresh.end)
        var best: (segment: TimedLyricSegment, overlap: TimeInterval)?
        for old in oldSegments {
            let oldWindow = min(old.start, old.end)...max(old.start, old.end)
            let overlap =
                max(
                    0,
                    min(freshWindow.upperBound, oldWindow.upperBound)
                        - max(freshWindow.lowerBound, oldWindow.lowerBound))
            if overlap > 0, best == nil || overlap > best!.overlap {
                best = (old, overlap)
            }
        }
        if let best { return best.segment }
        // No time-window overlap at all (a boundary shifted completely past the old one) — fall
        // back to nearest start, same as `LyricBlendRowBuilder.reconciled`'s fallback.
        return oldSegments.min { abs($0.start - fresh.start) < abs($1.start - fresh.start) }
    }
}

/// Which measured signal a chord event's time is anchored to. A chord change is an inference;
/// where in time it is placed is a separate question with more than one defensible answer, and
/// the answers disagree on real songs (measured 2026-08-01: the onset snap moves 33-99% of events
/// depending on the song, because `InstrumentOnsetDetector` fires on ATTACKS and a chord change
/// under sustained instrumentation produces none). Rather than pick one blind, the decoder records
/// every candidate placement so they can be A/B'd against the audio by ear.
///
/// The raw values are the persisted keys of `EditableChordEvent.placementCandidates` — renaming
/// one silently orphans existing picks, so don't.
enum ChordPlacementVariant: String, Codable, CaseIterable, Sendable {
    /// The decoder's own window boundary — `beatTimes[i]` for the window that won the Viterbi.
    /// Exactly on a beat by construction (`ChordTimelineDecoder.windowEvidence`), which is why
    /// comparing chord times to the beat grid can never validate the grid.
    case beatQuantized
    /// Snapped to the nearest instrumental attack by `ChordOnsetAligner` — today's shipped time.
    case instrumentOnset

    var displayName: String {
        switch self {
        case .beatQuantized: return "Beat"
        case .instrumentOnset: return "Onset"
        }
    }
}

/// A listener's verdict that, over one span of the song, one placement variant sits better
/// against the audio than the others. Stored as an absolute TIME RANGE rather than as section or
/// row indices so it survives re-analysis: sections are re-derived from lyrics and can renumber,
/// but the seconds a chorus occupies barely move. Same reasoning as
/// `LyricBlendRowBuilder.reconciled`'s time-window overlap matching.
struct ChordPlacementPick: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var variant: ChordPlacementVariant

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, variant: ChordPlacementVariant)
    {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
        self.variant = variant
    }

    func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }
}

struct EditableChordEvent: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var time: TimeInterval
    var chord: String
    var confidence: Float?
    /// Whether the user has explicitly accepted this chord event in the Review tab (backlog #15).
    /// Purely additive to the existing whole-song `chordReviewState` — does not affect it.
    var accepted: Bool = false
    /// A user-dragged position from the Review chart (backlog #15 Phase 2 consolidation). `nil`
    /// means "use the detected `time`." Deliberately a FREE timestamp with no snapping (Eric's
    /// confirmed decision) — dragging a chord drops it exactly where released. Kept separate from
    /// `time` (rather than overwriting it) so reconciliation across a fresh re-analysis always has
    /// the original DETECTED time to match against — see `reconciled(newEvents:against:)`.
    var manualTime: TimeInterval? = nil
    /// Candidate times for this same chord change under each placement rule, keyed by
    /// `ChordPlacementVariant.rawValue`. Recorded by the harmony stage so the alternatives can be
    /// compared against the audio without re-analysing. Empty for documents written before the
    /// A/B rig existed, and for events whose stage produced no alternatives — callers must treat
    /// a missing key as "this variant is unavailable", never as an error.
    var placementCandidates: [String: TimeInterval] = [:]

    private enum CodingKeys: String, CodingKey {
        case id
        case time
        case chord
        case confidence
        case accepted
        case manualTime
        case placementCandidates
    }

    init(
        id: UUID = UUID(),
        time: TimeInterval,
        chord: String,
        confidence: Float? = nil,
        accepted: Bool = false,
        manualTime: TimeInterval? = nil,
        placementCandidates: [String: TimeInterval] = [:]
    ) {
        self.id = id
        self.time = time
        self.chord = chord
        self.confidence = confidence
        self.accepted = accepted
        self.manualTime = manualTime
        self.placementCandidates = placementCandidates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try container.decode(TimeInterval.self, forKey: .time)
        chord = try container.decode(String.self, forKey: .chord)
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        manualTime = try container.decodeIfPresent(TimeInterval.self, forKey: .manualTime)
        placementCandidates =
            try container.decodeIfPresent([String: TimeInterval].self, forKey: .placementCandidates)
            ?? [:]
    }

    /// The position actually used for display/drag interaction: the user's manually-dragged
    /// `manualTime` if set, else the detected `time`. Reconciliation and anything comparing
    /// against fresh detection output should keep using raw `time`, never this.
    var effectiveTime: TimeInterval { manualTime ?? time }

    /// This event's recorded time under `variant`, or nil when the stage produced no such
    /// candidate (older documents, or a run where the variant's cue was unavailable).
    func placementTime(for variant: ChordPlacementVariant) -> TimeInterval? {
        placementCandidates[variant.rawValue]
    }

    /// Display position when a placement variant is being auditioned. `manualTime` still wins —
    /// a hand-dragged chord is a decision, not a candidate — and a variant with no recorded
    /// candidate falls back to `effectiveTime` so an A/B never silently drops an event.
    func effectiveTime(preferring variant: ChordPlacementVariant?) -> TimeInterval {
        if let manualTime { return manualTime }
        guard let variant, let candidate = placementTime(for: variant) else { return effectiveTime }
        return candidate
    }

    /// Carries `manualTime`/`accepted` forward from a PRIOR analysis's chord events onto a
    /// freshly re-detected set, matched by nearest DETECTED `time` (never `effectiveTime`, so a
    /// drag never poisons future reconciliation) within `tolerance` seconds. Same convention as
    /// `TimedLyricSegment.reconciled`.
    static func reconciled(
        newEvents: [EditableChordEvent], against oldEvents: [EditableChordEvent],
        tolerance: TimeInterval = 0.75
    ) -> [EditableChordEvent] {
        guard !oldEvents.isEmpty else { return newEvents }
        return newEvents.map { fresh in
            guard
                let match = oldEvents.filter({ abs($0.time - fresh.time) <= tolerance })
                    .min(by: { abs($0.time - fresh.time) < abs($1.time - fresh.time) })
            else { return fresh }
            var carried = fresh
            carried.manualTime = match.manualTime
            carried.accepted = match.accepted
            return carried
        }
    }

    /// Finds the real chord event a rendered chart chord corresponds to, given the RAW onset
    /// time `SongTimeline.Row.chordTimes` recorded for it (Review chart interactivity, backlog
    /// #15 Phase 2 remainder). That time is the literal `event.time` `ChordProDraftBuilder`
    /// threaded into the chart, so matching by nearest raw `time` (never `effectiveTime`, so a
    /// previous drag can't shift which event a chart chord resolves to) recovers the same event
    /// even after it's been dragged/accepted. `tolerance` only guards against floating-point
    /// drift — the times are otherwise expected to match exactly.
    static func matching(
        rowTime: TimeInterval, in events: [EditableChordEvent], tolerance: TimeInterval = 0.01
    ) -> EditableChordEvent? {
        events.filter { abs($0.time - rowTime) <= tolerance }
            .min { abs($0.time - rowTime) < abs($1.time - rowTime) }
    }
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
    /// Real-time capture (loopback / mic / system audio). No audio is ever persisted; only the
    /// derived chart is saved. Always a draft, never loaded from cache.
    case liveCapture
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
    // 7: added sourceDuration (full audio length for lyric/chord timeline bounds).
    // 8: added untranscribedVocalRegions (sung spans the ASR produced no words for).
    // 9: added lyricBlendRows (Lyric Blending feature, backlog #11).
    // 10: added TimedLyricSegment.confidence/.accepted and EditableChordEvent.accepted
    //     (Review tab, backlog #15). All optional/defaulted, so no migration is required.
    // 11: added LyricBlendRow.overrideText (manual per-line correction, takes precedence over
    //     every ASR candidate and survives re-analysis). Optional, no migration required.
    static let currentSchemaVersion = 11

    var schemaVersion = currentSchemaVersion
    var lyrics: [TimedLyricSegment] = []
    /// Per-time-window candidate lines from every transcription mode that produced one, for the
    /// "Lyric Blend" picker (backlog #11). `lyrics` above always reflects the CURRENT effective
    /// blend (each row's `selectedMode` candidate, defaulting to accuracy) — this array is the
    /// raw material the blend UI presents, not a second source of truth for playback/ChordPro,
    /// which always read `lyrics`. Empty for songs analyzed before this feature, or when only one
    /// transcription engine was installed at analysis time (nothing to blend).
    var lyricBlendRows: [LyricBlendRow] = []
    /// Sung regions (strict-VAD voiced) that have NO transcribed words — chorus tails, ad-libs,
    /// outro vocals the ASR missed (audit RC-4). Consumers must not label these Instrumental.
    var untranscribedVocalRegions: [ClosedRange<TimeInterval>] = []
    /// User-provided reference lyrics. When non-empty, the transcription stage aligns these exact
    /// words/lines to the ASR word timings instead of using the raw ASR text (see
    /// `ReferenceLyricAligner`).
    var referenceLyrics = ""
    /// Full audio duration from transcription (seconds), used to span intro/outro gaps on the timeline.
    var sourceDuration: TimeInterval? = nil
    var chords: [EditableChordEvent] = []
    var chordProSource = ""
    var estimatedBPM: Double?
    var beatTimes: [TimeInterval] = []
    var bassNotes: [BassNoteObservation] = []
    var estimatedKey: MusicalKey?
    var chordConfidenceThreshold: Float = 0.5
    /// Listener verdicts from the chord-placement A/B, newest last. A later pick overlapping an
    /// earlier one wins, so re-judging a span does not require deleting the old verdict.
    var chordPlacementPicks: [ChordPlacementPick] = []
    var stems: StoredStemFiles?
    var stemSet: StoredStemSetManifest?
    var stemMixer = StemMixerModel()
    var lyricReviewState = AnalysisReviewState.draft
    var chordReviewState = AnalysisReviewState.draft
    var chordProReviewState = AnalysisReviewState.draft
    var stageRecords: [SongAnalysisStage: AnalysisStageRecord] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lyrics
        case lyricBlendRows
        case untranscribedVocalRegions
        case referenceLyrics
        case sourceDuration
        case chords
        case chordProSource
        case estimatedBPM
        case beatTimes
        case bassNotes
        case estimatedKey
        case chordConfidenceThreshold
        case chordPlacementPicks
        case stems
        case stemSet
        case stemMixer
        case lyricReviewState
        case chordReviewState
        case chordProReviewState
        case stageRecords
    }

    init(
        schemaVersion: Int = currentSchemaVersion,
        lyrics: [TimedLyricSegment] = [],
        lyricBlendRows: [LyricBlendRow] = [],
        untranscribedVocalRegions: [ClosedRange<TimeInterval>] = [],
        referenceLyrics: String = "",
        sourceDuration: TimeInterval? = nil,
        chords: [EditableChordEvent] = [],
        chordProSource: String = "",
        estimatedBPM: Double? = nil,
        beatTimes: [TimeInterval] = [],
        bassNotes: [BassNoteObservation] = [],
        estimatedKey: MusicalKey? = nil,
        chordConfidenceThreshold: Float = 0.5,
        chordPlacementPicks: [ChordPlacementPick] = [],
        stems: StoredStemFiles? = nil,
        stemSet: StoredStemSetManifest? = nil,
        stemMixer: StemMixerModel = StemMixerModel(),
        lyricReviewState: AnalysisReviewState = .draft,
        chordReviewState: AnalysisReviewState = .draft,
        chordProReviewState: AnalysisReviewState = .draft,
        stageRecords: [SongAnalysisStage: AnalysisStageRecord] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.lyrics = lyrics
        self.lyricBlendRows = lyricBlendRows
        self.untranscribedVocalRegions = untranscribedVocalRegions
        self.referenceLyrics = referenceLyrics
        self.sourceDuration = sourceDuration
        self.chords = chords
        self.chordProSource = chordProSource
        self.estimatedBPM = estimatedBPM
        self.beatTimes = beatTimes
        self.bassNotes = bassNotes
        self.estimatedKey = estimatedKey
        self.chordConfidenceThreshold = min(max(chordConfidenceThreshold, 0), 1)
        self.chordPlacementPicks = chordPlacementPicks
        self.stems = stems
        self.stemSet = stemSet ?? stems.map { StoredStemSetManifest(files: $0.resolved()) }
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
        lyricBlendRows =
            try container.decodeIfPresent([LyricBlendRow].self, forKey: .lyricBlendRows) ?? []
        untranscribedVocalRegions =
            try container.decodeIfPresent(
                [ClosedRange<TimeInterval>].self, forKey: .untranscribedVocalRegions) ?? []
        referenceLyrics =
            try container.decodeIfPresent(String.self, forKey: .referenceLyrics) ?? ""
        sourceDuration =
            try container.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration)
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
        chordPlacementPicks =
            try container.decodeIfPresent([ChordPlacementPick].self, forKey: .chordPlacementPicks)
            ?? []
        stems = try container.decodeIfPresent(StoredStemFiles.self, forKey: .stems)
        stemSet =
            try container.decodeIfPresent(StoredStemSetManifest.self, forKey: .stemSet)
            ?? stems.map { StoredStemSetManifest(files: $0.resolved()) }
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

struct StoredStemSetManifest: Codable, Equatable, Sendable {
    let descriptors: [StemDescriptor]
    let assets: [StoredStemAsset]
    let recipeIdentity: StemRecipeIdentity?

    init(manifest: StemSetManifest) {
        descriptors = manifest.descriptors
        assets = manifest.assets.map(StoredStemAsset.init(asset:))
        recipeIdentity = manifest.recipeIdentity
    }

    init(files: StemFiles) {
        self.init(manifest: files.stemSetManifest)
    }

    func resolved() -> StemSetManifest {
        StemSetManifest(
            descriptors: descriptors,
            assets: assets.map(\.resolved),
            recipeIdentity: recipeIdentity
        )
    }
}

struct StoredStemAsset: Codable, Equatable, Sendable {
    let id: StemID
    let audio: StoredAudioReference
    let producerID: String

    init(asset: StemAsset) {
        id = asset.id
        audio = StoredAudioReference(url: asset.audioURL)
        producerID = asset.producerID
    }

    var resolved: StemAsset {
        StemAsset(id: id, audioURL: audio.resolvedURL(), producerID: producerID)
    }
}

struct StoredAudioReference: Codable, Equatable, Sendable {
    let path: String
    let bookmarkData: Data?

    init(url: URL) {
        path = url.path
        bookmarkData = try? url.appScopedBookmarkData()
    }

    func resolvedURL() -> URL {
        guard let bookmarkData else { return URL(fileURLWithPath: path) }
        var stale = false
        return
            (try? URL(resolvingAppScopedBookmark: bookmarkData, bookmarkDataIsStale: &stale))
            ?? URL(fileURLWithPath: path)
    }
}
