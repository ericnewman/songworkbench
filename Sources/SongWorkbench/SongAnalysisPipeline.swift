import CryptoKit
import Foundation

enum TranscriptionMode: String, Codable, Equatable, Sendable {
    case fastDraft
    case balancedDraft
    case accuracy
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
        AnalysisEngineVersion(identifier: "native-vdsp-beat-chroma", version: "2")
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

    init(
        sourceURL: URL,
        outputDirectory: URL,
        title: String,
        stages: Set<SongAnalysisStage>,
        transcriptionMode: TranscriptionMode,
        existingDocument: SongAnalysisDocument,
        chordProReplacementPolicy: ChordProReplacementPolicy = .preserveExisting
    ) {
        self.sourceURL = sourceURL
        self.outputDirectory = outputDirectory
        self.title = title
        self.stages = stages
        self.transcriptionMode = transcriptionMode
        self.existingDocument = existingDocument
        self.chordProReplacementPolicy = chordProReplacementPolicy
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

struct SongAnalysisPipeline: Sendable {
    private let stemEngine: (any StemSeparationEngine)?
    private let fastTranscriptionEngine: (any TranscriptionEngine)?
    private let balancedTranscriptionEngine: (any TranscriptionEngine)?
    private let accuracyTranscriptionEngine: (any TranscriptionEngine)?
    private let harmonyEngine: any SongHarmonyAnalyzing
    private let cache: AnalysisResultDiskCache?
    private let chordProBuilder = ChordProDraftBuilder()

    init(
        stemEngine: (any StemSeparationEngine)?,
        fastTranscriptionEngine: (any TranscriptionEngine)?,
        balancedTranscriptionEngine: (any TranscriptionEngine)? = nil,
        accuracyTranscriptionEngine: (any TranscriptionEngine)?,
        harmonyEngine: any SongHarmonyAnalyzing,
        cache: AnalysisResultDiskCache? = nil
    ) {
        self.stemEngine = stemEngine
        self.fastTranscriptionEngine = fastTranscriptionEngine
        self.balancedTranscriptionEngine = balancedTranscriptionEngine
        self.accuracyTranscriptionEngine = accuracyTranscriptionEngine
        self.harmonyEngine = harmonyEngine
        self.cache = cache
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

                // Snapshot the inputs both stages need so neither concurrent
                // task touches the shared `document` or the digest memo.
                let stems = document.stems
                let transcriptionAudioURL = stems?.resolved().vocals ?? request.sourceURL
                let harmonySource = try? HarmonyAudioSourceSelector().select(
                    recordingURL: request.sourceURL,
                    stems: stems?.resolved(),
                    allowsRecordingFallback: true
                )
                let transcriptionAudioDigest =
                    (try? digestMemo.digest(of: transcriptionAudioURL)) ?? sourceDigest
                let harmonySourceDigest: String? =
                    harmonySource.flatMap { try? digestMemo.digest(of: $0.url) }

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

                async let transcriptionOutcome = self.transcriptionOutcome(
                    request: request,
                    audioURL: transcriptionAudioURL,
                    hasStems: stems != nil,
                    audioDigest: transcriptionAudioDigest,
                    stageProgress: transcriptionProgress
                )
                async let harmonyOutcome = self.harmonyOutcome(
                    sourceDigest: sourceDigest,
                    harmonySource: harmonySource,
                    harmonySourceDigest: harmonySourceDigest,
                    stageProgress: harmonyProgress
                )

                let (transcription, harmony) = await (transcriptionOutcome, harmonyOutcome)

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
                apply(transcription, stage: .transcription, to: &document)
                apply(harmony, stage: .harmony, to: &document)

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

            do {
                switch stage {
                case .separation:
                    try await runSeparation(
                        request: request,
                        sourceDigest: sourceDigest,
                        document: &document,
                        stageProgress: stageProgress(
                            stage: stage,
                            completedStages: completedStages,
                            totalStages: totalStages,
                            progress: progress
                        )
                    )
                case .transcription:
                    let outcome = await self.transcriptionOutcome(
                        request: request,
                        audioURL: document.stems?.resolved().vocals ?? request.sourceURL,
                        hasStems: document.stems != nil,
                        audioDigest: (try? digestMemo.digest(
                            of: document.stems?.resolved().vocals ?? request.sourceURL))
                            ?? sourceDigest,
                        stageProgress: stageProgress(
                            stage: stage,
                            completedStages: completedStages,
                            totalStages: totalStages,
                            progress: progress
                        )
                    )
                    apply(outcome, stage: .transcription, to: &document)
                    if outcome.wasCancelled {
                        wasCancelled = true
                        break stageLoop
                    }
                case .harmony:
                    let harmonySource = try? HarmonyAudioSourceSelector().select(
                        recordingURL: request.sourceURL,
                        stems: document.stems?.resolved(),
                        allowsRecordingFallback: true
                    )
                    let outcome = await self.harmonyOutcome(
                        sourceDigest: sourceDigest,
                        harmonySource: harmonySource,
                        harmonySourceDigest: harmonySource.flatMap {
                            try? digestMemo.digest(of: $0.url)
                        },
                        stageProgress: stageProgress(
                            stage: stage,
                            completedStages: completedStages,
                            totalStages: totalStages,
                            progress: progress
                        )
                    )
                    apply(outcome, stage: .harmony, to: &document)
                    if outcome.wasCancelled {
                        wasCancelled = true
                        break stageLoop
                    }
                case .chordPro:
                    try runChordPro(
                        request: request,
                        sourceDigest: sourceDigest,
                        document: &document
                    )
                }
            } catch is CancellationError {
                document.stageRecords[stage] = cancelledRecord()
                wasCancelled = true
                break stageLoop
            } catch {
                document.stageRecords[stage] = AnalysisStageRecord(
                    state: .failed,
                    provenance: nil,
                    confidence: nil,
                    errorMessage: error.localizedDescription
                )
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

    private func runSeparation(
        request: SongAnalysisPipelineRequest,
        sourceDigest: String,
        document: inout SongAnalysisDocument,
        stageProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        if let stemEngine,
            SeparationCachingPolicy(currentEngine: stemEngine.metadata).isCacheHit(
                record: document.stageRecords[.separation],
                sourceDigest: sourceDigest,
                storedStems: document.stems
            ),
            let existingRecord = document.stageRecords[.separation]
        {
            var cachedRecord = existingRecord
            if var provenance = cachedRecord.provenance {
                provenance.loadedFromCache = true
                cachedRecord.provenance = provenance
            }
            document.stageRecords[.separation] = cachedRecord
            stageProgress(1, "loadedFromCache")
            return
        }
        guard let stemEngine else { throw SongAnalysisPipelineError.missingStemEngine }
        let result = try await stemEngine.separate(
            request: StemSeparationRequest(
                inputURL: request.sourceURL,
                outputDirectory: request.outputDirectory
            )
        ) { value in
            stageProgress(value.fractionCompleted, value.phase.rawValue)
        }
        document.stems = StoredStemFiles(files: result.stems)
        document.stageRecords[.separation] = successfulRecord(
            sourceDigest: sourceDigest,
            sourceKind: .recording,
            engine: AnalysisEngineVersion(
                identifier: stemEngine.metadata.engineIdentifier,
                version: stemEngine.metadata.engineVersion
            ),
            modelIdentifier: stemEngine.metadata.modelIdentifier,
            modelVersion: stemEngine.metadata.modelVersion,
            configurationIdentifier: "six-stem-44.1k-stereo",
            confidence: nil
        )
    }

    /// Result of running a single independent stage off the main flow. Carries
    /// the fields the stage produces so they can be merged into `document`
    /// deterministically, without the stage touching shared mutable state.
    private struct TranscriptionOutcome: Sendable {
        var record: AnalysisStageRecord
        var wasCancelled: Bool = false
        var lyrics: [TimedLyricSegment]?
        var lyricReviewState: AnalysisReviewState?
    }

    private struct HarmonyOutcome: Sendable {
        var record: AnalysisStageRecord
        var wasCancelled: Bool = false
        var estimatedBPM: Double??
        var estimatedKey: MusicalKey??
        var chords: [EditableChordEvent]?
        var chordReviewState: AnalysisReviewState?
    }

    private func apply(
        _ outcome: TranscriptionOutcome,
        stage: SongAnalysisStage,
        to document: inout SongAnalysisDocument
    ) {
        if let lyrics = outcome.lyrics { document.lyrics = lyrics }
        if let lyricReviewState = outcome.lyricReviewState {
            document.lyricReviewState = lyricReviewState
        }
        document.stageRecords[stage] = outcome.record
    }

    private func apply(
        _ outcome: HarmonyOutcome,
        stage: SongAnalysisStage,
        to document: inout SongAnalysisDocument
    ) {
        if let estimatedBPM = outcome.estimatedBPM { document.estimatedBPM = estimatedBPM }
        if let estimatedKey = outcome.estimatedKey { document.estimatedKey = estimatedKey }
        if let chords = outcome.chords { document.chords = chords }
        if let chordReviewState = outcome.chordReviewState {
            document.chordReviewState = chordReviewState
        }
        document.stageRecords[stage] = outcome.record
    }

    /// Runs transcription and returns its outcome. Never throws: a failure or
    /// cancellation is encoded into the returned record so that a sibling stage
    /// running concurrently is unaffected and prior results are preserved.
    private func transcriptionOutcome(
        request: SongAnalysisPipelineRequest,
        audioURL: URL,
        hasStems: Bool,
        audioDigest: String,
        stageProgress: @escaping @Sendable (Double, String) -> Void
    ) async -> TranscriptionOutcome {
        do {
            let engine: (any TranscriptionEngine)? =
                switch request.transcriptionMode {
                case .fastDraft:
                    fastTranscriptionEngine
                case .balancedDraft:
                    balancedTranscriptionEngine
                case .accuracy:
                    accuracyTranscriptionEngine
                }
            guard let engine else {
                throw SongAnalysisPipelineError.missingTranscriptionEngine(
                    request.transcriptionMode)
            }
            let sourceKind: AnalysisSourceKind = hasStems ? .vocalsStem : .recording
            let cacheEngine = AnalysisEngineVersion(
                identifier: [
                    "transcription",
                    engine.metadata.engineName,
                    engine.metadata.modelName,
                    request.transcriptionMode.rawValue,
                    sourceKind.rawValue,
                ].joined(separator: "|"),
                version: [
                    engine.metadata.engineVersion,
                    engine.metadata.modelVersion ?? "unknown",
                    "schema-\(SongAnalysisDocument.currentSchemaVersion)",
                ].joined(separator: "|")
            )
            let result: TranscriptionResult
            let loadedFromCache: Bool
            if let cached: TranscriptionResult = try await cache?.value(
                forSourceHash: audioDigest,
                engine: cacheEngine
            ) {
                result = cached
                loadedFromCache = true
                stageProgress(1, "loadedFromCache")
            } else {
                let requestID = UUID()
                do {
                    result = try await engine.transcribe(
                        request: TranscriptionRequest(id: requestID, audioURL: audioURL)
                    ) { value in
                        stageProgress(value.fractionCompleted, value.phase.rawValue)
                    }
                } catch is CancellationError {
                    await engine.cancel(requestID: requestID)
                    throw CancellationError()
                }
                try await cache?.store(result, forSourceHash: audioDigest, engine: cacheEngine)
                loadedFromCache = false
            }
            try Task.checkCancellation()
            let confidences = result.segments.flatMap(\.tokens).compactMap(\.confidence)
            let record = successfulRecord(
                sourceDigest: audioDigest,
                sourceKind: sourceKind,
                engine: AnalysisEngineVersion(
                    identifier: result.engine.engineName,
                    version: result.engine.engineVersion
                ),
                modelIdentifier: result.engine.modelName,
                modelVersion: result.engine.modelVersion,
                configurationIdentifier: request.transcriptionMode.rawValue,
                confidence: confidenceSummary(confidences),
                loadedFromCache: loadedFromCache
            )
            return TranscriptionOutcome(
                record: record,
                lyrics: TimedLyricSegmentGrouper.group(result: result),
                lyricReviewState: .draft
            )
        } catch is CancellationError {
            return TranscriptionOutcome(record: cancelledRecord(), wasCancelled: true)
        } catch {
            return TranscriptionOutcome(
                record: AnalysisStageRecord(
                    state: .failed,
                    provenance: nil,
                    confidence: nil,
                    errorMessage: error.localizedDescription
                ))
        }
    }

    /// Runs harmony and returns its outcome. Never throws (see
    /// `transcriptionOutcome`). `harmonySource`/`harmonySourceDigest` may be nil
    /// when source selection failed; that surfaces as a `.failed` record exactly
    /// as the original throwing selector did.
    private func harmonyOutcome(
        sourceDigest: String,
        harmonySource: HarmonyAudioSource?,
        harmonySourceDigest: String?,
        stageProgress: @escaping @Sendable (Double, String) -> Void
    ) async -> HarmonyOutcome {
        do {
            guard let source = harmonySource, let sourceHash = harmonySourceDigest else {
                throw HarmonyAudioSourceError.missingAccompanimentStem
            }
            let cacheEngine = AnalysisEngineVersion(
                identifier: harmonyEngine.metadata.identifier
                    + "|\(source.configurationIdentifier)",
                version:
                    harmonyEngine.metadata.version
                    + "|schema-\(SongAnalysisDocument.currentSchemaVersion)"
            )
            let result: SongAudioAnalysis
            let loadedFromCache: Bool
            if let cached: SongAudioAnalysis = try await cache?.value(
                forSourceHash: sourceHash,
                engine: cacheEngine
            ) {
                result = cached
                loadedFromCache = true
            } else {
                result = try await harmonyEngine.analyze(url: source.url)
                try await cache?.store(result, forSourceHash: sourceHash, engine: cacheEngine)
                loadedFromCache = false
            }
            try Task.checkCancellation()
            stageProgress(1, "completed")
            let record = successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: source.kind,
                engine: harmonyEngine.metadata,
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier: source.configurationIdentifier,
                confidence: confidenceSummary(result.chords.map(\.confidence)),
                loadedFromCache: loadedFromCache
            )
            return HarmonyOutcome(
                record: record,
                estimatedBPM: .some(result.beat?.bpm),
                estimatedKey: .some(
                    result.estimatedKey ?? MusicalKeyEstimator().estimate(from: result.chords)),
                chords: ChordEventReducer().events(from: result),
                chordReviewState: .draft
            )
        } catch is CancellationError {
            return HarmonyOutcome(record: cancelledRecord(), wasCancelled: true)
        } catch {
            return HarmonyOutcome(
                record: AnalysisStageRecord(
                    state: .failed,
                    provenance: nil,
                    confidence: nil,
                    errorMessage: error.localizedDescription
                ))
        }
    }

    private func runChordPro(
        request: SongAnalysisPipelineRequest,
        sourceDigest: String,
        document: inout SongAnalysisDocument
    ) throws {
        let existingWasGenerated =
            document.stageRecords[.chordPro]?.state == .succeeded
            && document.stageRecords[.chordPro]?.provenance?.engineIdentifier
                == "chordpro-draft-builder"
        let hasProtectedContent =
            !document.chordProSource.isEmpty
            && (document.chordProReviewState == .reviewed || !existingWasGenerated)
        guard !hasProtectedContent || request.chordProReplacementPolicy == .replaceExisting else {
            throw SongAnalysisPipelineError.chordProReplacementRequiresConfirmation
        }
        document.chordProSource = chordProBuilder.build(
            ChordProDraftInput(
                title: request.title,
                tempo: document.estimatedBPM,
                lyrics: document.lyrics,
                chords: document.chords,
                confidenceThreshold: document.chordConfidenceThreshold
            ))
        document.chordProReviewState = .draft
        document.stageRecords[.chordPro] = successfulRecord(
            sourceDigest: sourceDigest,
            sourceKind: .recording,
            engine: AnalysisEngineVersion(identifier: "chordpro-draft-builder", version: "2"),
            modelIdentifier: nil,
            modelVersion: nil,
            configurationIdentifier:
                "confidence-\(Int((document.chordConfidenceThreshold * 100).rounded()))",
            confidence: nil
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

    private func successfulRecord(
        sourceDigest: String,
        sourceKind: AnalysisSourceKind,
        engine: AnalysisEngineVersion,
        modelIdentifier: String?,
        modelVersion: String?,
        configurationIdentifier: String,
        confidence: AnalysisConfidenceSummary?,
        loadedFromCache: Bool = false
    ) -> AnalysisStageRecord {
        AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: sourceDigest,
                sourceKind: sourceKind,
                engineIdentifier: engine.identifier,
                engineVersion: engine.version,
                modelIdentifier: modelIdentifier,
                modelVersion: modelVersion,
                configurationIdentifier: configurationIdentifier,
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(),
                loadedFromCache: loadedFromCache
            ),
            confidence: confidence,
            errorMessage: nil
        )
    }

    private func confidenceSummary(_ values: [Float]) -> AnalysisConfidenceSummary? {
        guard !values.isEmpty else { return nil }
        return AnalysisConfidenceSummary(
            average: values.reduce(0, +) / Float(values.count),
            lowConfidenceCount: values.filter { $0 < 0.5 }.count,
            totalCount: values.count
        )
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
private final class DigestMemo {
    private let compute: @Sendable (URL) throws -> String
    private var cache: [URL: String] = [:]

    init(compute: @escaping @Sendable (URL) throws -> String) {
        self.compute = compute
    }

    func digest(of url: URL) throws -> String {
        if let cached = cache[url] { return cached }
        let value = try compute(url)
        cache[url] = value
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
