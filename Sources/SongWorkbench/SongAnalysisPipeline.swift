import CryptoKit
import Foundation

enum TranscriptionMode: String, Codable, Equatable, Sendable {
    case fastDraft
    case balancedDraft
    case accuracy
}

enum AnalysisRuntimePlatform: String, Codable, Equatable, Sendable {
    case desktop
    case iPad

    static var current: AnalysisRuntimePlatform {
        #if os(iOS)
            .iPad
        #else
            .desktop
        #endif
    }
}

enum StemSeparationModelTier: String, Codable, Equatable, Sendable {
    case none
    case reducedSixStem
    case fullSixStem
    case advancedDesktop
}

enum PerformanceTrackCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case leadVocals
    case backingVocals
    case drumPieces
    case chordTimeline
    case noteTimeline
    case phraseTimeline
    case songPartTimeline
}

enum AnalysisPipelineExecutionPolicy: String, Codable, Equatable, Sendable {
    case concurrentIndependentStages
    case serialHeavyStages
}

struct AnalysisCapabilityProfile: Codable, Equatable, Sendable {
    let platform: AnalysisRuntimePlatform
    let displayName: String
    let stemSeparationTier: StemSeparationModelTier
    let transcriptionModes: Set<TranscriptionMode>
    let executionPolicy: AnalysisPipelineExecutionPolicy
    let performanceTracks: Set<PerformanceTrackCapability>

    private static let advancedStemRefinementDefaultsKey =
        "SongWorkbench.advancedStemRefinement"

    static var prefersAdvancedStemRefinement: Bool {
        get {
            #if os(macOS)
                UserDefaults.standard.bool(forKey: advancedStemRefinementDefaultsKey)
            #else
                false
            #endif
        }
        set {
            #if os(macOS)
                UserDefaults.standard.set(newValue, forKey: advancedStemRefinementDefaultsKey)
            #endif
        }
    }

    static var current: AnalysisCapabilityProfile {
        #if os(macOS)
            if prefersAdvancedStemRefinement {
                return .desktopAdvanced
            }
        #endif
        return profile(for: .current)
    }

    static var desktopAdvanced: AnalysisCapabilityProfile {
        AnalysisCapabilityProfile(
            platform: .desktop,
            displayName: "Desktop Advanced",
            stemSeparationTier: .advancedDesktop,
            transcriptionModes: [.fastDraft, .balancedDraft, .accuracy],
            executionPolicy: .concurrentIndependentStages,
            performanceTracks: Set(PerformanceTrackCapability.allCases)
        )
    }

    static func profile(for platform: AnalysisRuntimePlatform) -> AnalysisCapabilityProfile {
        switch platform {
        case .desktop:
            AnalysisCapabilityProfile(
                platform: .desktop,
                displayName: "Desktop Full",
                stemSeparationTier: .fullSixStem,
                transcriptionModes: [.fastDraft, .balancedDraft, .accuracy],
                executionPolicy: .concurrentIndependentStages,
                performanceTracks: Set(PerformanceTrackCapability.allCases)
            )
        case .iPad:
            AnalysisCapabilityProfile(
                platform: .iPad,
                displayName: "iPad Reduced",
                stemSeparationTier: .reducedSixStem,
                transcriptionModes: [.fastDraft, .balancedDraft],
                executionPolicy: .serialHeavyStages,
                performanceTracks: [.chordTimeline, .phraseTimeline, .songPartTimeline]
            )
        }
    }

    func allowsTranscriptionMode(_ mode: TranscriptionMode) -> Bool {
        transcriptionModes.contains(mode)
    }

    func supportsPerformanceTrack(_ capability: PerformanceTrackCapability) -> Bool {
        performanceTracks.contains(capability)
    }

    func requiresModelPackage(_ descriptor: ModelPackageDescriptor) -> Bool {
        if ModelCatalog.optionalRefinementIDs.contains(descriptor.id) {
            return false
        }
        switch descriptor.id {
        case ModelCatalog.htdemucs.id:
            return stemSeparationTier == .fullSixStem
                || stemSeparationTier == .advancedDesktop
                || stemSeparationTier == .reducedSixStem
        case ModelCatalog.parakeetFastDraft.id:
            return transcriptionModes.contains(.fastDraft)
                || transcriptionModes.contains(.balancedDraft)
        case ModelCatalog.whisperAccuracy.id:
            return transcriptionModes.contains(.accuracy)
        default:
            return true
        }
    }

    /// Packages shown in the Models UI for this tier, including optional refiners.
    func offersModelPackage(_ descriptor: ModelPackageDescriptor) -> Bool {
        if descriptor.id == ModelCatalog.drumsep.id
            || descriptor.id == ModelCatalog.karaokeVocals.id
        {
            return platform == .desktop
                && (stemSeparationTier == .advancedDesktop
                    || stemSeparationTier == .fullSixStem)
        }
        return requiresModelPackage(descriptor)
    }
}

enum ChordProReplacementPolicy: Equatable, Sendable {
    case preserveExisting
    case replaceExisting
}

protocol SongHarmonyAnalyzing: Sendable {
    var metadata: AnalysisEngineVersion { get }
    func analyze(url: URL) async throws -> SongAudioAnalysis
}

extension AudioFileAnalysisService: SongHarmonyAnalyzing {
    nonisolated var metadata: AnalysisEngineVersion {
        // v7: more permissive bass clarity gate (tracks quieter intro bass).
        AnalysisEngineVersion(identifier: "native-vdsp-beat-chroma", version: "7")
    }
}

struct SongAnalysisPipelineRequest: Sendable {
    let sourceURL: URL
    let outputDirectory: URL
    let title: String
    let stages: Set<SongAnalysisStage>
    let transcriptionMode: TranscriptionMode
    let existingDocument: SongAnalysisDocument
    let chordProReplacementPolicy: ChordProReplacementPolicy
    /// Pitch-preserved decode speed for the transcription pass (Accuracy/Whisper only): < 1 slows
    /// the vocals before recognition, then timestamps are mapped back. 1.0 = no change.
    let transcriptionDecodeRate: Double

    init(
        sourceURL: URL,
        outputDirectory: URL,
        title: String,
        stages: Set<SongAnalysisStage>,
        transcriptionMode: TranscriptionMode,
        existingDocument: SongAnalysisDocument,
        chordProReplacementPolicy: ChordProReplacementPolicy = .preserveExisting,
        transcriptionDecodeRate: Double = 1.0
    ) {
        self.sourceURL = sourceURL
        self.outputDirectory = outputDirectory
        self.title = title
        self.stages = stages
        self.transcriptionMode = transcriptionMode
        self.existingDocument = existingDocument
        self.chordProReplacementPolicy = chordProReplacementPolicy
        self.transcriptionDecodeRate = transcriptionDecodeRate
    }
}

struct SongAnalysisPipelineProgress: Equatable, Sendable {
    let stage: SongAnalysisStage?
    let completedStages: Int
    let totalStages: Int
    let stageFraction: Double
    let message: String

    var fractionCompleted: Double {
        guard totalStages > 0 else { return 1 }
        let boundedStageFraction = min(max(stageFraction, 0), 1)
        return min(
            max((Double(completedStages) + boundedStageFraction) / Double(totalStages), 0),
            1
        )
    }
}

struct SongAnalysisPipelineResult: Equatable, Sendable {
    let document: SongAnalysisDocument
    let wasCancelled: Bool
}

/// Concentrates the transcription mode→engine mapping behind a single value so
/// the pipeline (and any other caller) selects an engine by mode without
/// repeating the `switch`.
struct TranscriptionEngineFactory: Sendable {
    var fast: (any TranscriptionEngine)?
    var balanced: (any TranscriptionEngine)?
    var accuracy: (any TranscriptionEngine)?

    func engine(for mode: TranscriptionMode) -> (any TranscriptionEngine)? {
        switch mode {
        case .fastDraft:
            fast
        case .balancedDraft:
            balanced
        case .accuracy:
            accuracy
        }
    }

    func availableModes() -> Set<TranscriptionMode> {
        var modes: Set<TranscriptionMode> = []
        if fast != nil { modes.insert(.fastDraft) }
        if balanced != nil { modes.insert(.balancedDraft) }
        if accuracy != nil { modes.insert(.accuracy) }
        return modes
    }

    func filtered(to profile: AnalysisCapabilityProfile) -> TranscriptionEngineFactory {
        TranscriptionEngineFactory(
            fast: profile.allowsTranscriptionMode(.fastDraft) ? fast : nil,
            balanced: profile.allowsTranscriptionMode(.balancedDraft) ? balanced : nil,
            accuracy: profile.allowsTranscriptionMode(.accuracy) ? accuracy : nil
        )
    }
}

struct SongAnalysisPipeline: Sendable {
    private let stemEngine: (any StemSeparationEngine)?
    private let stemRefiners: [any StemRefinementEngine]
    private let transcriptionEngineFactory: TranscriptionEngineFactory
    private let harmonyEngine: any SongHarmonyAnalyzing
    private let cache: AnalysisResultDiskCache?
    private let executionPolicy: AnalysisPipelineExecutionPolicy
    private let chordProBuilder = ChordProDraftBuilder()

    init(
        stemEngine: (any StemSeparationEngine)?,
        stemRefiners: [any StemRefinementEngine] = [],
        transcriptionEngineFactory: TranscriptionEngineFactory,
        harmonyEngine: any SongHarmonyAnalyzing,
        cache: AnalysisResultDiskCache? = nil,
        executionPolicy: AnalysisPipelineExecutionPolicy =
            AnalysisCapabilityProfile.current.executionPolicy
    ) {
        self.stemEngine = stemEngine
        self.stemRefiners = stemRefiners
        self.transcriptionEngineFactory = transcriptionEngineFactory
        self.harmonyEngine = harmonyEngine
        self.cache = cache
        self.executionPolicy = executionPolicy
    }

    init(
        stemEngine: (any StemSeparationEngine)?,
        stemRefiners: [any StemRefinementEngine] = [],
        fastTranscriptionEngine: (any TranscriptionEngine)?,
        balancedTranscriptionEngine: (any TranscriptionEngine)? = nil,
        accuracyTranscriptionEngine: (any TranscriptionEngine)?,
        harmonyEngine: any SongHarmonyAnalyzing,
        cache: AnalysisResultDiskCache? = nil,
        executionPolicy: AnalysisPipelineExecutionPolicy =
            AnalysisCapabilityProfile.current.executionPolicy
    ) {
        self.init(
            stemEngine: stemEngine,
            stemRefiners: stemRefiners,
            transcriptionEngineFactory: TranscriptionEngineFactory(
                fast: fastTranscriptionEngine,
                balanced: balancedTranscriptionEngine,
                accuracy: accuracyTranscriptionEngine
            ),
            harmonyEngine: harmonyEngine,
            cache: cache,
            executionPolicy: executionPolicy
        )
    }

    func run(
        _ request: SongAnalysisPipelineRequest,
        progress: @escaping @Sendable (SongAnalysisPipelineProgress) -> Void
    ) async throws -> SongAnalysisPipelineResult {
        let stages = stagesIncludingGeneratedDependents(for: request)
        let orderedStages = SongAnalysisStage.allCases.filter(stages.contains)
        let totalStages = orderedStages.count
        let digestMemo = DigestMemo { url in try self.digest(of: url) }
        let sourceDigest = try digestMemo.digest(of: request.sourceURL)
        var document = request.existingDocument
        var completedStages = 0
        var wasCancelled = false

        progress(
            SongAnalysisPipelineProgress(
                stage: nil,
                completedStages: 0,
                totalStages: totalStages,
                stageFraction: 0,
                message: "Preparing analysis"
            ))

        var index = 0
        stageLoop: while index < orderedStages.count {
            let stage = orderedStages[index]

            // When both transcription and harmony are scheduled, run them
            // concurrently after separation (they each depend only on
            // separation and are independent of each other).
            if stage == .transcription, stages.contains(.harmony) {
                if Task.isCancelled {
                    document.stageRecords[.transcription] = cancelledRecord()
                    document.stageRecords[.harmony] = cancelledRecord()
                    wasCancelled = true
                    break stageLoop
                }
                progress(
                    SongAnalysisPipelineProgress(
                        stage: .transcription,
                        completedStages: completedStages,
                        totalStages: totalStages,
                        stageFraction: 0,
                        message: "Starting \(SongAnalysisStage.transcription.rawValue)"
                    ))
                progress(
                    SongAnalysisPipelineProgress(
                        stage: .harmony,
                        completedStages: completedStages,
                        totalStages: totalStages,
                        stageFraction: 0,
                        message: "Starting \(SongAnalysisStage.harmony.rawValue)"
                    ))

                // Precompute every digest both stages will need on THIS task and
                // capture only the resulting Sendable snapshot into the closure
                // the concurrent contexts use. The non-Sendable DigestMemo never
                // crosses into the `async let` tasks.
                let stems = document.stems
                let transcriptionAudioURL = stems?.resolved().vocals ?? request.sourceURL
                let harmonySource = try? HarmonyAudioSourceSelector().select(
                    recordingURL: request.sourceURL,
                    stems: stems?.resolved(),
                    allowsRecordingFallback: true
                )
                var builtSnapshot: [URL: String] = [:]
                if let value = try? digestMemo.digest(of: transcriptionAudioURL) {
                    builtSnapshot[transcriptionAudioURL] = value
                }
                if let source = harmonySource,
                    let value = try? digestMemo.digest(of: source.url)
                {
                    builtSnapshot[source.url] = value
                }
                let digestSnapshot = builtSnapshot
                let snapshotDigest: @Sendable (URL) -> String? = { url in digestSnapshot[url] }

                let transcriptionProgress = stageProgress(
                    stage: .transcription,
                    completedStages: completedStages,
                    totalStages: totalStages,
                    progress: progress
                )
                let harmonyProgress = stageProgress(
                    stage: .harmony,
                    completedStages: completedStages,
                    totalStages: totalStages,
                    progress: progress
                )

                let transcriptionContext = makeContext(
                    request: request,
                    document: document,
                    sourceDigest: sourceDigest,
                    digest: snapshotDigest,
                    stageProgress: transcriptionProgress
                )
                let harmonyContext = makeContext(
                    request: request,
                    document: document,
                    sourceDigest: sourceDigest,
                    digest: snapshotDigest,
                    stageProgress: harmonyProgress
                )

                let transcription: AnalysisStageOutcome
                let harmony: AnalysisStageOutcome
                switch executionPolicy {
                case .serialHeavyStages:
                    // Memory-bounded profile: avoid overlapping ASR and harmony working sets
                    // immediately after stem separation.
                    transcription = await runStage(
                        .transcription,
                        runner: TranscriptionStage(),
                        context: transcriptionContext
                    )
                    harmony = await runStage(
                        .harmony,
                        runner: HarmonyStage(),
                        context: harmonyContext
                    )
                case .concurrentIndependentStages:
                    async let transcriptionOutcome = runStage(
                        .transcription,
                        runner: TranscriptionStage(),
                        context: transcriptionContext
                    )
                    async let harmonyOutcome = runStage(
                        .harmony,
                        runner: HarmonyStage(),
                        context: harmonyContext
                    )
                    (transcription, harmony) = await (transcriptionOutcome, harmonyOutcome)
                }

                // A cancelled run publishes no freshly-computed results: record
                // cancellation only for the stage(s) actually interrupted and do
                // not persist a sibling result computed during the teardown race.
                if transcription.wasCancelled || harmony.wasCancelled {
                    if transcription.wasCancelled {
                        document.stageRecords[.transcription] = cancelledRecord()
                    }
                    if harmony.wasCancelled {
                        document.stageRecords[.harmony] = cancelledRecord()
                    }
                    wasCancelled = true
                    break stageLoop
                }

                // Apply deterministically: transcription first, then harmony.
                // A failure in one never erases the other's record or any
                // previously persisted result.
                transcription.apply(&document)
                harmony.apply(&document)

                completedStages += 1
                progress(
                    SongAnalysisPipelineProgress(
                        stage: .transcription,
                        completedStages: completedStages,
                        totalStages: totalStages,
                        stageFraction: 0,
                        message: "Finished \(SongAnalysisStage.transcription.rawValue)"
                    ))
                completedStages += 1
                progress(
                    SongAnalysisPipelineProgress(
                        stage: .harmony,
                        completedStages: completedStages,
                        totalStages: totalStages,
                        stageFraction: 0,
                        message: "Finished \(SongAnalysisStage.harmony.rawValue)"
                    ))

                if wasCancelled { break stageLoop }

                // Skip the standalone harmony iteration; it has been handled.
                index += 1
                if index < orderedStages.count, orderedStages[index] == .harmony {
                    index += 1
                }
                continue stageLoop
            }

            if Task.isCancelled {
                document.stageRecords[stage] = cancelledRecord()
                wasCancelled = true
                break stageLoop
            }
            progress(
                SongAnalysisPipelineProgress(
                    stage: stage,
                    completedStages: completedStages,
                    totalStages: totalStages,
                    stageFraction: 0,
                    message: "Starting \(stage.rawValue)"
                ))

            // The digest memo is used only here, on this single (non-concurrent)
            // task, so the stage context may be backed by it directly.
            let memoDigest: @Sendable (URL) -> String? = { url in
                try? digestMemo.digest(of: url)
            }
            let context = makeContext(
                request: request,
                document: document,
                sourceDigest: sourceDigest,
                digest: memoDigest,
                stageProgress: stageProgress(
                    stage: stage,
                    completedStages: completedStages,
                    totalStages: totalStages,
                    progress: progress
                )
            )
            let runner: any AnalysisStageRunning
            switch stage {
            case .separation:
                runner = SeparationStage()
            case .transcription:
                runner = TranscriptionStage()
            case .harmony:
                runner = HarmonyStage()
            case .chordPro:
                runner = ChordProStage()
            }
            let outcome = await runStage(stage, runner: runner, context: context)
            outcome.apply(&document)
            if outcome.wasCancelled {
                wasCancelled = true
                break stageLoop
            }

            completedStages += 1
            progress(
                SongAnalysisPipelineProgress(
                    stage: stage,
                    completedStages: completedStages,
                    totalStages: totalStages,
                    stageFraction: 0,
                    message: "Finished \(stage.rawValue)"
                ))
            index += 1
        }

        return SongAnalysisPipelineResult(document: document, wasCancelled: wasCancelled)
    }

    private func runStage(
        _ stage: SongAnalysisStage,
        runner: any AnalysisStageRunning,
        context: AnalysisStageContext
    ) async -> AnalysisStageOutcome {
        let startedAt = ContinuousClock.now
        AnalysisResourceLog.checkpoint(stage: stage.rawValue, event: "started")
        let outcome = await runner.run(context)
        if stage == .transcription,
            let engine = context.transcriptionEngineFactory.engine(
                for: context.request.transcriptionMode
            )
        {
            await engine.releaseResources()
            AnalysisResourceLog.checkpoint(
                stage: stage.rawValue,
                event: "model-released",
                startedAt: startedAt
            )
        }
        AnalysisResourceLog.checkpoint(
            stage: stage.rawValue,
            event: outcome.wasCancelled ? "cancelled" : "finished",
            startedAt: startedAt
        )
        return outcome
    }

    private func cancelledRecord() -> AnalysisStageRecord {
        AnalysisStageRecord(
            state: .cancelled,
            provenance: nil,
            confidence: nil,
            errorMessage: nil
        )
    }

    private func stagesIncludingGeneratedDependents(
        for request: SongAnalysisPipelineRequest
    ) -> Set<SongAnalysisStage> {
        var stages = request.stages
        guard
            !stages.contains(.chordPro),
            stages.contains(.transcription) || stages.contains(.harmony),
            request.existingDocument.chordProReviewState == .draft,
            request.existingDocument.stageRecords[.chordPro]?.state == .succeeded,
            request.existingDocument.stageRecords[.chordPro]?.provenance?.engineIdentifier
                == "chordpro-draft-builder"
        else { return stages }

        stages.insert(.chordPro)
        return stages
    }

    /// Bundles everything a stage adapter needs for one invocation. Rebuilt per
    /// stage so later stages see earlier stages' document mutations.
    private func makeContext(
        request: SongAnalysisPipelineRequest,
        document: SongAnalysisDocument,
        sourceDigest: String,
        digest: @escaping @Sendable (URL) -> String?,
        stageProgress: @escaping @Sendable (Double, String) -> Void
    ) -> AnalysisStageContext {
        AnalysisStageContext(
            request: request,
            document: document,
            sourceDigest: sourceDigest,
            digest: digest,
            cache: cache,
            stemEngine: stemEngine,
            stemRefiners: stemRefiners,
            transcriptionEngineFactory: transcriptionEngineFactory,
            harmonyEngine: harmonyEngine,
            chordProBuilder: chordProBuilder,
            chordProReplacementPolicy: request.chordProReplacementPolicy,
            stageProgress: stageProgress
        )
    }

    private func stageProgress(
        stage: SongAnalysisStage,
        completedStages: Int,
        totalStages: Int,
        progress: @escaping @Sendable (SongAnalysisPipelineProgress) -> Void
    ) -> @Sendable (Double, String) -> Void {
        let emitter = MonotonicStageProgressEmitter(
            stage: stage,
            completedStages: completedStages,
            totalStages: totalStages,
            progress: progress
        )
        return { fraction, message in
            emitter.report(fraction: fraction, message: message)
        }
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Memoizes per-URL SHA-256 digests so each distinct audio file is hashed at
/// most once during a single pipeline run.
private final class DigestMemo: @unchecked Sendable {
    private let compute: @Sendable (URL) throws -> String
    private let lock = NSLock()
    private var cache: [URL: String] = [:]

    init(compute: @escaping @Sendable (URL) throws -> String) {
        self.compute = compute
    }

    func digest(of url: URL) throws -> String {
        if let cached = lock.withLock({ cache[url] }) { return cached }
        let value = try compute(url)
        lock.withLock { cache[url] = value }
        return value
    }
}

enum SongAnalysisPipelineError: LocalizedError, Equatable {
    case missingStemEngine
    case missingTranscriptionEngine(TranscriptionMode)
    case chordProReplacementRequiresConfirmation

    var errorDescription: String? {
        switch self {
        case .missingStemEngine:
            "Install the stem-separation model before running separation."
        case .missingTranscriptionEngine(let mode):
            "Install the \(mode.rawValue) transcription model before transcribing."
        case .chordProReplacementRequiresConfirmation:
            "Confirm replacement before overwriting reviewed or manually imported ChordPro."
        }
    }
}

private final class MonotonicStageProgressEmitter: @unchecked Sendable {
    private let stage: SongAnalysisStage
    private let completedStages: Int
    private let totalStages: Int
    private let progress: @Sendable (SongAnalysisPipelineProgress) -> Void
    private let lock = NSLock()
    private var highestFraction = 0.0

    init(
        stage: SongAnalysisStage,
        completedStages: Int,
        totalStages: Int,
        progress: @escaping @Sendable (SongAnalysisPipelineProgress) -> Void
    ) {
        self.stage = stage
        self.completedStages = completedStages
        self.totalStages = totalStages
        self.progress = progress
    }

    func report(fraction: Double, message: String) {
        let monotonicFraction = lock.withLock {
            highestFraction = max(highestFraction, min(max(fraction, 0), 1))
            return highestFraction
        }
        progress(
            SongAnalysisPipelineProgress(
                stage: stage,
                completedStages: completedStages,
                totalStages: totalStages,
                stageFraction: monotonicFraction,
                message: message
            ))
    }
}
