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
        let sourceDigest = try digest(of: request.sourceURL)
        var document = request.existingDocument
        var completedStages = 0
        var wasCancelled = false

        progress(
            SongAnalysisPipelineProgress(
                stage: nil,
                completedStages: 0,
                totalStages: orderedStages.count,
                stageFraction: 0,
                message: "Preparing analysis"
            ))

        for stage in orderedStages {
            if Task.isCancelled {
                document.stageRecords[stage] = AnalysisStageRecord(
                    state: .cancelled,
                    provenance: nil,
                    confidence: nil,
                    errorMessage: nil
                )
                wasCancelled = true
                break
            }
            progress(
                SongAnalysisPipelineProgress(
                    stage: stage,
                    completedStages: completedStages,
                    totalStages: orderedStages.count,
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
                            totalStages: orderedStages.count,
                            progress: progress
                        )
                    )
                case .transcription:
                    try await runTranscription(
                        request: request,
                        sourceDigest: sourceDigest,
                        document: &document,
                        stageProgress: stageProgress(
                            stage: stage,
                            completedStages: completedStages,
                            totalStages: orderedStages.count,
                            progress: progress
                        )
                    )
                case .harmony:
                    try await runHarmony(
                        request: request,
                        sourceDigest: sourceDigest,
                        document: &document
                    )
                case .chordPro:
                    try runChordPro(
                        request: request,
                        sourceDigest: sourceDigest,
                        document: &document
                    )
                }
            } catch is CancellationError {
                document.stageRecords[stage] = AnalysisStageRecord(
                    state: .cancelled,
                    provenance: nil,
                    confidence: nil,
                    errorMessage: nil
                )
                wasCancelled = true
                break
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
                    totalStages: orderedStages.count,
                    stageFraction: 0,
                    message: "Finished \(stage.rawValue)"
                ))
        }

        return SongAnalysisPipelineResult(document: document, wasCancelled: wasCancelled)
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
        if let storedStems = document.stems,
            let existingRecord = document.stageRecords[.separation],
            existingRecord.state == .succeeded,
            existingRecord.provenance?.sourceDigest == sourceDigest,
            existingRecord.provenance?.engineIdentifier == stemEngine?.metadata.engineIdentifier,
            existingRecord.provenance?.engineVersion == stemEngine?.metadata.engineVersion,
            existingRecord.provenance?.modelIdentifier == stemEngine?.metadata.modelIdentifier,
            storedStems.resolved().isSixSource,
            storedStems.resolved().availableKinds.allSatisfy({ kind in
                guard let url = storedStems.resolved()[kind] else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            })
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

    private func runTranscription(
        request: SongAnalysisPipelineRequest,
        sourceDigest: String,
        document: inout SongAnalysisDocument,
        stageProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
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
            throw SongAnalysisPipelineError.missingTranscriptionEngine(request.transcriptionMode)
        }
        let audioURL = document.stems?.resolved().vocals ?? request.sourceURL
        let sourceKind: AnalysisSourceKind = document.stems == nil ? .recording : .vocalsStem
        let audioData: Data
        if let selectedAudioData = try? Data(contentsOf: audioURL, options: .mappedIfSafe) {
            audioData = selectedAudioData
        } else {
            audioData = try Data(contentsOf: request.sourceURL, options: .mappedIfSafe)
        }
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
            for: audioData,
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
            try await cache?.store(result, for: audioData, engine: cacheEngine)
            loadedFromCache = false
        }
        try Task.checkCancellation()
        document.lyrics = TimedLyricSegmentGrouper.group(result: result)
        document.lyricReviewState = .draft
        let confidences = result.segments.flatMap(\.tokens).compactMap(\.confidence)
        document.stageRecords[.transcription] = successfulRecord(
            sourceDigest: (try? digest(of: audioURL)) ?? sourceDigest,
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
    }

    private func runHarmony(
        request: SongAnalysisPipelineRequest,
        sourceDigest: String,
        document: inout SongAnalysisDocument
    ) async throws {
        let source = try HarmonyAudioSourceSelector().select(
            recordingURL: request.sourceURL,
            stems: document.stems?.resolved(),
            allowsRecordingFallback: true
        )
        let sourceData = try Data(contentsOf: source.url, options: .mappedIfSafe)
        let cacheEngine = AnalysisEngineVersion(
            identifier: harmonyEngine.metadata.identifier + "|\(source.configurationIdentifier)",
            version:
                harmonyEngine.metadata.version
                + "|schema-\(SongAnalysisDocument.currentSchemaVersion)"
        )
        let result: SongAudioAnalysis
        let loadedFromCache: Bool
        if let cached: SongAudioAnalysis = try await cache?.value(
            for: sourceData,
            engine: cacheEngine
        ) {
            result = cached
            loadedFromCache = true
        } else {
            result = try await harmonyEngine.analyze(url: source.url)
            try await cache?.store(result, for: sourceData, engine: cacheEngine)
            loadedFromCache = false
        }
        try Task.checkCancellation()
        document.estimatedBPM = result.beat?.bpm
        document.estimatedKey =
            result.estimatedKey
            ?? MusicalKeyEstimator().estimate(
                from: result.chords)
        document.chords = ChordEventReducer().events(from: result)
        document.chordReviewState = .draft
        document.stageRecords[.harmony] = successfulRecord(
            sourceDigest: sourceDigest,
            sourceKind: source.kind,
            engine: harmonyEngine.metadata,
            modelIdentifier: nil,
            modelVersion: nil,
            configurationIdentifier: source.configurationIdentifier,
            confidence: confidenceSummary(result.chords.map(\.confidence)),
            loadedFromCache: loadedFromCache
        )
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
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
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
