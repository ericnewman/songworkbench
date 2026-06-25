import Foundation

/// The result of running a single analysis stage through its adapter.
///
/// `apply` performs that stage's document mutations — setting any produced
/// fields and writing the stage record. Outcomes are built so that a
/// failed/cancelled stage's `apply` writes ONLY its stage record (a `.failed`
/// or `.cancelled` record) and touches nothing else, preserving any results a
/// prior stage already wrote into the document.
struct AnalysisStageOutcome: Sendable {
    let wasCancelled: Bool
    let apply: @Sendable (inout SongAnalysisDocument) -> Void

    init(
        wasCancelled: Bool = false,
        apply: @escaping @Sendable (inout SongAnalysisDocument) -> Void
    ) {
        self.wasCancelled = wasCancelled
        self.apply = apply
    }
}

/// Everything a stage adapter needs, captured per-invocation. The pipeline
/// rebuilds this for each stage so later stages see earlier stages' results
/// (e.g. transcription/harmony see separation's stems through `document`).
///
/// `digest` is a `@Sendable` closure rather than the pipeline's `DigestMemo`:
/// the memo is a non-`Sendable` reference type and must never be shared into
/// the concurrent transcription+harmony tasks. For the concurrent branch the
/// pipeline derives this closure from a precomputed snapshot of digests; for
/// sequential stages it may be backed by the memo (used on a single task).
struct AnalysisStageContext: Sendable {
    let request: SongAnalysisPipelineRequest
    let document: SongAnalysisDocument
    let sourceDigest: String
    let digest: @Sendable (URL) -> String?
    let cache: AnalysisResultDiskCache?
    let stemEngine: (any StemSeparationEngine)?
    let transcriptionEngineFactory: TranscriptionEngineFactory
    let harmonyEngine: any SongHarmonyAnalyzing
    let chordProBuilder: ChordProDraftBuilder
    let chordProReplacementPolicy: ChordProReplacementPolicy
    let stageProgress: @Sendable (Double, String) -> Void
}

/// Uniform interface every stage adapter conforms to. The pipeline owns
/// ordering, concurrency, and cancellation; each adapter owns the per-stage
/// knowledge (engine selection, cache keys, provenance, document mutations).
protocol AnalysisStageRunning: Sendable {
    var stage: SongAnalysisStage { get }
    func run(_ context: AnalysisStageContext) async -> AnalysisStageOutcome
}

// MARK: - Shared record construction

/// Per-stage record/provenance construction extracted from the pipeline so the
/// per-stage knowledge lives in the stage. The produced records, keys, and
/// provenance remain byte-identical to the pre-refactor pipeline.
enum AnalysisStageRecordFactory {
    static func cancelledRecord() -> AnalysisStageRecord {
        AnalysisStageRecord(
            state: .cancelled,
            provenance: nil,
            confidence: nil,
            errorMessage: nil
        )
    }

    static func failedRecord(_ error: Error) -> AnalysisStageRecord {
        AnalysisStageRecord(
            state: .failed,
            provenance: nil,
            confidence: nil,
            errorMessage: error.localizedDescription
        )
    }

    static func successfulRecord(
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

    static func confidenceSummary(_ values: [Float]) -> AnalysisConfidenceSummary? {
        guard !values.isEmpty else { return nil }
        return AnalysisConfidenceSummary(
            average: values.reduce(0, +) / Float(values.count),
            lowConfidenceCount: values.filter { $0 < 0.5 }.count,
            totalCount: values.count
        )
    }
}

// MARK: - Separation

struct SeparationStage: AnalysisStageRunning {
    let stage: SongAnalysisStage = .separation

    func run(_ context: AnalysisStageContext) async -> AnalysisStageOutcome {
        do {
            let document = context.document
            let sourceDigest = context.sourceDigest

            // Cache hit: reuse the existing record, marking it loaded-from-cache,
            // and mutate nothing else.
            if let stemEngine = context.stemEngine,
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
                let loadedRecord = cachedRecord
                context.stageProgress(1, "loadedFromCache")
                return AnalysisStageOutcome { document in
                    document.stageRecords[.separation] = loadedRecord
                }
            }

            guard let stemEngine = context.stemEngine else {
                throw SongAnalysisPipelineError.missingStemEngine
            }
            let stageProgress = context.stageProgress
            let result = try await stemEngine.separate(
                request: StemSeparationRequest(
                    inputURL: context.request.sourceURL,
                    outputDirectory: context.request.outputDirectory
                )
            ) { value in
                stageProgress(value.fractionCompleted, value.phase.rawValue)
            }
            let stems = StoredStemFiles(files: result.stems)
            let record = AnalysisStageRecordFactory.successfulRecord(
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
            return AnalysisStageOutcome { document in
                document.stems = stems
                document.stageRecords[.separation] = record
            }
        } catch is CancellationError {
            return AnalysisStageOutcome(wasCancelled: true) { document in
                document.stageRecords[.separation] = AnalysisStageRecordFactory.cancelledRecord()
            }
        } catch {
            let record = AnalysisStageRecordFactory.failedRecord(error)
            return AnalysisStageOutcome { document in
                document.stageRecords[.separation] = record
            }
        }
    }
}

// MARK: - Transcription

struct TranscriptionStage: AnalysisStageRunning {
    let stage: SongAnalysisStage = .transcription

    func run(_ context: AnalysisStageContext) async -> AnalysisStageOutcome {
        let request = context.request
        let audioURL = context.document.stems?.resolved().vocals ?? request.sourceURL
        let hasStems = context.document.stems != nil
        let audioDigest = context.digest(audioURL) ?? context.sourceDigest
        let stageProgress = context.stageProgress

        do {
            let engine = context.transcriptionEngineFactory.engine(for: request.transcriptionMode)
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
            if let cached: TranscriptionResult = try await context.cache?.value(
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
                try await context.cache?.store(
                    result, forSourceHash: audioDigest, engine: cacheEngine)
                loadedFromCache = false
            }
            try Task.checkCancellation()
            let confidences = result.segments.flatMap(\.tokens).compactMap(\.confidence)
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: audioDigest,
                sourceKind: sourceKind,
                engine: AnalysisEngineVersion(
                    identifier: result.engine.engineName,
                    // Grouping-version suffix: changes the stage record (so re-analysis
                    // re-groups from the cached raw transcription) without changing the raw
                    // transcription cache key, so no re-transcription is needed.
                    version: result.engine.engineVersion + "|grouping-9-leading-orphan"
                        + referenceLyricsVersionTag(context.document.referenceLyrics)
                ),
                modelIdentifier: result.engine.modelName,
                modelVersion: result.engine.modelVersion,
                configurationIdentifier: request.transcriptionMode.rawValue,
                confidence: AnalysisStageRecordFactory.confidenceSummary(confidences),
                loadedFromCache: loadedFromCache
            )
            // Drop stray low-confidence words isolated in silence so instrumental gaps
            // survive and become Intro/Instrumental/Outro sections, then group into lines.
            // (The consensus RepeatedLyricCorrector is intentionally NOT applied here: on
            // real songs a majority mis-hearing — e.g. "flip flops" heard as "slip flops" in
            // 2 of 3 choruses — makes consensus propagate the wrong word. It stays available
            // for an opt-in path once a dictionary/language signal can pick the real word.)
            let gatedTokens = TranscriptionSilenceGate.filtered(
                result.segments.flatMap(\.tokens))
            // Respect the transcriber's segment boundaries as line breaks: Whisper segments per
            // sung line (with ~zero word gaps), so without this its lines run on; Parakeet emits a
            // single segment, so this is a no-op and its lines still come from the grouping rules.
            let groupedLyrics = TimedLyricSegmentGrouper.group(
                tokens: gatedTokens,
                lineStartOnsets: TimedLyricSegmentGrouper.lineStartOnsets(of: result.segments))
            // When the user supplied reference lyrics, align their exact words/lines to the ASR
            // word timings (most accurate path); otherwise use the ASR-grouped lines.
            let reference = context.document.referenceLyrics
            let lyrics =
                reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? groupedLyrics
                : ReferenceLyricAligner.align(referenceText: reference, asrSegments: groupedLyrics)
            return AnalysisStageOutcome { document in
                document.lyrics = lyrics
                document.lyricReviewState = .draft
                document.stageRecords[.transcription] = record
            }
        } catch is CancellationError {
            return AnalysisStageOutcome(wasCancelled: true) { document in
                document.stageRecords[.transcription] = AnalysisStageRecordFactory.cancelledRecord()
            }
        } catch {
            let record = AnalysisStageRecordFactory.failedRecord(error)
            return AnalysisStageOutcome { document in
                document.stageRecords[.transcription] = record
            }
        }
    }
}

/// A stable, deterministic tag for the reference lyrics so that changing them invalidates the
/// transcription stage record (forcing a re-group + re-align from the cached raw transcription,
/// with no re-transcription). Empty reference → empty tag (no behavior change). FNV-1a over UTF-8.
private func referenceLyricsVersionTag(_ referenceLyrics: String) -> String {
    let trimmed = referenceLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in trimmed.utf8 {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return "|ref-" + String(hash, radix: 36)
}

// MARK: - Harmony

struct HarmonyStage: AnalysisStageRunning {
    let stage: SongAnalysisStage = .harmony

    /// Detects the played bass line from the BASS stem. Constructed once;
    /// stateless and `Sendable`.
    private let bassLineAnalyzer = BassLineAnalyzer()

    /// Runs bass-line detection over the separated BASS stem, if present and
    /// readable. Purely additive to the harmony stage: returns `nil` (leaving
    /// `bassNotes` unchanged) when there is no bass stem, and swallows any
    /// failure so bass detection can never fail the harmony stage. Honors
    /// cancellation.
    private func detectBassNotes(_ context: AnalysisStageContext) -> [BassNoteObservation]? {
        guard (try? Task.checkCancellation()) != nil else { return nil }
        // Resolve the bass stem and analyze it. The analyzer opens the file with
        // security-scoped access itself, so we must NOT pre-gate on
        // `isReadableFile` here — that returns false for a security-scoped
        // bookmark URL whose access hasn't been started, which silently skipped
        // detection. A nil/empty result leaves existing bassNotes untouched.
        guard let bassURL = context.document.stems?.resolved().bass,
            let notes = try? bassLineAnalyzer.analyze(url: bassURL),
            !notes.isEmpty
        else {
            return nil
        }
        return notes
    }

    func run(_ context: AnalysisStageContext) async -> AnalysisStageOutcome {
        let harmonySource = try? HarmonyAudioSourceSelector().select(
            recordingURL: context.request.sourceURL,
            stems: context.document.stems?.resolved(),
            allowsRecordingFallback: true
        )
        let harmonySourceDigest: String? = harmonySource.flatMap { context.digest($0.url) }
        let sourceDigest = context.sourceDigest
        let harmonyEngine = context.harmonyEngine
        let cache = context.cache
        let stageProgress = context.stageProgress

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
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: source.kind,
                // Reducer-version suffix: changes the stage record (so re-analysis re-reduces the
                // cached raw chord observations into events) WITHOUT changing the raw chroma cache
                // key — so no re-chroma is needed when only the ChordEventReducer changes.
                engine: AnalysisEngineVersion(
                    identifier: harmonyEngine.metadata.identifier,
                    version: harmonyEngine.metadata.version + "|reduce-2"
                ),
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier: source.configurationIdentifier,
                confidence: AnalysisStageRecordFactory.confidenceSummary(
                    result.chords.map(\.confidence)),
                loadedFromCache: loadedFromCache
            )
            let estimatedBPM: Double? = result.beat?.bpm
            let beatTimes = result.beat?.beatTimes ?? []
            let estimatedKey: MusicalKey? =
                result.estimatedKey ?? MusicalKeyEstimator().estimate(from: result.chords)
            // Additive: detect the played bass line from the BASS stem (runs
            // whether or not the harmony chord result was a cache hit). A `nil`
            // result (no stem / failure) leaves existing bassNotes untouched.
            let detectedBassNotes = detectBassNotes(context)
            // Re-root shared-note chord confusions (e.g. Cm vs Ab) using the bass line.
            let chords = BassInformedChordRefiner().refine(
                ChordEventReducer().events(from: result),
                bassNotes: detectedBassNotes ?? []
            )
            return AnalysisStageOutcome { document in
                document.estimatedBPM = estimatedBPM
                document.beatTimes = beatTimes
                document.estimatedKey = estimatedKey
                document.chords = chords
                if let detectedBassNotes {
                    document.bassNotes = detectedBassNotes
                }
                document.chordReviewState = .draft
                document.stageRecords[.harmony] = record
            }
        } catch is CancellationError {
            return AnalysisStageOutcome(wasCancelled: true) { document in
                document.stageRecords[.harmony] = AnalysisStageRecordFactory.cancelledRecord()
            }
        } catch {
            let record = AnalysisStageRecordFactory.failedRecord(error)
            return AnalysisStageOutcome { document in
                document.stageRecords[.harmony] = record
            }
        }
    }
}

// MARK: - ChordPro

struct ChordProStage: AnalysisStageRunning {
    let stage: SongAnalysisStage = .chordPro

    func run(_ context: AnalysisStageContext) async -> AnalysisStageOutcome {
        let document = context.document
        let request = context.request
        let sourceDigest = context.sourceDigest

        do {
            let existingWasGenerated =
                document.stageRecords[.chordPro]?.state == .succeeded
                && document.stageRecords[.chordPro]?.provenance?.engineIdentifier
                    == "chordpro-draft-builder"
            let hasProtectedContent =
                !document.chordProSource.isEmpty
                && (document.chordProReviewState == .reviewed || !existingWasGenerated)
            guard
                !hasProtectedContent
                    || request.chordProReplacementPolicy == .replaceExisting
            else {
                throw SongAnalysisPipelineError.chordProReplacementRequiresConfirmation
            }
            let chordProSource = context.chordProBuilder.build(
                ChordProDraftInput(
                    title: request.title,
                    tempo: document.estimatedBPM,
                    lyrics: document.lyrics,
                    chords: document.chords,
                    confidenceThreshold: document.chordConfidenceThreshold,
                    beatTimes: document.beatTimes
                ))
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: .recording,
                engine: AnalysisEngineVersion(identifier: "chordpro-draft-builder", version: "2"),
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier:
                    "confidence-\(Int((document.chordConfidenceThreshold * 100).rounded()))",
                confidence: nil
            )
            return AnalysisStageOutcome { document in
                document.chordProSource = chordProSource
                document.chordProReviewState = .draft
                document.stageRecords[.chordPro] = record
            }
        } catch is CancellationError {
            return AnalysisStageOutcome(wasCancelled: true) { document in
                document.stageRecords[.chordPro] = AnalysisStageRecordFactory.cancelledRecord()
            }
        } catch {
            let record = AnalysisStageRecordFactory.failedRecord(error)
            return AnalysisStageOutcome { document in
                document.stageRecords[.chordPro] = record
            }
        }
    }
}
