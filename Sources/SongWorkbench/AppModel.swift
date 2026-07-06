import CryptoKit
import Foundation

enum PlaybackSource: Equatable, Sendable {
    case recording
    case stemMix
}

/// Pure lyric-line join/split transforms (character-range arithmetic on `TimedLyricSegment`), split
/// out from `AppModel` so they can be unit-tested without the view/model.
enum LyricLineEdit {
    /// `first` followed by `next` joined into one line: text concatenated with a space, `next`'s
    /// per-word timings re-indexed past the join, span covering both.
    static func merged(_ first: TimedLyricSegment, _ next: TimedLyricSegment) -> TimedLyricSegment {
        let joined = first.text + " " + next.text
        let offset = first.text.count + 1
        let shifted = next.words.map { word in
            TimedLyricWord(
                text: word.text, start: word.start, end: word.end,
                characterRange: (word.characterRange.lowerBound + offset)..<(word.characterRange
                    .upperBound + offset))
        }
        return TimedLyricSegment(
            start: min(first.start, next.start),
            end: max(first.end, next.end),
            text: joined,
            words: first.words + shifted)
    }

    /// `segment` broken in two at its largest internal word gap, or `nil` if it has < 2 words or no
    /// usable split point. Each half's word character-ranges are re-indexed into its own text.
    static func split(_ segment: TimedLyricSegment) -> (TimedLyricSegment, TimedLyricSegment)? {
        let words = segment.words
        guard words.count >= 2 else { return nil }
        var splitAt = 1
        var widestGap = -TimeInterval.infinity
        for k in 1..<words.count where words[k].start - words[k - 1].end > widestGap {
            widestGap = words[k].start - words[k - 1].end
            splitAt = k
        }
        let chars = Array(segment.text)
        let cut = words[splitAt].characterRange.lowerBound
        guard cut > 0, cut < chars.count else { return nil }
        let firstWords = Array(words[0..<splitAt])
        let secondWords = words[splitAt...].map { word in
            TimedLyricWord(
                text: word.text, start: word.start, end: word.end,
                characterRange: (word.characterRange.lowerBound - cut)..<(word.characterRange
                    .upperBound - cut))
        }
        let first = TimedLyricSegment(
            start: segment.start, end: firstWords.last?.end ?? segment.start,
            text: String(chars[0..<cut]).trimmingCharacters(in: .whitespaces), words: firstWords)
        let second = TimedLyricSegment(
            start: secondWords.first?.start ?? segment.end, end: segment.end,
            text: String(chars[cut...]), words: secondWords)
        return (first, second)
    }
}

/// Flags lyric lines that look like mis-splits / mis-timings, for review in the editor. Uses a
/// probable line length (the median line's beats) and the beat grid: a line far off the typical
/// length, or whose onset sits well off any beat, is suspect. Pure so it can be unit-tested.
enum LyricLineDiagnostics {
    /// Reason strings keyed by segment id. Empty without a tempo or with too few lines to judge.
    static func suspectReasons(
        _ segments: [TimedLyricSegment], beatTimes: [TimeInterval], tempo: Double?
    ) -> [TimedLyricSegment.ID: String] {
        guard let tempo, tempo > 0, segments.count >= 4 else { return [:] }
        let beatDuration = 60.0 / tempo
        guard beatDuration > 0 else { return [:] }
        let lengths = segments.map { max(0, ($0.end - $0.start) / beatDuration) }.sorted()
        let median = lengths[lengths.count / 2]
        guard median > 0 else { return [:] }
        let sortedBeats = beatTimes.sorted()
        func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
        var result: [TimedLyricSegment.ID: String] = [:]
        for segment in segments {
            var reasons: [String] = []
            let length = max(0, (segment.end - segment.start) / beatDuration)
            if length < max(2.0, median * 0.45) {
                reasons.append("short — \(fmt(length)) beats vs ~\(fmt(median)) typical")
            } else if length > median * 1.9 {
                reasons.append("long — \(fmt(length)) beats vs ~\(fmt(median)) typical")
            }
            if let nearest = sortedBeats.min(by: {
                abs($0 - segment.start) < abs($1 - segment.start)
            }) {
                let off = abs(nearest - segment.start) / beatDuration
                if off > 0.3 { reasons.append("starts \(fmt(off)) beat off the grid") }
            }
            if !reasons.isEmpty {
                result[segment.id] = "Possible mis-split — " + reasons.joined(separator: "; ")
            }
        }
        return result
    }
}

/// Type-to-select matching for the song list. Pure and case/diacritic-insensitive so it can be
/// unit-tested independently of the view.
enum SongTypeahead {
    /// The first song whose title begins with `prefix` (case- and diacritic-insensitive, surrounding
    /// whitespace trimmed). Returns `nil` for an empty prefix or when nothing matches.
    static func firstMatch(prefix: String, in songs: [Song]) -> Song? {
        let needle =
            prefix
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        return songs.first { song in
            song.title
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .hasPrefix(needle)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published var selectedSongID: Song.ID?
    @Published private(set) var waveform: WaveformEnvelope?
    @Published private(set) var isLoadingWaveform = false
    /// Detected singing intervals on the vocals stem, overlaid on the waveform so vocal-activity
    /// detection can be evaluated (and later used to correct lyric timing). Empty when no stem.
    @Published private(set) var vocalActivityIntervals: [ClosedRange<TimeInterval>] = []
    /// A waveform envelope of the isolated vocals stem (finer-grained than the song waveform), used
    /// to render a per-lyric-line audio strip so word↔voice alignment is directly visible. `nil`
    /// when the song has no vocals stem (the preview falls back to the full-mix `waveform`).
    @Published private(set) var vocalWaveform: WaveformEnvelope?
    /// Per-stem waveform envelopes, one lane per available stem, in a fixed display order. Rendered
    /// as stacked lanes beneath the full-mix waveform so each instrument's energy lines up with the
    /// mix on a shared time axis. Empty when the song has no separated stems.
    @Published private(set) var stemWaveforms: [(kind: StemKind, envelope: WaveformEnvelope)] = []
    @Published private(set) var projectErrorMessage: String?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    @Published var lyricSegments: [TimedLyricSegment] = [] {
        didSet {
            if !isApplyingAnalysis {
                lyricReviewState = .draft
                rebuildGeneratedChordProDraft()
            }
            persistSelectedAnalysis()
        }
    }
    /// Per-time-window candidate lines from every transcription mode, for the "Lyric Blend"
    /// window (backlog #11). Mirrors `document.lyricBlendRows` for the SELECTED song, the same
    /// way `lyricSegments` mirrors `document.lyrics` — see `applyLyricBlendSelection` and
    /// `LyricBlendRowBuilder`. No `didSet` of its own: callers that change a row's
    /// `selectedMode` always also reassign `lyricSegments` from
    /// `LyricBlendRowBuilder.effectiveLyrics`, which is what actually triggers the existing
    /// rebuild/persist pipeline above.
    @Published private(set) var lyricBlendRows: [LyricBlendRow] = []
    /// The song ID whose Lyric Blend candidates just finished computing — a view observes this
    /// to auto-open the "Lyric Blend" window once, per the backlog #11 spec ("on analysis
    /// complete, open a new Lyric Blend window"). Consumers should reset it to `nil` after
    /// opening the window so re-selecting the song later doesn't re-trigger it.
    @Published var lyricBlendReadySongID: Song.ID?
    /// True while the two non-primary transcription modes are running in the background after a
    /// full analysis, to populate Lyric Blend candidates. The primary analysis has ALREADY
    /// finished and `document.lyrics`/ChordPro are fully usable during this window — this flag is
    /// purely informational (e.g. a small "Preparing lyric blend…" indicator), never a gate on
    /// other UI.
    @Published private(set) var isComputingLyricBlend = false
    /// Live description of the post-analysis background phase (per-mode blend transcription,
    /// stem-onset matching, chart rebuild), for the bottom status bar — the 30–60s window
    /// after an analysis completes previously showed NOTHING while the app quietly re-ran
    /// the other transcription modes and then refreshed lyrics/chart (Eric: "we need some
    /// indication of the background activity … that precedes the refresh").
    @Published private(set) var lyricBlendStatus: String?
    /// User-provided reference lyrics. Persisted; the next analysis aligns these exact words/lines
    /// to the ASR timings. Call `applyReferenceLyrics()` to re-run alignment from the cached audio.
    @Published var referenceLyrics = "" {
        didSet {
            guard !isApplyingAnalysis, referenceLyrics != oldValue else { return }
            persistSelectedAnalysis()
        }
    }
    @Published var chordEvents: [EditableChordEvent] = [] {
        didSet {
            if !isApplyingAnalysis { chordReviewState = .draft }
            persistSelectedAnalysis()
        }
    }
    @Published var chordProSource = "" {
        didSet {
            if !isApplyingAnalysis { chordProReviewState = .draft }
            persistSelectedAnalysis()
        }
    }
    @Published var estimatedBPM: Double? {
        didSet { persistSelectedAnalysis() }
    }
    @Published var beatTimes: [TimeInterval] = [] {
        didSet { persistSelectedAnalysis() }
    }
    /// Full audio duration from transcription (seconds), for intro/outro timeline bounds.
    @Published var sourceDuration: TimeInterval? {
        didSet { persistSelectedAnalysis() }
    }
    /// Sung spans the ASR produced no words for (audit RC-4); flags timeline rows so
    /// "instrumental" sections that actually contain vocals can be surfaced.
    @Published var untranscribedVocalRegions: [ClosedRange<TimeInterval>] = [] {
        didSet { persistSelectedAnalysis() }
    }
    @Published var bassNotes: [BassNoteObservation] = [] {
        didSet { persistSelectedAnalysis() }
    }
    @Published var estimatedKey: MusicalKey? {
        didSet { persistSelectedAnalysis() }
    }
    @Published var chordConfidenceThreshold: Float = 0.5 {
        didSet {
            let normalized = min(max(chordConfidenceThreshold, 0), 1)
            if normalized != chordConfidenceThreshold {
                chordConfidenceThreshold = normalized
                return
            }
            guard !isApplyingAnalysis else { return }
            rebuildGeneratedChordProDraft()
            persistSelectedAnalysis()
        }
    }
    @Published var stemFiles: StemFiles? {
        didSet { persistSelectedAnalysis() }
    }
    @Published var stemMixer = StemMixerModel() {
        didSet { persistSelectedAnalysis() }
    }
    @Published private(set) var lyricReviewState = AnalysisReviewState.draft {
        didSet { persistSelectedAnalysis() }
    }
    @Published private(set) var chordReviewState = AnalysisReviewState.draft {
        didSet { persistSelectedAnalysis() }
    }
    @Published private(set) var chordProReviewState = AnalysisReviewState.draft {
        didSet { persistSelectedAnalysis() }
    }
    @Published private(set) var analysisStageRecords: [SongAnalysisStage: AnalysisStageRecord] = [:]
    {
        didSet { persistSelectedAnalysis() }
    }
    @Published private(set) var analysisJobSnapshot: BackgroundJobSnapshot?
    /// Live import/localization progress ("Importing 2 of 5: …"); nil when idle. Feeds the
    /// always-visible background-status line.
    @Published private(set) var importStatus: String?

    /// One-line description of whatever the app is doing in the background right now, for
    /// the persistent status line at the bottom of the main window. `nil` = idle.
    var backgroundActivityStatus: String? {
        if let importStatus { return importStatus }
        if let bulk = reanalyzeAllStatus {
            return "Re-analyzing \(bulk.index) of \(bulk.total): \(bulk.title)…"
        }
        if isSongAnalysisRunning {
            if let progress = songAnalysisProgress {
                let percent = Int((progress.fractionCompleted * 100).rounded())
                return "Analyzing… \(progress.message) (\(percent)%)"
            }
            return "Analyzing song…"
        }
        if let lyricBlendStatus { return lyricBlendStatus }
        if isExporting {
            return "Exporting mix… \(Int((exportProgress * 100).rounded()))%"
        }
        if let (id, progress) = modelInstallProgress.min(by: { $0.key < $1.key }) {
            let name = ModelCatalog.all.first { $0.id == id }?.displayName ?? "model"
            return "Downloading \(name)… \(Int((progress * 100).rounded()))%"
        }
        if isLoadingWaveform { return "Loading waveform…" }
        return nil
    }
    static let accuracyDecodeSpeedDefaultsKey = "accuracyDecodeSpeed"
    /// Pitch-preserved playback-speed factor applied to the vocals stem before Whisper (Accuracy)
    /// transcription. < 1 slows the audio, which can improve recognition of fast / dense singing;
    /// 1.0 disables it. Timestamps are mapped back to real time afterward. Persisted; the UI bounds
    /// it to 0.75–1.0.
    @Published var accuracyDecodeSpeed: Double = {
        let stored = UserDefaults.standard.double(forKey: AppModel.accuracyDecodeSpeedDefaultsKey)
        return stored == 0 ? 0.85 : stored
    }()
    {
        didSet {
            UserDefaults.standard.set(
                accuracyDecodeSpeed, forKey: AppModel.accuracyDecodeSpeedDefaultsKey)
        }
    }
    @Published private(set) var songAnalysisProgress: SongAnalysisPipelineProgress?
    @Published private(set) var isSongAnalysisRunning = false
    /// While "Re-analyze All Songs" runs, the song currently being processed and its position in
    /// the queue, so the progress UI can show "Re-analyzing 3 of 25: <title>". Nil otherwise.
    @Published private(set) var reanalyzeAllStatus: ReanalyzeAllStatus?

    struct ReanalyzeAllStatus: Equatable {
        var index: Int
        var total: Int
        var title: String
    }
    @Published private(set) var activePlaybackSource = PlaybackSource.recording
    @Published private(set) var modelPackageStatuses: [String: ModelPackageStatus] = [:]
    @Published private(set) var modelInstallProgress: [String: Double] = [:]
    @Published var pitchSemitones = 0 {
        didSet {
            let normalized = PitchShift.normalized(pitchSemitones)
            if normalized != pitchSemitones {
                pitchSemitones = normalized
                return
            }
            playback.setPitch(semitones: normalized)
            stemPlayback.setPitch(semitones: normalized)
            persistSelectedSettings()
        }
    }
    @Published var tempoRate = 1.0 {
        didSet {
            let normalized = min(max(tempoRate, 0.5), 1.5)
            if normalized != tempoRate {
                tempoRate = normalized
                return
            }
            playback.setTempo(rate: normalized)
            stemPlayback.setTempo(rate: normalized)
            persistSelectedSettings()
        }
    }
    @Published var loopRegion: LoopRegion? {
        didSet {
            let normalized = loopRegion?.clamped(to: playback.duration)
            if normalized != loopRegion {
                loopRegion = normalized
                return
            }
            playback.setLoopRegion(normalized)
            persistSelectedSettings()
        }
    }
    @Published var chordProTranspose = 0 {
        didSet {
            let normalized = min(max(chordProTranspose, -12), 12)
            if normalized != chordProTranspose {
                chordProTranspose = normalized
                return
            }
            persistSelectedSettings()
        }
    }
    /// Render-only timing offset (ms) for the ChordPro bouncing ball / position
    /// indicator. Single source of truth read by the ball clock; never touches audio.
    @Published var chordProTimingOffsetMS = 0 {
        didSet {
            let normalized = min(max(chordProTimingOffsetMS, -500), 500)
            if normalized != chordProTimingOffsetMS {
                chordProTimingOffsetMS = normalized
                return
            }
            persistSelectedSettings()
        }
    }
    @Published var isImporterPresented = false

    // MARK: Music library (Apple Music / Music app) browsing
    @Published var isMusicLibraryPickerPresented = false
    @Published private(set) var musicLibraryItems: [MusicLibraryItem] = []
    @Published private(set) var isLoadingMusicLibrary = false
    @Published private(set) var musicLibraryError: String?
    /// Friendly explanation shown when the user picks a DRM/cloud track that
    /// can't be opened. Cleared when an openable track loads.
    @Published var musicLibraryNotice: String?

    let playback = AudioPlaybackService()
    let stemPlayback = StemPlaybackService()
    let offlineExporter = OfflineAudioExporter()

    private let store: any ProjectStore
    private let musicLibrary: any MusicLibraryProviding
    private let waveformAnalyzer = WaveformAnalyzer()
    private let audioAnalysisService = AudioFileAnalysisService()
    private let analysisJobs = BackgroundJobCoordinator()
    private let analysisCache: AnalysisResultDiskCache
    private let stemMixExporter = StemMixExporter()
    private let chordProBuilder = ChordProDraftBuilder()
    private let modelPackageManager: ModelPackageManager
    private var settingsBySongID: [Song.ID: PracticeSettings] = [:]
    private var analysisBySongID: [Song.ID: SongAnalysisDocument] = [:]
    private var lastOpenedBySongID: [Song.ID: Date] = [:]
    private var saveTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var vocalActivityTask: Task<Void, Never>?
    private var stemWaveformsTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var analysisControlTask: Task<Void, Never>?
    private var analysisMonitorTask: Task<Void, Never>?
    private let analysisCoordinator: SongAnalysisCoordinator
    private var modelInstallTasks: [String: Task<Void, Never>] = [:]
    private var currentAnalysisJobID: BackgroundJobID?
    private var currentExportID: UUID?
    private var isApplyingSettings = false
    private var isApplyingAnalysis = false
    private var hasRestoredProjects = false
    private var needsSaveAfterRestore = false

    init(
        store: any ProjectStore = SplitProjectStore.standard,
        musicLibrary: (any MusicLibraryProviding)? = nil
    ) {
        self.store = store
        self.musicLibrary = musicLibrary ?? DefaultMusicLibrary.make()
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let modelDirectory =
            applicationSupportDirectory
            .appendingPathComponent("SongWorkbench", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        modelPackageManager = ModelPackageManager(
            directoryURL: modelDirectory,
            downloader: URLSessionModelArtifactDownloader()
        )
        let cacheRootDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        Self.migrateLegacyDirectoryIfNeeded(
            named: "CCSSongWorkbench",
            to: "SongWorkbench",
            in: cacheRootDirectory
        )
        let cacheDirectory =
            cacheRootDirectory
            .appendingPathComponent("SongWorkbench", isDirectory: true)
            .appendingPathComponent("Analysis", isDirectory: true)
        analysisCache = AnalysisResultDiskCache(directoryURL: cacheDirectory)
        analysisCoordinator = SongAnalysisCoordinator(
            pipelineFactory: SongAnalysisPipelineFactory(
                modelPackageManager: modelPackageManager,
                harmonyEngine: audioAnalysisService,
                cache: analysisCache
            )
        )
        Task { await restoreProjects() }
        Task { await refreshModelPackageStatuses() }
    }

    private static func migrateLegacyDirectoryIfNeeded(
        named legacyName: String,
        to currentName: String,
        in baseDirectory: URL
    ) {
        let currentURL = baseDirectory.appendingPathComponent(currentName, isDirectory: true)
        let legacyURL = baseDirectory.appendingPathComponent(legacyName, isDirectory: true)
        guard
            !FileManager.default.fileExists(atPath: currentURL.path),
            FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }
        try? FileManager.default.moveItem(at: legacyURL, to: currentURL)
    }

    isolated deinit {
        saveTask?.cancel()
        waveformTask?.cancel()
        vocalActivityTask?.cancel()
        stemWaveformsTask?.cancel()
        exportTask?.cancel()
        analysisControlTask?.cancel()
        analysisMonitorTask?.cancel()
        analysisCoordinator.cancel()
        for task in modelInstallTasks.values { task.cancel() }
    }

    var selectedSong: Song? {
        songs.first { $0.id == selectedSongID }
    }

    var recentSongs: [Song] {
        songs.sorted {
            (lastOpenedBySongID[$0.id] ?? .distantPast)
                > (lastOpenedBySongID[$1.id] ?? .distantPast)
        }
    }

    var totalInstalledModelBytes: Int64 {
        modelPackageStatuses.values.reduce(0) { total, status in
            guard case .installed(let package) = status else { return total }
            return total + package.sizeBytes
        }
    }

    var requiresChordProReplacementConfirmation: Bool {
        guard !chordProSource.isEmpty else { return false }
        let existingWasGenerated =
            analysisStageRecords[.chordPro]?.state == .succeeded
            && analysisStageRecords[.chordPro]?.provenance?.engineIdentifier
                == "chordpro-draft-builder"
        return chordProReviewState == .reviewed || !existingWasGenerated
    }

    /// The playback service currently backing `activePlaybackSource`. Every "act on whichever
    /// is active" call site should read/write through this instead of re-deriving
    /// `activePlaybackSource == .stemMix ? stemPlayback.x : playback.x`. Code that legitimately
    /// needs both services by name (e.g. the source hand-off in `toggleRecordingPlayback`/
    /// `toggleStemPlayback`, which pauses the outgoing one and seeks the incoming one) is
    /// exempt — it is inherently about the two named services, not "the active one."
    var activeClock: any PlaybackClock {
        activePlaybackSource == .stemMix ? stemPlayback : playback
    }

    var activePlaybackTime: TimeInterval { activeClock.currentTime }

    /// Playhead clock for lyric line highlight and the waveform — identical to audible playback
    /// (no ChordPro render-only timing offset).
    var lyricHighlightTime: TimeInterval { activePlaybackTime }

    var activePlaybackDuration: TimeInterval { activeClock.duration }

    /// Duration for lyric/chord timeline axes: prefer stored transcription length, else playback.
    var timelineDuration: TimeInterval {
        if let sourceDuration, sourceDuration > 0 { return sourceDuration }
        return activePlaybackDuration
    }

    var isActivePlaybackPlaying: Bool { activeClock.isPlaying }

    var canAnalyzeAccompaniment: Bool {
        guard let stemFiles else { return false }
        return FileManager.default.fileExists(
            atPath: (stemFiles.accompaniment ?? stemFiles.other).path
        )
    }

    var hasStaleStemPlayback: Bool {
        stemFiles != nil && analysisStageRecords[.separation]?.state == .stale
            && !stemPlayback.isLoaded
    }

    var includedChordEventCount: Int {
        chordEvents.filter(isChordIncludedInChordPro).count
    }

    var bassNoteChordProSource: String {
        guard selectedSong != nil || !lyricSegments.isEmpty || !chordEvents.isEmpty else {
            return ""
        }
        if !bassNotes.isEmpty {
            // Prefer the detected bass line: map each observation to a chord
            // event carrying the pitch-class label of the played bass note.
            let detectedEvents = bassNotes.map { observation in
                EditableChordEvent(
                    time: observation.timestamp,
                    chord: BassNoteNaming.name(forMidiNote: observation.midiNote),
                    confidence: observation.confidence
                )
            }
            return chordProBuilder.build(
                ChordProDraftInput(
                    title: selectedSong?.title ?? "Untitled",
                    tempo: estimatedBPM,
                    lyrics: lyricSegments,
                    chords: detectedEvents,
                    confidenceThreshold: chordConfidenceThreshold,
                    beatTimes: beatTimes
                ),
                comment: ChordProDraftBuilder.bassNoteDraftComment,
                chordLabel: { $0.chord }
            )
        }
        return chordProBuilder.build(
            ChordProDraftInput(
                title: selectedSong?.title ?? "Untitled",
                tempo: estimatedBPM,
                lyrics: lyricSegments,
                chords: chordEvents,
                confidenceThreshold: chordConfidenceThreshold,
                beatTimes: beatTimes
            ),
            comment: ChordProDraftBuilder.bassNoteDraftComment,
            chordLabel: { BassNote(chordSymbol: $0.chord)?.label }
        )
    }

    func isChordIncludedInChordPro(_ event: EditableChordEvent) -> Bool {
        event.confidence.map { $0 >= chordConfidenceThreshold } ?? true
    }

    func toggleActivePlayback() {
        switch activePlaybackSource {
        case .recording:
            toggleRecordingPlayback()
        case .stemMix:
            toggleStemPlayback()
        }
    }

    func toggleRecordingPlayback() {
        if activePlaybackSource == .stemMix {
            let sourceTime = stemPlayback.currentTime
            stemPlayback.pause()
            playback.seek(to: sourceTime)
        }
        activePlaybackSource = .recording
        playback.togglePlayback()
    }

    func toggleStemPlayback() {
        guard stemPlayback.isLoaded else { return }
        if activePlaybackSource == .recording {
            let sourceTime = playback.currentTime
            playback.pause()
            stemPlayback.seek(to: sourceTime)
        }
        activePlaybackSource = .stemMix
        stemPlayback.togglePlayback()
    }

    func seekActivePlayback(to time: TimeInterval) {
        activeClock.seek(to: time)
    }

    func skipActivePlayback(by interval: TimeInterval) {
        seekActivePlayback(to: min(max(activePlaybackTime + interval, 0), activePlaybackDuration))
    }

    func installModelPackage(_ descriptor: ModelPackageDescriptor) {
        modelInstallTasks[descriptor.id]?.cancel()
        modelInstallProgress[descriptor.id] = 0
        modelInstallTasks[descriptor.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await modelPackageManager.install(descriptor) { fraction in
                    Task { @MainActor [weak self] in
                        self?.modelInstallProgress[descriptor.id] = fraction
                    }
                }
                modelInstallProgress[descriptor.id] = nil
                modelPackageStatuses[descriptor.id] = await modelPackageManager.status(
                    for: descriptor
                )
                projectErrorMessage = nil
            } catch is CancellationError {
                modelInstallProgress[descriptor.id] = nil
            } catch {
                modelInstallProgress[descriptor.id] = nil
                projectErrorMessage =
                    "Could not install \(descriptor.displayName): \(error.localizedDescription)"
            }
            modelInstallTasks[descriptor.id] = nil
        }
    }

    func cancelModelPackageInstall(_ descriptor: ModelPackageDescriptor) {
        modelInstallTasks[descriptor.id]?.cancel()
    }

    func removeModelPackage(_ descriptor: ModelPackageDescriptor) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await modelPackageManager.remove(descriptor)
                modelPackageStatuses[descriptor.id] = .available
                projectErrorMessage = nil
            } catch {
                projectErrorMessage =
                    "Could not remove \(descriptor.displayName): \(error.localizedDescription)"
            }
        }
    }

    func verifyModelPackage(_ descriptor: ModelPackageDescriptor) {
        Task { [weak self] in
            guard let self else { return }
            modelPackageStatuses[descriptor.id] = await modelPackageManager.status(for: descriptor)
        }
    }

    func analyzeSelectedSong(replaceExistingChordPro: Bool = false) {
        guard let song = selectedSong else { return }
        runAnalysis(
            for: song,
            stages: Set(SongAnalysisStage.allCases),
            replaceExistingChordPro: replaceExistingChordPro,
            runLyricBlend: true
        )
    }

    /// Transcription modes whose engine is currently installed — used to pick the primary mode
    /// and to decide which Lyric Blend passes (backlog #11) are worth attempting. Reflects
    /// `modelPackageStatuses`, which the model-package manager keeps current.
    private var availableTranscriptionModes: Set<TranscriptionMode> {
        var modes: Set<TranscriptionMode> = []
        if case .installed = modelPackageStatuses[ModelCatalog.parakeetFastDraft.id] {
            modes.insert(.fastDraft)
            modes.insert(.balancedDraft)
        }
        if case .installed = modelPackageStatuses[ModelCatalog.whisperAccuracy.id] {
            modes.insert(.accuracy)
        }
        return modes
    }

    /// The mode used for a song's OFFICIAL lyrics/ChordPro before any Lyric Blend pick — prefers
    /// Accuracy (best quality), then Balanced, then Fast Draft, falling back to Accuracy when
    /// nothing is installed yet so the existing "install the model" error still surfaces exactly
    /// as it does today. There is no more user-facing mode picker (backlog #11 drops it in favor
    /// of always running every installed mode and letting the blend UI be the tuning).
    private var primaryTranscriptionMode: TranscriptionMode {
        let available = availableTranscriptionModes
        return LyricBlendRowBuilder.modeOrder.first { available.contains($0) } ?? .accuracy
    }

    /// Re-aligns the lyrics to the audio from the current `referenceLyrics` by re-running the
    /// transcription stage (re-groups + aligns from the cached raw transcription — no
    /// re-transcription) and rebuilding the ChordPro chart. With empty reference lyrics this
    /// reverts to the raw ASR lines.
    func applyReferenceLyrics() {
        guard let song = selectedSong else { return }
        runAnalysis(
            for: song,
            stages: [.transcription, .chordPro],
            replaceExistingChordPro: true
        )
    }

    /// The current lyric lines as plain text, one line per segment. Used to seed the reference
    /// lyrics from a good transcription (e.g. an Accuracy run): Parakeet (Fast/Balanced) has the
    /// same words but no line structure, so promoting the better mode's lines to the reference and
    /// re-aligning gives the quick modes the same line breaks.
    var currentLyricsAsText: String {
        lyricSegments.map(\.text).joined(separator: "\n")
    }

    /// Re-analyzes EVERY song in the library, sequentially. Each song runs all stages, but the
    /// disk cache makes this cheap where possible: already-separated songs skip the slow stem
    /// separation (cache hit), and transcription/harmony re-run from their cached raw results to
    /// pick up grouping/chord improvements. Songs never analyzed before get a full first-time
    /// analysis (including separation). Every song always uses the same dynamic primary-mode
    /// selection (see `primaryTranscriptionMode`) — there's no more per-song remembered mode now
    /// that mode is no longer a user choice (backlog #11).
    ///
    /// Deliberately does NOT run Lyric Blend's extra passes here — tripling transcription cost
    /// for the WHOLE library on every bulk re-analyze is a much bigger cost/UX tradeoff than the
    /// single-song case and deserves its own decision if wanted later. Re-selecting a song after
    /// a bulk re-analyze and running Analyze again on it individually will populate its blend
    /// candidates.
    func reanalyzeAllSongs() {
        guard !isSongAnalysisRunning else { return }
        reanalyzeNext(in: songs, total: songs.count)
    }

    private func reanalyzeNext(in queue: [Song], total: Int) {
        guard let song = queue.first else {
            reanalyzeAllStatus = nil
            return
        }
        reanalyzeAllStatus = ReanalyzeAllStatus(
            index: total - queue.count + 1, total: total, title: song.title)
        runAnalysis(
            for: song,
            stages: Set(SongAnalysisStage.allCases)
        ) { [weak self] cancelled in
            guard let self, !cancelled else {
                self?.reanalyzeAllStatus = nil
                return
            }
            reanalyzeNext(in: Array(queue.dropFirst()), total: total)
        }
    }

    private func runAnalysis(
        for song: Song,
        stages: Set<SongAnalysisStage>,
        replaceExistingChordPro: Bool = false,
        runLyricBlend: Bool = false,
        completion: ((_ cancelled: Bool) -> Void)? = nil
    ) {
        guard !stages.isEmpty else {
            completion?(false)
            return
        }
        // Detection-only guard for cloud-stored sources (iCloud / Google Drive / network or
        // removable volumes): such files are often online-only/dataless or refuse a direct
        // open() with EPERM, which otherwise produces a silent no-stems analysis. Verify the
        // source is readable first; on failure surface a clear, actionable message (and kick
        // off an iCloud download) and abort so nothing is half-written — the user retries once
        // the file is available.
        isSongAnalysisRunning = true
        songAnalysisProgress = SongAnalysisPipelineProgress(
            stage: nil, completedStages: 0, totalStages: stages.count,
            stageFraction: 0, message: "Checking source file")
        let sourceURL = song.url
        Task { [weak self] in
            let availability = await Task.detached(priority: .userInitiated) {
                AppModel.sourceAvailability(of: sourceURL)
            }.value
            guard let self else { return }
            switch availability {
            case .available:
                self.beginAnalysis(
                    for: song, stages: stages,
                    replaceExistingChordPro: replaceExistingChordPro,
                    runLyricBlend: runLyricBlend, completion: completion)
            case .unavailable(let message):
                self.isSongAnalysisRunning = false
                self.projectErrorMessage = message
                completion?(false)
            }
        }
    }

    private enum SourceAvailability: Sendable {
        case available
        case unavailable(String)
    }

    /// Detects whether a source audio file can actually be read right now. Cloud-provider files
    /// (iCloud, Google Drive, network/removable volumes) are frequently online-only/dataless or
    /// refuse a direct `open()` with EPERM; analyzing them silently yields no stems. Runs off the
    /// main actor.
    nonisolated private static func sourceAvailability(of url: URL) -> SourceAvailability {
        let name = url.lastPathComponent
        // iCloud: if the item exists but isn't downloaded, request the download and ask the user
        // to retry once it lands.
        if let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true {
            if values.ubiquitousItemDownloadingStatus != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return .unavailable(
                    "“\(name)” is stored in iCloud and isn’t downloaded yet. I’ve started "
                        + "downloading it — once it finishes, run Analyze again.")
            }
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return .available
        } catch {
            let nsError = error as NSError
            let isPermission =
                (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPERM))
                || (nsError.domain == NSCocoaErrorDomain
                    && nsError.code == NSFileReadNoPermissionError)
            if isPermission {
                return .unavailable(
                    "“\(name)” couldn’t be opened (operation not permitted). It looks like it’s on "
                        + "a cloud or removable volume that isn’t available right now. Make it "
                        + "available offline (or copy it to a local folder) and try Analyze again.")
            }
            return .unavailable(
                "“\(name)” couldn’t be read: \(error.localizedDescription) Make sure the file is "
                    + "available locally and try Analyze again.")
        }
    }

    private func beginAnalysis(
        for song: Song,
        stages: Set<SongAnalysisStage>,
        replaceExistingChordPro: Bool = false,
        runLyricBlend: Bool = false,
        completion: ((_ cancelled: Bool) -> Void)? = nil
    ) {
        let songID = song.id
        let existingDocument = analysisBySongID[songID] ?? SongAnalysisDocument()
        isSongAnalysisRunning = true
        songAnalysisProgress = SongAnalysisPipelineProgress(
            stage: nil,
            completedStages: 0,
            totalStages: stages.count,
            stageFraction: 0,
            message: "Preparing analysis"
        )
        let request = SongAnalysisPipelineRequest(
            sourceURL: song.url,
            outputDirectory: analysisOutputDirectory(for: songID),
            title: song.title,
            stages: stages,
            transcriptionMode: primaryTranscriptionMode,
            existingDocument: existingDocument,
            chordProReplacementPolicy: replaceExistingChordPro
                ? .replaceExisting : .preserveExisting,
            transcriptionDecodeRate: min(max(accuracyDecodeSpeed, 0.75), 1.0)
        )
        analysisCoordinator.run(
            request: request,
            onStatuses: { [weak self] statuses in
                for (id, status) in statuses { self?.modelPackageStatuses[id] = status }
            },
            onProgress: { [weak self] value in
                guard self?.isSongAnalysisRunning == true else { return }
                self?.songAnalysisProgress = value
            },
            onFinish: { [weak self] outcome in
                guard let self else { return }
                var cancelled = false
                switch outcome {
                case .success(let result):
                    // Carry forward any manual chord drag / lyric-line correction / accept flag
                    // from the PREVIOUS analysis onto whichever freshly-detected segment/chord now
                    // occupies the same time (backlog #15 Phase 2) — otherwise a re-analysis
                    // silently discards edits made in the Review chart, defeating the whole point
                    // of them surviving re-analysis.
                    var document = result.document
                    document.lyrics = TimedLyricSegment.reconciled(
                        newSegments: document.lyrics, against: existingDocument.lyrics)
                    document.chords = EditableChordEvent.reconciled(
                        newEvents: document.chords, against: existingDocument.chords)
                    analysisBySongID[songID] = document
                    if selectedSongID == songID {
                        applyAnalysis(document)
                        // A fresh analysis may have just produced the stems; the
                        // waveform-derived state (stem lanes + vocal-activity overlay)
                        // is otherwise only loaded in select(), so refresh it here or a
                        // newly analyzed song shows an empty stem panel until reselected.
                        if let song = selectedSong {
                            loadVocalActivity(for: song)
                            loadStemWaveforms(for: song)
                        }
                    }
                    // Always persist the freshly computed analysis (applyAnalysis only
                    // persists when it detects a migration change, which a fresh result
                    // often isn't).
                    scheduleSave()
                    isSongAnalysisRunning = false
                    cancelled = result.wasCancelled
                    if !result.wasCancelled {
                        projectErrorMessage = nil
                    }
                    if runLyricBlend, !result.wasCancelled, stages.contains(.transcription) {
                        runLyricBlendPasses(for: song, primaryDocument: result.document)
                    }
                case .failure(let error):
                    isSongAnalysisRunning = false
                    cancelled = error is CancellationError
                    if !(error is CancellationError) {
                        projectErrorMessage =
                            "Could not analyze song: \(error.localizedDescription)"
                    }
                }
                completion?(cancelled)
            }
        )
    }

    /// After a full analysis completes, independently re-runs transcription in the OTHER
    /// installed modes (whichever of Fast/Balanced/Accuracy weren't the primary mode) so the
    /// "Lyric Blend" window has real candidates from every available mode (backlog #11). Runs
    /// sequentially, not concurrently: `SongAnalysisCoordinator` cancels any in-flight run when
    /// `.run` is called again, so a second overlapping call here would cancel the first. Each
    /// pass only requests `.transcription`, so harmony/chords/stems already in `primaryDocument`
    /// are carried through untouched, and each pass's own per-mode cache key (`AnalysisStage`)
    /// makes an unchanged-audio re-blend cheap on a later analysis. A mode whose model isn't
    /// installed, or a pass that fails for any reason, is skipped — Lyric Blending degrades to
    /// fewer candidates rather than disturbing the analysis that already succeeded.
    private func runLyricBlendPasses(for song: Song, primaryDocument: SongAnalysisDocument) {
        let songID = song.id
        let available = availableTranscriptionModes
        let primaryMode = primaryTranscriptionMode
        let otherModes = LyricBlendRowBuilder.modeOrder.filter {
            $0 != primaryMode && available.contains($0)
        }
        guard !otherModes.isEmpty else { return }

        isComputingLyricBlend = true
        Task { [weak self] in
            guard let self else { return }
            // Whatever path exits this task, the status line must clear — a stuck
            // "Preparing…" is worse than none.
            defer {
                self.lyricBlendStatus = nil
                self.isComputingLyricBlend = false
            }
            var lyricsByMode: [TranscriptionMode: [TimedLyricSegment]] = [
                primaryMode: primaryDocument.lyrics
            ]
            for (index, mode) in otherModes.enumerated() {
                self.lyricBlendStatus =
                    "Preparing Lyric Blend — \(Self.blendModeLabel(mode)) pass "
                    + "(\(index + 1) of \(otherModes.count))…"
                if let segments = await self.runSingleTranscriptionPass(
                    for: song, mode: mode, existingDocument: primaryDocument)
                {
                    lyricsByMode[mode] = segments
                }
            }
            self.lyricBlendStatus = "Preparing Lyric Blend — matching lines to the vocal stem…"
            // The song may have been removed from the library while these passes ran.
            guard self.analysisBySongID[songID] != nil else { return }

            let freshRows = LyricBlendRowBuilder.buildRows(
                fastDraft: lyricsByMode[.fastDraft] ?? [],
                balancedDraft: lyricsByMode[.balancedDraft] ?? [],
                accuracy: lyricsByMode[.accuracy] ?? [])
            // Nothing to blend (e.g. every other mode's pass failed) — don't open a blend window
            // with only one column and nothing to pick between.
            guard freshRows.contains(where: { $0.candidates.count > 1 }) else { return }

            var updated = self.analysisBySongID[songID] ?? primaryDocument
            // Carry forward any manual override/mode pick from the PREVIOUS blend rows onto
            // whichever freshly-built row now occupies the same time window — otherwise a
            // re-analysis silently discards a user's correction, which is exactly what a
            // consistently-misheard-lyric override exists to survive.
            let reconciledRows = LyricBlendRowBuilder.reconciled(
                newRows: freshRows, against: updated.lyricBlendRows)
            // The vocal stem is ground truth for word placement (every sung burst ↔ a word):
            // where the stem's energy onsets clearly corroborate a non-default candidate's
            // timing, prefer it for rows the user hasn't picked — engine timing disagreements
            // (the duplicated-line class of bugs) then resolve toward the audio itself.
            // Detection runs off the main actor; a missing stem degrades to no change.
            let vocalsURL = updated.stems?.resolved().vocals
            let vocalOnsets: [TimeInterval] = await Task.detached(priority: .utility) {
                guard let vocalsURL else { return [] }
                return (try? InstrumentOnsetDetector.onsets(url: vocalsURL)) ?? []
            }.value
            // A candidate that runs a neighbour's line together with this row's line is a
            // timing artifact, not a longer line — prefer the split candidate (field case:
            // "line 9 is actually 2 lines").
            let rows = LyricBlendRowBuilder.runOnDuplicatesDemoted(
                LyricBlendRowBuilder.onsetCorroborated(
                    reconciledRows, vocalOnsets: vocalOnsets))
            updated.lyricBlendRows = rows
            let oldLyrics = updated.lyrics
            updated.lyrics = TimedLyricSegment.reconciled(
                newSegments: LyricBlendRowBuilder.effectiveLyrics(from: rows), against: oldLyrics)
            // The chart must follow the lyrics: this overwrite previously left the GENERATED
            // ChordPro draft stale, so the chart kept showing pre-blend run-on lines after
            // the lyric list was already fixed (field case: chart line 12 "settle down,
            // trading my rowdy friends…"). Same guards as `rebuildGeneratedChordProDraft`:
            // only an unreviewed, generator-produced draft is rebuilt.
            if updated.stageRecords[.chordPro]?.state == .succeeded,
                updated.stageRecords[.chordPro]?.provenance?.engineIdentifier
                    == "chordpro-draft-builder",
                updated.chordProReviewState != .reviewed
            {
                self.lyricBlendStatus = "Preparing Lyric Blend — rebuilding chart…"
                updated.chordProSource = self.chordProBuilder.build(
                    ChordProDraftInput(
                        title: song.title,
                        tempo: updated.estimatedBPM,
                        lyrics: updated.lyrics,
                        chords: updated.chords,
                        confidenceThreshold: updated.chordConfidenceThreshold,
                        beatTimes: updated.beatTimes,
                        sourceDuration: updated.sourceDuration,
                        estimatedKey: updated.estimatedKey
                    ))
            }
            self.analysisBySongID[songID] = updated
            if self.selectedSongID == songID {
                self.applyAnalysis(updated)
            }
            self.scheduleSave()
            self.lyricBlendReadySongID = songID
        }
    }

    /// Short human label for a transcription mode in the background status line.
    private static func blendModeLabel(_ mode: TranscriptionMode) -> String {
        switch mode {
        case .fastDraft: "Fast"
        case .balancedDraft: "Balanced"
        case .accuracy: "Accuracy"
        }
    }

    /// Runs ONE transcription-only pass in `mode` via the coordinator, returning its resulting
    /// lyric lines (or `nil` on failure/cancellation) without touching any other published
    /// analysis state — the caller decides what to do with the result. Used by
    /// `runLyricBlendPasses` to gather each non-primary mode's candidate.
    private func runSingleTranscriptionPass(
        for song: Song, mode: TranscriptionMode, existingDocument: SongAnalysisDocument
    ) async -> [TimedLyricSegment]? {
        await withCheckedContinuation { continuation in
            let request = SongAnalysisPipelineRequest(
                sourceURL: song.url,
                outputDirectory: analysisOutputDirectory(for: song.id),
                title: song.title,
                stages: [.transcription],
                transcriptionMode: mode,
                existingDocument: existingDocument,
                chordProReplacementPolicy: .preserveExisting,
                transcriptionDecodeRate: min(max(accuracyDecodeSpeed, 0.75), 1.0)
            )
            analysisCoordinator.run(
                request: request,
                onStatuses: { [weak self] statuses in
                    for (id, status) in statuses { self?.modelPackageStatuses[id] = status }
                },
                onProgress: { _ in },
                onFinish: { outcome in
                    switch outcome {
                    case .success(let result):
                        continuation.resume(
                            returning: result.wasCancelled ? nil : result.document.lyrics)
                    case .failure:
                        continuation.resume(returning: nil)
                    }
                }
            )
        }
    }

    /// Records the user's pick for one Lyric Blend row (backlog #11) and rebuilds the effective
    /// lyrics from every row's current pick (this row's new one, every other row's existing pick
    /// or its default) for the CURRENTLY SELECTED song — the Lyric Blend window always reflects
    /// the selected song's live, reactive `lyricBlendRows`/`lyricSegments` rather than being
    /// pinned to whichever song it was opened for (deliberately simpler than a per-song window:
    /// `analysisBySongID` is a plain cache, not `@Published`, so a window bound to a
    /// non-selected song's cached document wouldn't update live anyway). Goes through the same
    /// `lyricSegments` `didSet` every other lyric edit uses, so ChordPro regeneration and
    /// persistence stay consistent.
    func applyLyricBlendSelection(rowID: UUID, mode: TranscriptionMode) {
        guard let index = lyricBlendRows.firstIndex(where: { $0.id == rowID }) else { return }
        lyricBlendRows[index].selectedMode = mode
        lyricSegments = LyricBlendRowBuilder.effectiveLyrics(from: lyricBlendRows)
    }

    /// Records a manual override for one Lyric Blend row — a "4th candidate" the user types in
    /// for a line that's consistently misheard by every transcription mode. An override takes
    /// precedence over every ASR candidate (`LyricBlendRow.effectiveText`), and — unlike a mode
    /// pick alone — is explicitly carried forward across re-analysis by
    /// `LyricBlendRowBuilder.reconciled` in `runLyricBlendPasses`, so it survives the rows being
    /// rebuilt from scratch. Passing whitespace-only or empty text clears the override (falls
    /// back to the mode pick/default candidate), rather than persisting a blank line.
    func applyLyricBlendOverride(rowID: UUID, text: String) {
        guard let index = lyricBlendRows.firstIndex(where: { $0.id == rowID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lyricBlendRows[index].overrideText = trimmed.isEmpty ? nil : text
        lyricSegments = LyricBlendRowBuilder.effectiveLyrics(from: lyricBlendRows)
    }

    /// Toggles a chord event's Review-chart "accepted" flag, by id (backlog #15 Phase 2
    /// remainder — chart interactivity). A no-op if the id isn't found, e.g. a stale tap racing
    /// a fast re-analysis that already replaced the event.
    func toggleChordAccepted(id: EditableChordEvent.ID) {
        guard let index = chordEvents.firstIndex(where: { $0.id == id }) else { return }
        chordEvents[index].accepted.toggle()
    }

    /// Sets (or clears, when `nil`) a chord event's dragged Review-chart position. Deliberately a
    /// FREE timestamp with no snapping — see `EditableChordEvent.manualTime`'s doc comment.
    func setChordManualTime(id: EditableChordEvent.ID, manualTime: TimeInterval?) {
        guard let index = chordEvents.firstIndex(where: { $0.id == id }) else { return }
        chordEvents[index].manualTime = manualTime
    }

    /// Toggles a lyric segment's Review-chart "accepted" flag, by id.
    func toggleLyricAccepted(id: TimedLyricSegment.ID) {
        guard let index = lyricSegments.firstIndex(where: { $0.id == id }) else { return }
        lyricSegments[index].accepted.toggle()
    }

    /// Records a manual correction typed directly into the Review chart for one lyric line, by
    /// id — mirrors `applyLyricBlendOverride`'s trim/clear convention. Unlike the Lyric Blend
    /// override, this does not rebuild `lyricSegments` from a row builder (there isn't one here);
    /// it edits the matching segment in place.
    func setLyricOverrideText(id: TimedLyricSegment.ID, text: String) {
        guard let index = lyricSegments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lyricSegments[index].overrideText = trimmed.isEmpty ? nil : text
    }

    func retryAnalysisStage(_ stage: SongAnalysisStage) {
        guard let song = selectedSong else { return }
        runAnalysis(for: song, stages: [stage])
    }

    func cancelSongAnalysis() {
        analysisCoordinator.cancel()
    }

    func importSongs(from urls: [URL]) {
        // Expand dropped/selected folders into their audio files before importing.
        let candidates = SongImportPolicy.expandingDirectories(urls)
        let imported = SongImportPolicy.songs(from: candidates)
        if imported.isEmpty, !urls.isEmpty {
            projectErrorMessage = "No supported audio files were found."
            return
        } else if imported.count < candidates.count {
            projectErrorMessage = "Some files use unsupported audio formats."
        }
        // Copy each source into local app storage and import the LOCAL copy, so analysis never
        // depends on a cloud provider (iCloud / Google Drive) that serves online-only files or
        // refuses a direct open() with EPERM. iCloud items are downloaded first. A single
        // deliberate import is auto-selected; bulk/folder imports only auto-select when nothing
        // is selected yet.
        let selectImmediately = urls.count == 1
        Task { [weak self] in
            guard let self else { return }
            var localizedSongs: [Song] = []
            var firstFailure: String?
            for (index, song) in imported.enumerated() {
                // Surface the copy/download step — an iCloud item can take a while to
                // materialize and the song only appears in the list afterwards.
                self.importStatus =
                    imported.count == 1
                    ? "Importing “\(song.title)”…"
                    : "Importing \(index + 1) of \(imported.count): \(song.title)…"
                switch await AppModel.localizedSource(for: song.url) {
                case .success(let localURL):
                    localizedSongs.append(Song(url: localURL))
                case .failure(let reason):
                    if firstFailure == nil { firstFailure = reason }
                }
            }
            self.importStatus = nil
            let existingIDs = Set(self.songs.map(\.id))
            let newSongs = localizedSongs.filter { !existingIDs.contains($0.id) }
            self.songs.append(contentsOf: newSongs)
            self.songs.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if let first = newSongs.first, selectImmediately || self.selectedSongID == nil {
                self.select(first)
            }
            if let firstFailure { self.projectErrorMessage = firstFailure }
            self.scheduleSave()
            // Newly imported songs go straight into analysis (sequentially for bulk
            // imports), so a fresh song is ready to practice without another click.
            if !newSongs.isEmpty, !self.isSongAnalysisRunning {
                self.reanalyzeNext(in: newSongs, total: newSongs.count)
            }
        }
    }

    /// Local directory holding imported source copies, so analysis operates on files the app can
    /// always read regardless of any originating cloud provider.
    nonisolated private static func localSourcesDirectory() -> URL? {
        guard
            let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
        else { return nil }
        return
            appSupport
            .appendingPathComponent("SongWorkbench", isDirectory: true)
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private enum LocalizedSourceOutcome: Sendable {
        case success(URL)
        case failure(String)
    }

    /// Returns a LOCAL, readable URL for an imported source: the file is copied into the app's
    /// local Sources directory (materializing an iCloud item first) so later analysis never has to
    /// open the original cloud path. Files already inside the local Sources directory are returned
    /// as-is. Runs off the main actor.
    nonisolated private static func localizedSource(for url: URL) async -> LocalizedSourceOutcome {
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        guard let sourcesDirectory = localSourcesDirectory() else {
            return .failure("Couldn’t locate local storage for imported songs.")
        }
        // Already a local copy — nothing to do.
        if url.standardizedFileURL.path.hasPrefix(sourcesDirectory.standardizedFileURL.path) {
            return .success(url)
        }
        // Materialize an iCloud item before copying (online-only files can't be read directly).
        if let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true,
            values.ubiquitousItemDownloadingStatus != .current
        {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let status = try? url.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]
                ).ubiquitousItemDownloadingStatus, status == .current {
                    break
                }
            }
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Key the destination folder by the resolved original path so re-importing the same file
        // reuses the copy instead of duplicating it.
        let identifier = SHA256.hash(
            data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8)
        ).map { String(format: "%02x", $0) }.joined()
        let destinationDirectory = sourcesDirectory.appendingPathComponent(
            identifier, isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                return .success(destination)
            }
            try fileManager.copyItem(at: url, to: destination)
            return .success(destination)
        } catch {
            return .failure(
                "“\(name)” couldn’t be copied to local storage: \(error.localizedDescription) "
                    + "If it’s in iCloud or Google Drive, make it available offline and re-import.")
        }
    }

    /// Loads the Music library on first open of the picker. Reads happen off the
    /// main actor because enumerating a large library is slow; the iTunesLibrary
    /// access triggers the macOS Media authorization prompt on first use.
    func loadMusicLibraryIfNeeded() {
        guard musicLibraryItems.isEmpty, !isLoadingMusicLibrary else { return }
        loadMusicLibrary()
    }

    func loadMusicLibrary() {
        isLoadingMusicLibrary = true
        musicLibraryError = nil
        let provider = musicLibrary
        Task { [weak self] in
            do {
                let items = try await Task.detached { try provider.fetchSongs() }.value
                await MainActor.run {
                    self?.musicLibraryItems = items
                    self?.isLoadingMusicLibrary = false
                }
            } catch {
                await MainActor.run {
                    self?.musicLibraryError =
                        "Couldn't read your Music library: \(error.localizedDescription)"
                    self?.isLoadingMusicLibrary = false
                }
            }
        }
    }

    /// Opens a Music-library track. An openable local file is funneled through
    /// the exact same import path as a dropped/selected file, so every
    /// downstream feature (playback, pitch, tempo, waveform, stems, lyrics,
    /// chords, export, persistence) works identically. DRM/cloud tracks set a
    /// friendly notice and load nothing.
    @discardableResult
    func openMusicLibraryItem(_ item: MusicLibraryItem) -> Bool {
        guard case .openable(let url) = item.openability() else {
            let reason = item.unopenableReason ?? "This track can't be opened."
            musicLibraryNotice = "“\(item.title)” can't be opened. \(reason)"
            return false
        }
        // importSongs copies the track into local storage and auto-selects a single import, so the
        // song's final id is the LOCAL copy's — no post-hoc select by the original URL is needed.
        importSongs(from: [url])
        musicLibraryNotice = nil
        isMusicLibraryPickerPresented = false
        return true
    }

    func handleSongImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importSongs(from: urls)
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            return
        case .failure(let error):
            projectErrorMessage = "Could not import songs: \(error.localizedDescription)"
        }
    }

    func removeSong(_ song: Song) {
        let removedSelectedSong = selectedSongID == song.id
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }

        songs.remove(at: index)
        settingsBySongID.removeValue(forKey: song.id)
        analysisBySongID.removeValue(forKey: song.id)
        lastOpenedBySongID.removeValue(forKey: song.id)

        if removedSelectedSong {
            clearSelectedSongState()
            if !songs.isEmpty {
                select(songs[min(index, songs.count - 1)])
                return
            }
        }

        scheduleSave()
    }

    func select(_ song: Song) {
        resetSelectedSongProgressState()
        stemPlayback.unload()
        activePlaybackSource = .recording
        selectedSongID = song.id
        lastOpenedBySongID[song.id] = Date()
        playback.load(song.url)
        applySettings(settingsBySongID[song.id] ?? PracticeSettings())
        applyAnalysis(analysisBySongID[song.id] ?? SongAnalysisDocument())
        loadWaveform(for: song)
        loadVocalActivity(for: song)
        loadStemWaveforms(for: song)
        scheduleSave()
    }

    private var typeaheadBuffer = ""
    private var typeaheadLastKeyAt = Date.distantPast

    /// Type-to-select: selects the first song whose title starts with the accumulating typed prefix.
    /// Characters typed within `resetInterval` extend the current prefix; a longer pause (or an
    /// extended prefix that matches nothing) restarts from the new character. Returns true when the
    /// keystroke selected/matched a song (so the caller can mark it handled).
    @discardableResult
    func typeToSelect(_ characters: String, resetInterval: TimeInterval = 0.8) -> Bool {
        let now = Date()
        if now.timeIntervalSince(typeaheadLastKeyAt) > resetInterval { typeaheadBuffer = "" }
        typeaheadLastKeyAt = now
        for candidate in [typeaheadBuffer + characters, characters] {
            if let match = SongTypeahead.firstMatch(prefix: candidate, in: songs) {
                typeaheadBuffer = candidate
                if match.id != selectedSongID { select(match) }
                return true
            }
        }
        return false
    }

    private func resetSelectedSongProgressState() {
        analysisCoordinator.cancel()
        isSongAnalysisRunning = false
        songAnalysisProgress = nil

        analysisControlTask?.cancel()
        analysisControlTask = nil
        analysisMonitorTask?.cancel()
        analysisMonitorTask = nil
        analysisJobSnapshot = nil

        if let jobID = currentAnalysisJobID {
            currentAnalysisJobID = nil
            Task { [analysisJobs] in
                await analysisJobs.cancel(jobID)
                while let snapshot = await analysisJobs.snapshot(for: jobID),
                    !snapshot.state.isTerminal
                {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                await analysisJobs.discard(jobID)
            }
        }

        waveformTask?.cancel()
        waveformTask = nil
        waveform = nil
        isLoadingWaveform = false
        vocalActivityTask?.cancel()
        vocalActivityTask = nil
        vocalActivityIntervals = []
        vocalWaveform = nil
        stemWaveformsTask?.cancel()
        stemWaveformsTask = nil
        stemWaveforms = []
    }

    private func clearSelectedSongState() {
        resetSelectedSongProgressState()
        playback.unload()
        stemPlayback.unload()
        activePlaybackSource = .recording
        selectedSongID = nil
        loopRegion = nil
        lyricSegments = []
        untranscribedVocalRegions = []
        chordEvents = []
        chordProSource = ""
        estimatedBPM = nil
        beatTimes = []
        bassNotes = []
        estimatedKey = nil
        chordConfidenceThreshold = 0.5
        stemFiles = nil
        stemMixer = StemMixerModel()
        lyricReviewState = .draft
        chordReviewState = .draft
        chordProReviewState = .draft
        analysisStageRecords = [:]
    }

    func setLoop(start: TimeInterval, end: TimeInterval) {
        loopRegion = LoopRegion(start: start, end: end)
    }

    func clearLoop() {
        loopRegion = nil
    }

    /// Whether a loop region is set and can be played.
    var canPlayLoop: Bool { loopRegion != nil }

    /// Whether a loop region is set and playback is currently running (looping it).
    var isLoopPlaying: Bool { loopRegion != nil && isActivePlaybackPlaying }

    /// Starts playback at the loop region's start; playback then loops within the region
    /// (the playback service seeks back to the start when it reaches the end).
    func playLoopRegion() {
        guard let loopRegion else { return }
        seekActivePlayback(to: loopRegion.start)
        if !isActivePlaybackPlaying {
            toggleActivePlayback()
        }
    }

    func exportSelectedSong(to destinationURL: URL) {
        guard let song = selectedSong else { return }
        exportTask?.cancel()
        let exportID = UUID()
        currentExportID = exportID
        isExporting = true
        exportProgress = 0
        let settings = OfflineExportSettings(
            pitchSemitones: pitchSemitones,
            tempoRate: tempoRate
        )
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await offlineExporter.export(
                    sourceURL: song.url,
                    destinationURL: destinationURL,
                    settings: settings
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.currentExportID == exportID else { return }
                        self?.exportProgress = progress
                    }
                }
                guard !Task.isCancelled, currentExportID == exportID else { return }
                isExporting = false
                exportProgress = 1
                currentExportID = nil
                projectErrorMessage = nil
            } catch is CancellationError {
                guard currentExportID == exportID else { return }
                isExporting = false
                currentExportID = nil
            } catch {
                guard currentExportID == exportID else { return }
                isExporting = false
                currentExportID = nil
                projectErrorMessage = "Could not export audio: \(error.localizedDescription)"
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        currentExportID = nil
        isExporting = false
    }

    func runChordAnalysis() {
        guard let song = selectedSong else { return }
        let source: HarmonyAudioSource
        do {
            source = try HarmonyAudioSourceSelector().select(
                recordingURL: song.url,
                stems: stemFiles,
                allowsRecordingFallback: false
            )
        } catch {
            projectErrorMessage = error.localizedDescription
            return
        }
        analysisControlTask?.cancel()
        analysisControlTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let previousJobID = currentAnalysisJobID {
                    await analysisJobs.cancel(previousJobID)
                    while let snapshot = await analysisJobs.snapshot(for: previousJobID),
                        !snapshot.state.isTerminal
                    {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    await analysisJobs.discard(previousJobID)
                }
                let songID = song.id
                let sourceURL = source.url
                let engine = AnalysisEngineVersion(
                    identifier: "native-vdsp-beat-chroma|\(source.configurationIdentifier)",
                    version: "2|schema-\(SongAnalysisDocument.currentSchemaVersion)"
                )
                let jobID = try await analysisJobs.submit { [weak self] reporter in
                    guard let self else { throw CancellationError() }
                    await reporter.report(
                        BackgroundJobProgress(
                            completedUnits: 0,
                            totalUnits: 3,
                            message: "Hashing source"
                        ))
                    let accessing = sourceURL.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { sourceURL.stopAccessingSecurityScopedResource() }
                    }
                    let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                    try Task.checkCancellation()

                    let result: SongAudioAnalysis
                    let loadedFromCache: Bool
                    if let cached: SongAudioAnalysis = try await analysisCache.value(
                        for: sourceData,
                        engine: engine
                    ) {
                        result = cached
                        loadedFromCache = true
                        await reporter.report(
                            BackgroundJobProgress(
                                completedUnits: 2,
                                totalUnits: 3,
                                message: "Loaded cached analysis"
                            ))
                    } else {
                        loadedFromCache = false
                        await reporter.report(
                            BackgroundJobProgress(
                                completedUnits: 1,
                                totalUnits: 3,
                                message: "Analyzing beat and harmony"
                            ))
                        result = try await audioAnalysisService.analyze(url: sourceURL)
                        try await analysisCache.store(result, for: sourceData, engine: engine)
                    }
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.applyAudioAnalysis(
                            result,
                            for: songID,
                            source: source,
                            sourceDigest: SHA256.hash(data: sourceData).map {
                                String(format: "%02x", $0)
                            }.joined(),
                            loadedFromCache: loadedFromCache
                        )
                    }
                    await reporter.report(
                        BackgroundJobProgress(
                            completedUnits: 3,
                            totalUnits: 3,
                            message: "Analysis complete"
                        ))
                }
                currentAnalysisJobID = jobID
                monitorAnalysisJob(jobID)
            } catch is CancellationError {
                return
            } catch {
                projectErrorMessage = "Could not start analysis: \(error.localizedDescription)"
            }
        }
    }

    func cancelChordAnalysis() {
        guard let currentAnalysisJobID else { return }
        Task { await analysisJobs.cancel(currentAnalysisJobID) }
    }

    func importStems(from directoryURL: URL) throws {
        let accessing = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { directoryURL.stopAccessingSecurityScopedResource() }
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        func file(for kind: StemKind) throws -> URL {
            guard
                let url = contents.first(where: {
                    $0.deletingPathExtension().lastPathComponent.lowercased() == kind.rawValue
                        && SongImportPolicy.accepts($0)
                })
            else {
                throw StemImportError.missingStem(kind)
            }
            return url
        }
        func optionalFile(for kind: StemKind) -> URL? {
            contents.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == kind.rawValue
                    && SongImportPolicy.accepts($0)
            })
        }
        stemFiles = try StemFiles(
            vocals: file(for: .vocals),
            drums: file(for: .drums),
            bass: file(for: .bass),
            guitar: optionalFile(for: .guitar),
            piano: optionalFile(for: .piano),
            other: file(for: .other)
        )
        if let stemFiles {
            try stemPlayback.load(stemFiles, mixer: stemMixer)
            stemPlayback.loadClickTrack(beatTimes: beatTimes)
            stemPlayback.setPitch(semitones: pitchSemitones)
            stemPlayback.setTempo(rate: tempoRate)
        }
    }

    func setStemGain(_ gain: Float, for kind: StemKind) {
        stemMixer.setGain(gain, for: kind)
        stemPlayback.apply(stemMixer)
    }

    func setStemMuted(_ muted: Bool, for kind: StemKind) {
        stemMixer.setMuted(muted, for: kind)
        stemPlayback.apply(stemMixer)
    }

    func setStemSoloed(_ soloed: Bool, for kind: StemKind) {
        stemMixer.setSoloed(soloed, for: kind)
        stemPlayback.apply(stemMixer)
    }

    func setStemPan(_ pan: Float, for kind: StemKind) {
        stemMixer.setPan(pan, for: kind)
        stemPlayback.apply(stemMixer)
    }

    /// True when the mixer differs from its default state (any gain, mute, or solo changed).
    var isStemMixerModified: Bool {
        stemMixer != StemMixerModel()
    }

    /// Resets every stem's gain/mute/solo to defaults and applies it to live playback.
    func resetStemMixer() {
        stemMixer = StemMixerModel()
        stemPlayback.apply(stemMixer)
    }

    func exportStemMix(to destinationURL: URL) {
        guard let stemFiles else { return }
        exportTask?.cancel()
        let exportID = UUID()
        currentExportID = exportID
        isExporting = true
        exportProgress = 0
        let mixer = stemMixer
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await stemMixExporter.export(
                    stems: stemFiles,
                    to: destinationURL,
                    mixer: mixer
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.currentExportID == exportID else { return }
                        self?.exportProgress = progress
                    }
                }
                guard !Task.isCancelled, currentExportID == exportID else { return }
                isExporting = false
                exportProgress = 1
                currentExportID = nil
            } catch is CancellationError {
                guard currentExportID == exportID else { return }
                isExporting = false
                currentExportID = nil
            } catch {
                guard currentExportID == exportID else { return }
                isExporting = false
                currentExportID = nil
                projectErrorMessage = "Could not export stem mix: \(error.localizedDescription)"
            }
        }
    }

    func addLyricSegment(at time: TimeInterval? = nil) {
        let start = time ?? activePlaybackTime
        lyricSegments.append(TimedLyricSegment(start: start, end: start + 4, text: ""))
        lyricSegments.sort { $0.start < $1.start }
    }

    func removeLyricSegments(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            lyricSegments.remove(at: index)
        }
    }

    /// Manual line join: merge a lyric line with the one that follows it in time (for a phrase the
    /// analysis split in two). Text is concatenated with a space, per-word timings are preserved and
    /// re-indexed, and the span covers both. The `lyricSegments` didSet rebuilds the chart + saves.
    func mergeLyricSegmentWithNext(_ id: TimedLyricSegment.ID) {
        let sorted = lyricSegments.sorted { $0.start < $1.start }
        guard let pos = sorted.firstIndex(where: { $0.id == id }), pos + 1 < sorted.count else {
            return
        }
        let first = sorted[pos]
        let next = sorted[pos + 1]
        let merged = LyricLineEdit.merged(first, next)
        lyricSegments.removeAll { $0.id == first.id || $0.id == next.id }
        lyricSegments.append(merged)
        lyricSegments.sort { $0.start < $1.start }
    }

    /// Manual line split: break a lyric line into two at its largest internal word gap (the most
    /// likely place a run-on line should break). No-op for a line with fewer than two words.
    func splitLyricSegment(_ id: TimedLyricSegment.ID) {
        guard let index = lyricSegments.firstIndex(where: { $0.id == id }),
            let (first, second) = LyricLineEdit.split(lyricSegments[index])
        else { return }
        lyricSegments.remove(at: index)
        lyricSegments.append(contentsOf: [first, second])
        lyricSegments.sort { $0.start < $1.start }
    }

    func addChordEvent(at time: TimeInterval? = nil, chord: String = "C") {
        chordEvents.append(
            EditableChordEvent(
                time: time ?? activePlaybackTime,
                chord: chord,
                confidence: nil
            ))
        chordEvents.sort { $0.time < $1.time }
    }

    func removeChordEvents(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            chordEvents.remove(at: index)
        }
    }

    func markLyricsReviewed() {
        lyricReviewState = .reviewed
    }

    func markChordsReviewed() {
        chordReviewState = .reviewed
    }

    func markChordProReviewed() {
        chordProReviewState = .reviewed
    }

    func importChordPro(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        _ = try ChordProDocument(parsing: source)
        chordProSource = source
    }

    func exportChordPro(to url: URL, transposedBy semitones: Int) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let document = try ChordProDocument(parsing: chordProSource)
        try document.transposed(by: semitones).export().write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    func exportBassNoteChordPro(to url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let source = bassNoteChordProSource
        _ = try ChordProDocument(parsing: source)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    func restoreProjects() async {
        do {
            let document = try await store.load()
            var needsBookmarkRefresh = false
            let restored = document.songs.compactMap {
                stored -> (Song, PracticeSettings, SongAnalysisDocument, Date?)? in
                let resolution = stored.resolvedURLWithStaleness()
                needsBookmarkRefresh = needsBookmarkRefresh || resolution.isStale
                let url = resolution.url
                guard SongImportPolicy.accepts(url) else { return nil }
                var settings = stored.settings
                settings.normalize()
                return (
                    Song(url: url),
                    settings,
                    stored.analysis ?? SongAnalysisDocument(),
                    stored.lastOpenedAt
                )
            }
            let currentSongs = songs
            let currentIDs = Set(currentSongs.map(\.id))
            songs = (currentSongs + restored.map(\.0).filter { !currentIDs.contains($0.id) }).sorted
            {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            var restoredSettings = Dictionary(
                restored.map { ($0.0.id, $0.1) },
                uniquingKeysWith: { _, latest in latest }
            )
            restoredSettings.merge(settingsBySongID) { _, current in current }
            settingsBySongID = restoredSettings
            var restoredAnalysis = Dictionary(
                restored.map { ($0.0.id, $0.2) },
                uniquingKeysWith: { _, latest in latest }
            )
            restoredAnalysis.merge(analysisBySongID) { _, current in current }
            analysisBySongID = restoredAnalysis
            var restoredRecency = Dictionary(
                restored.compactMap { item in item.3.map { (item.0.id, $0) } },
                uniquingKeysWith: { _, latest in latest }
            )
            restoredRecency.merge(lastOpenedBySongID) { _, current in current }
            lastOpenedBySongID = restoredRecency
            if selectedSongID == nil, let first = recentSongs.first ?? songs.first {
                select(first)
            }
            hasRestoredProjects = true
            if needsBookmarkRefresh || needsSaveAfterRestore {
                needsSaveAfterRestore = false
                scheduleSave()
            }
            projectErrorMessage = nil
        } catch {
            hasRestoredProjects = true
            projectErrorMessage = "Could not restore projects: \(error.localizedDescription)"
        }
    }

    func saveProjects() async {
        do {
            try await store.save(makeDocument())
            projectErrorMessage = nil
        } catch {
            projectErrorMessage = "Could not save projects: \(error.localizedDescription)"
        }
    }

    private func applySettings(_ settings: PracticeSettings) {
        isApplyingSettings = true
        pitchSemitones = settings.pitchSemitones
        tempoRate = settings.tempoRate
        loopRegion = settings.loopRegion?.clamped(to: playback.duration)
        chordProTranspose = settings.chordProTranspose
        chordProTimingOffsetMS = settings.chordProTimingOffsetMS
        isApplyingSettings = false
        playback.setPitch(semitones: pitchSemitones)
        playback.setTempo(rate: tempoRate)
        stemPlayback.setPitch(semitones: pitchSemitones)
        stemPlayback.setTempo(rate: tempoRate)
        playback.setLoopRegion(loopRegion)
    }

    private func persistSelectedSettings() {
        guard !isApplyingSettings, let selectedSongID else { return }
        settingsBySongID[selectedSongID] = PracticeSettings(
            pitchSemitones: pitchSemitones,
            tempoRate: tempoRate,
            loopRegion: loopRegion,
            chordProTranspose: chordProTranspose,
            chordProTimingOffsetMS: chordProTimingOffsetMS
        )
        scheduleSave()
    }

    private func applyAnalysis(_ analysis: SongAnalysisDocument) {
        isApplyingAnalysis = true
        // Migrate older analyses to the current line-grouping rules from each segment's
        // stored word timings (no re-transcription). Idempotent for already-current lyrics.
        let regroupedLyrics = TimedLyricSegmentGrouper.regroup(analysis.lyrics)
        // Bar-period-aware re-segmentation (backlog #9 Phase 1) — a further post-pass over
        // already-grouped lines, run here (not inside TranscriptionStage) because it needs
        // BOTH finished lyrics and finished harmony, and those two stages run concurrently
        // (see `.scratch/PRD-phrase-structure-lyric-grouper.md` §2). Unconditional on every
        // load, exactly like `TimedLyricSegmentGrouper.regroup` above: it's pure/idempotent and
        // reads whatever chords/beats currently sit in the document, so a harmony-only
        // re-analysis is picked up automatically the next time the song is opened — no
        // chords-digest/version-tag plumbing needed (the PRD §6 versioning question is resolved
        // by following this existing unconditional-post-pass pattern rather than adding new
        // staleness tracking).
        let phraseGroupedLyrics = LyricPhraseGrouper.regroup(
            regroupedLyrics,
            beatTimes: analysis.beatTimes,
            tempo: analysis.estimatedBPM,
            chords: analysis.chords)
        let lyricsRegrouped = phraseGroupedLyrics != analysis.lyrics
        // Both regroup passes above rebuild plain `TimedLyricSegment`s straight from words, with
        // no way to carry a per-line ANNOTATION through (`confidence` is deliberately allowed to
        // be lost this way — see its doc comment — but `overrideText`/`accepted` are user-authored
        // corrections from the Review chart and must survive every load, not just a fresh
        // analysis, since this pipeline runs unconditionally even when nothing changed). Carry
        // them forward from the STORED document's own lyrics (not the live in-memory
        // `lyricSegments`, which may belong to whatever song was previously selected).
        lyricSegments = TimedLyricSegment.reconciled(
            newSegments: phraseGroupedLyrics, against: analysis.lyrics)
        lyricBlendRows = analysis.lyricBlendRows
        referenceLyrics = analysis.referenceLyrics
        chordEvents = analysis.chords
        chordProSource = analysis.chordProSource
        estimatedBPM = analysis.estimatedBPM
        beatTimes = analysis.beatTimes
        sourceDuration = analysis.sourceDuration
        untranscribedVocalRegions = analysis.untranscribedVocalRegions
        bassNotes = analysis.bassNotes
        estimatedKey = analysis.estimatedKey
        chordConfidenceThreshold = analysis.chordConfidenceThreshold
        stemFiles = analysis.stems?.resolved()
        stemMixer = analysis.stemMixer
        lyricReviewState = analysis.lyricReviewState
        chordReviewState = analysis.chordReviewState
        chordProReviewState = analysis.chordProReviewState
        analysisStageRecords = analysis.stageRecords
        // Rebuild the generated chart from the current builder so existing songs pick up
        // chart improvements (intro/instrumental chords, interlude markers, spacing) and
        // any re-grouped lines. Self-guards: only non-reviewed "chordpro-draft-builder"
        // charts are touched, and it's idempotent once a chart is current.
        let chordProBeforeRebuild = chordProSource
        rebuildGeneratedChordProDraft()
        let chordProRebuilt = chordProSource != chordProBeforeRebuild
        if let stemFiles, isCurrentSeparation(record: analysisStageRecords[.separation]) {
            try? stemPlayback.load(stemFiles, mixer: stemMixer)
            stemPlayback.loadClickTrack(beatTimes: beatTimes)
            stemPlayback.setPitch(semitones: pitchSemitones)
            stemPlayback.setTempo(rate: tempoRate)
        } else {
            stemPlayback.unload()
            activePlaybackSource = .recording
            if stemFiles != nil,
                shouldMarkSeparationStale(record: analysisStageRecords[.separation])
            {
                analysisStageRecords[.separation] = staleSeparationRecord(
                    from: analysisStageRecords[.separation]
                )
            }
        }
        isApplyingAnalysis = false
        // Persist once when the load migrated the lyrics or refreshed the generated chart.
        if lyricsRegrouped || chordProRebuilt { persistSelectedAnalysis() }
    }

    private var separationCachingPolicy: SeparationCachingPolicy {
        SeparationCachingPolicy(currentEngine: ONNXSixStemSeparationEngine.cpuMetadata)
    }

    private func isCurrentSeparation(record: AnalysisStageRecord?) -> Bool {
        separationCachingPolicy.isCurrentEngine(record)
    }

    private func shouldMarkSeparationStale(record: AnalysisStageRecord?) -> Bool {
        separationCachingPolicy.shouldMarkStale(record)
    }

    private func staleSeparationRecord(from record: AnalysisStageRecord?) -> AnalysisStageRecord {
        separationCachingPolicy.markStale(record)
    }

    private func persistSelectedAnalysis() {
        guard !isApplyingAnalysis, let selectedSongID else { return }
        analysisBySongID[selectedSongID] = SongAnalysisDocument(
            lyrics: lyricSegments,
            lyricBlendRows: lyricBlendRows,
            untranscribedVocalRegions: untranscribedVocalRegions,
            referenceLyrics: referenceLyrics,
            sourceDuration: sourceDuration,
            chords: chordEvents,
            chordProSource: chordProSource,
            estimatedBPM: estimatedBPM,
            beatTimes: beatTimes,
            bassNotes: bassNotes,
            estimatedKey: estimatedKey,
            chordConfidenceThreshold: chordConfidenceThreshold,
            stems: stemFiles.map(StoredStemFiles.init(files:)),
            stemMixer: stemMixer,
            lyricReviewState: lyricReviewState,
            chordReviewState: chordReviewState,
            chordProReviewState: chordProReviewState,
            stageRecords: analysisStageRecords
        )
        scheduleSave()
    }

    private func scheduleSave() {
        guard hasRestoredProjects else {
            needsSaveAfterRestore = true
            return
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.saveProjects()
        }
    }

    /// Flushes any pending debounced save synchronously. Called on app termination so a
    /// just-changed setting (e.g. transpose) isn't lost before the debounce fires.
    func flushPendingSave() {
        guard hasRestoredProjects else { return }
        saveTask?.cancel()
        try? store.saveBlocking(makeDocument())
    }

    /// Cached `SongTimeline` for the CURRENT `chordProSource`, or `nil` when the previewed
    /// source is not the generated draft (user-edited/reviewed charts) — callers must then fall
    /// back to source-derived behavior instead of trusting row numbers that may not match.
    ///
    /// Validity is proven, not assumed: the timeline is used only when rebuilding the draft from
    /// the current analysis reproduces `chordProSource` byte-for-byte, so timeline row N is
    /// exactly the preview's numbered musical line N (audit RC-2's single alignment routine).
    private var timelineCache: (source: String, timeline: SongTimeline)?
    func songTimelineForPreview() -> SongTimeline? {
        guard !chordProSource.isEmpty else { return nil }
        if let cached = timelineCache, cached.source == chordProSource {
            return cached.timeline
        }
        guard let song = selectedSong else { return nil }
        let result = chordProBuilder.buildResult(
            ChordProDraftInput(
                title: song.title,
                tempo: estimatedBPM,
                lyrics: lyricSegments,
                chords: chordEvents,
                confidenceThreshold: chordConfidenceThreshold,
                beatTimes: beatTimes,
                sourceDuration: sourceDuration,
                untranscribedVocalRegions: untranscribedVocalRegions,
                estimatedKey: estimatedKey
            ))
        guard result.source == chordProSource else {
            timelineCache = nil
            return nil
        }
        timelineCache = (chordProSource, result.timeline)
        return result.timeline
    }

    private func rebuildGeneratedChordProDraft() {
        guard
            let song = selectedSong,
            analysisStageRecords[.chordPro]?.state == .succeeded,
            analysisStageRecords[.chordPro]?.provenance?.engineIdentifier
                == "chordpro-draft-builder",
            chordProReviewState != .reviewed
        else { return }

        chordProSource = chordProBuilder.build(
            ChordProDraftInput(
                title: song.title,
                tempo: estimatedBPM,
                lyrics: lyricSegments,
                chords: chordEvents,
                confidenceThreshold: chordConfidenceThreshold,
                beatTimes: beatTimes,
                sourceDuration: sourceDuration,
                estimatedKey: estimatedKey
            ))
        if var record = analysisStageRecords[.chordPro], var provenance = record.provenance {
            provenance.configurationIdentifier = chordProConfigurationIdentifier
            provenance.resultSchemaVersion = SongAnalysisDocument.currentSchemaVersion
            provenance.completedAt = Date()
            provenance.loadedFromCache = false
            record.provenance = provenance
            analysisStageRecords[.chordPro] = record
        }
    }

    private var chordProConfigurationIdentifier: String {
        "confidence-\(Int((chordConfidenceThreshold * 100).rounded()))"
    }

    private func makeDocument() -> ProjectLibraryDocument {
        ProjectLibraryDocument(
            songs: songs.map { song in
                StoredSongProject(
                    url: song.url,
                    settings: settingsBySongID[song.id] ?? PracticeSettings(),
                    analysis: analysisBySongID[song.id],
                    lastOpenedAt: lastOpenedBySongID[song.id]
                )
            })
    }

    private func refreshModelPackageStatuses() async {
        for descriptor in ModelCatalog.all {
            modelPackageStatuses[descriptor.id] = await modelPackageManager.status(
                for: descriptor
            )
        }
    }

    private func analysisOutputDirectory(for songID: Song.ID) -> URL {
        let identifier = SHA256.hash(data: Data(songID.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("SongWorkbench", isDirectory: true)
        .appendingPathComponent("Analysis", isDirectory: true)
        .appendingPathComponent("Stems", isDirectory: true)
        .appendingPathComponent(identifier, isDirectory: true)
    }

    /// Computes vocal-activity intervals from the current song's vocals stem (off the main actor)
    /// for the waveform overlay. No-op when the song has no separated vocals stem.
    private func loadVocalActivity(for song: Song) {
        vocalActivityTask?.cancel()
        vocalActivityIntervals = []
        vocalWaveform = nil
        guard let vocalsURL = stemFiles?.vocals else { return }
        vocalActivityTask = Task { [weak self] in
            guard let self else { return }
            let accessing = vocalsURL.startAccessingSecurityScopedResource()
            defer { if accessing { vocalsURL.stopAccessingSecurityScopedResource() } }
            let intervals =
                (try? await audioAnalysisService.vocalActivityIntervals(url: vocalsURL)) ?? []
            let envelope = try? await waveformAnalyzer.analyze(
                url: vocalsURL, targetSampleCount: 4_000)
            guard !Task.isCancelled, selectedSongID == song.id else { return }
            vocalActivityIntervals = intervals
            vocalWaveform = envelope
        }
    }

    /// Computes a waveform envelope for each available stem (off the main actor) so the waveform
    /// panel can render one lane per instrument beneath the full mix. Lanes are produced in a fixed
    /// display order; missing stems are skipped. No-op when the song has no separated stems.
    private func loadStemWaveforms(for song: Song) {
        stemWaveformsTask?.cancel()
        stemWaveforms = []
        let stems = stemFiles
        guard stems != nil else {
            // Diagnostic: separation reported success but no stem references reached the model —
            // the stem panel will be empty for a reason the user can't otherwise see.
            if analysisBySongID[song.id]?.stageRecords[.separation]?.state == .succeeded {
                projectErrorMessage =
                    "Separation succeeded but its stem files aren’t linked to this song "
                    + "(no stem references). Re-run Analyze to regenerate them."
            }
            return
        }
        stemWaveformsTask = Task { [weak self] in
            guard let self else { return }
            let order: [StemKind] = [.vocals, .drums, .bass, .guitar, .piano, .other]
            var lanes: [(kind: StemKind, envelope: WaveformEnvelope)] = []
            var firstFailure: String?
            for kind in order {
                guard let url = stems?[kind] else { continue }
                if Task.isCancelled { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let envelope = try await waveformAnalyzer.analyze(
                        url: url, targetSampleCount: 1_200)
                    lanes.append((kind: kind, envelope: envelope))
                } catch {
                    if firstFailure == nil {
                        firstFailure = "\(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            guard !Task.isCancelled, selectedSongID == song.id else { return }
            stemWaveforms = lanes
            // Diagnostic: stems are referenced but none could be read (e.g. the files are
            // missing/unreadable). Surface why instead of silently showing an empty panel.
            if lanes.isEmpty, let firstFailure {
                projectErrorMessage = "Stem waveforms couldn’t be read — \(firstFailure)"
            }
        }
    }

    private func loadWaveform(for song: Song) {
        waveformTask?.cancel()
        waveform = nil
        isLoadingWaveform = true
        waveformTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accessing = song.url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { song.url.stopAccessingSecurityScopedResource() }
                }
                let sourceData = try Data(contentsOf: song.url, options: .mappedIfSafe)
                let engine = AnalysisEngineVersion(identifier: "waveform-envelope", version: "1")
                let envelope: WaveformEnvelope
                if let cached: WaveformEnvelope = try await analysisCache.value(
                    for: sourceData,
                    engine: engine
                ) {
                    envelope = cached
                } else {
                    envelope = try await waveformAnalyzer.analyze(url: song.url)
                    try await analysisCache.store(envelope, for: sourceData, engine: engine)
                }
                guard !Task.isCancelled, selectedSongID == song.id else { return }
                waveform = envelope
                isLoadingWaveform = false
            } catch is CancellationError {
                return
            } catch {
                guard selectedSongID == song.id else { return }
                isLoadingWaveform = false
                projectErrorMessage = "Could not generate waveform: \(error.localizedDescription)"
            }
        }
    }

    private func applyAudioAnalysis(
        _ analysis: SongAudioAnalysis,
        for songID: Song.ID,
        source: HarmonyAudioSource,
        sourceDigest: String,
        loadedFromCache: Bool
    ) {
        let events = ChordEventReducer().events(from: analysis)
        var document = analysisBySongID[songID] ?? SongAnalysisDocument()
        document.estimatedBPM = analysis.beat?.bpm
        document.beatTimes = analysis.beat?.beatTimes ?? []
        document.estimatedKey = analysis.estimatedKey
        document.chords = events
        document.chordReviewState = .draft
        document.stageRecords[.harmony] = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: sourceDigest,
                sourceKind: source.kind,
                engineIdentifier: "native-vdsp-beat-chroma",
                engineVersion: "2",
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier: source.configurationIdentifier,
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(),
                loadedFromCache: loadedFromCache
            ),
            confidence: AnalysisConfidenceSummary(
                average: analysis.chords.isEmpty
                    ? nil
                    : analysis.chords.map(\.confidence).reduce(0, +)
                        / Float(analysis.chords.count),
                lowConfidenceCount: analysis.chords.filter { $0.confidence < 0.5 }.count,
                totalCount: analysis.chords.count
            ),
            errorMessage: nil
        )
        analysisBySongID[songID] = document
        if selectedSongID == songID {
            estimatedBPM = document.estimatedBPM
            beatTimes = document.beatTimes
            estimatedKey = document.estimatedKey
            chordEvents = document.chords
            analysisStageRecords = document.stageRecords
        } else {
            scheduleSave()
        }
    }

    /// Applies a live-captured chord chart to the selected song as a DRAFT. Reuses the same
    /// `ChordEventReducer` + `SongAnalysisDocument` persistence as the offline path, but with
    /// `AnalysisSourceKind.liveCapture` provenance. NO audio file is written and NO
    /// `StoredAudioReference` is ever created — the song keeps whatever recording it had (or none).
    /// The provenance digest is a session identity (no file to hash); `loadedFromCache` is always
    /// false. Returns false when there is no selected song to attach the chart to.
    @discardableResult
    func applyLiveCaptureChart(_ analysis: SongAudioAnalysis) -> Bool {
        guard let songID = selectedSongID else { return false }
        let events = ChordEventReducer().events(from: analysis)
        var document = analysisBySongID[songID] ?? SongAnalysisDocument()
        document.estimatedBPM = analysis.beat?.bpm
        document.beatTimes = analysis.beat?.beatTimes ?? []
        document.estimatedKey = analysis.estimatedKey
        document.chords = events
        document.chordReviewState = .draft
        document.stageRecords[.harmony] = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: "livecapture-\(UUID().uuidString)",
                sourceKind: .liveCapture,
                engineIdentifier: "live-capture-vdsp-chroma",
                engineVersion: "1",
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier: "live-\(LiveHarmonyAnalyzer.frameLength)",
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(),
                loadedFromCache: false
            ),
            confidence: AnalysisConfidenceSummary(
                average: analysis.chords.isEmpty
                    ? nil
                    : analysis.chords.map(\.confidence).reduce(0, +)
                        / Float(analysis.chords.count),
                lowConfidenceCount: analysis.chords.filter { $0.confidence < 0.5 }.count,
                totalCount: analysis.chords.count
            ),
            errorMessage: nil
        )
        analysisBySongID[songID] = document
        applyAnalysis(document)
        scheduleSave()
        return true
    }

    private func monitorAnalysisJob(_ id: BackgroundJobID) {
        analysisMonitorTask?.cancel()
        analysisMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = await analysisJobs.snapshot(for: id)
                analysisJobSnapshot = snapshot
                if snapshot?.state.isTerminal == true {
                    if case .failed(let message) = snapshot?.state {
                        projectErrorMessage = "Analysis failed: \(message)"
                    }
                    await analysisJobs.discard(id)
                    if currentAnalysisJobID == id {
                        currentAnalysisJobID = nil
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

enum StemImportError: LocalizedError {
    case missingStem(StemKind)

    var errorDescription: String? {
        switch self {
        case .missingStem(let kind): "Missing \(kind.rawValue).wav stem."
        }
    }
}
