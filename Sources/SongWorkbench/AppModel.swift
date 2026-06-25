import CryptoKit
import Foundation

enum PlaybackSource: Equatable, Sendable {
    case recording
    case stemMix
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published var selectedSongID: Song.ID?
    @Published private(set) var waveform: WaveformEnvelope?
    @Published private(set) var isLoadingWaveform = false
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
    static let transcriptionModeDefaultsKey = "transcriptionMode"
    @Published var transcriptionMode: TranscriptionMode =
        UserDefaults.standard.string(forKey: AppModel.transcriptionModeDefaultsKey)
        .flatMap(TranscriptionMode.init(rawValue:)) ?? .fastDraft
    {
        didSet {
            UserDefaults.standard.set(
                transcriptionMode.rawValue, forKey: AppModel.transcriptionModeDefaultsKey)
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
    @Published var isImporterPresented = false

    let playback = AudioPlaybackService()
    let stemPlayback = StemPlaybackService()
    let offlineExporter = OfflineAudioExporter()

    private let store: any ProjectStore
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

    init(store: any ProjectStore = JSONProjectStore.standard) {
        self.store = store
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

    var activePlaybackTime: TimeInterval {
        activePlaybackSource == .stemMix ? stemPlayback.currentTime : playback.currentTime
    }

    var activePlaybackDuration: TimeInterval {
        activePlaybackSource == .stemMix ? stemPlayback.duration : playback.duration
    }

    var isActivePlaybackPlaying: Bool {
        activePlaybackSource == .stemMix ? stemPlayback.isPlaying : playback.isPlaying
    }

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
        switch activePlaybackSource {
        case .recording:
            playback.seek(to: time)
        case .stemMix:
            stemPlayback.seek(to: time)
        }
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
            replaceExistingChordPro: replaceExistingChordPro
        )
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

    /// Re-runs analysis for every song that already has an analysis, sequentially, re-running
    /// each song's existing stages (caching skips unchanged stages). Used to roll out
    /// analysis improvements (e.g. chord detection) across the whole library.
    func reanalyzeAllSongs() {
        guard !isSongAnalysisRunning else { return }
        let queue = songs.filter { analysisBySongID[$0.id]?.stageRecords.isEmpty == false }
        reanalyzeNext(in: queue, total: queue.count)
    }

    private func reanalyzeNext(in queue: [Song], total: Int) {
        guard let song = queue.first else {
            reanalyzeAllStatus = nil
            return
        }
        reanalyzeAllStatus = ReanalyzeAllStatus(
            index: total - queue.count + 1, total: total, title: song.title)
        // Only re-run the chord + chart stages: the harmony stage reuses each song's
        // existing stems (or falls back to the full mix), so we avoid re-running slow stem
        // separation across the whole library. Stop the chain if a run is cancelled.
        runAnalysis(for: song, stages: [.harmony, .chordPro]) { [weak self] cancelled in
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
        completion: ((_ cancelled: Bool) -> Void)? = nil
    ) {
        guard !stages.isEmpty else {
            completion?(false)
            return
        }
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
            transcriptionMode: transcriptionMode,
            existingDocument: existingDocument,
            chordProReplacementPolicy: replaceExistingChordPro
                ? .replaceExisting : .preserveExisting
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
                    analysisBySongID[songID] = result.document
                    if selectedSongID == songID {
                        applyAnalysis(result.document)
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
        } else if imported.count < candidates.count {
            projectErrorMessage = "Some files use unsupported audio formats."
        }
        let existingIDs = Set(songs.map(\.id))
        songs.append(contentsOf: imported.filter { !existingIDs.contains($0.id) })
        songs.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        if selectedSongID == nil, let first = imported.first {
            select(first)
        }
        scheduleSave()
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
        scheduleSave()
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
    }

    private func clearSelectedSongState() {
        resetSelectedSongProgressState()
        playback.unload()
        stemPlayback.unload()
        activePlaybackSource = .recording
        selectedSongID = nil
        loopRegion = nil
        lyricSegments = []
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
            chordProTranspose: chordProTranspose
        )
        scheduleSave()
    }

    private func applyAnalysis(_ analysis: SongAnalysisDocument) {
        isApplyingAnalysis = true
        // Migrate older analyses to the current line-grouping rules from each segment's
        // stored word timings (no re-transcription). Idempotent for already-current lyrics.
        let regroupedLyrics = TimedLyricSegmentGrouper.regroup(analysis.lyrics)
        let lyricsRegrouped = regroupedLyrics != analysis.lyrics
        lyricSegments = regroupedLyrics
        referenceLyrics = analysis.referenceLyrics
        chordEvents = analysis.chords
        chordProSource = analysis.chordProSource
        estimatedBPM = analysis.estimatedBPM
        beatTimes = analysis.beatTimes
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
            referenceLyrics: referenceLyrics,
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
                beatTimes: beatTimes
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
