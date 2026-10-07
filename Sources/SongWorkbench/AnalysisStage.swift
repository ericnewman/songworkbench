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
    let stemRefiners: [any StemRefinementEngine]
    let transcriptionEngineFactory: TranscriptionEngineFactory
    let harmonyEngine: any SongHarmonyAnalyzing
    let chordProBuilder: ChordProDraftBuilder
    let chordProReplacementPolicy: ChordProReplacementPolicy
    let stageProgress: @Sendable (Double, String) -> Void
    /// See `SongAnalysisPipeline.measureWordTimes`.
    var measureWordTimes: WordTimeMeasurer = MeasuredLyricTiming.measuredWithBundledModel
    /// See `SongAnalysisPipeline.vocalPosteriorgram`.
    var vocalPosteriorgram: VocalPosteriorgram = MeasuredLyricTiming.posteriorgramWithBundledModel
    /// See `SongAnalysisPipeline.measureBeatGrid`.
    var measureBeatGrid: BeatGridMeasurer? = nil
    /// See `SongAnalysisPipeline.recognizeChords`.
    var recognizeChords: ChordStemRecognizer? = nil
    /// When true, a live separation run executes the BASE engine only and the pipeline runs the
    /// refiners itself, concurrently with transcription and harmony. Cache checks still use the
    /// full base+refiners recipe, so a previously completed refined document is still a hit.
    var defersRefinement: Bool = false
    /// Set by the pipeline for the harmony stage while deferred refinement is in flight: awaits
    /// the refined manifest (nil on refiner failure or cancellation, in which case harmony falls
    /// back to the un-refined stems it already has).
    var awaitRefinedStemSet: (@Sendable () async -> StemSetManifest?)? = nil
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
            if let stemEngine = context.effectiveStemEngine,
                context.isSeparationCacheHit(
                    currentEngine: stemEngine.metadata,
                    document: document,
                    sourceDigest: sourceDigest
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

            guard let stemEngine = context.effectiveStemEngine else {
                throw SongAnalysisPipelineError.missingStemEngine
            }
            let stageProgress = context.stageProgress
            let separationRequest = StemSeparationRequest(
                inputURL: context.request.sourceURL,
                outputDirectory: context.request.outputDirectory
            )
            let result: StemSeparationResult
            // The record must describe what THIS run actually produced: on the deferred path only
            // the base engine has run when this record is written, so it carries the base
            // metadata; the pipeline rewrites it to the full base+refiners identity only after
            // the refiners actually deliver. A record claiming "+refiners" over a manifest with
            // no children would poison the cache check.
            let recordMetadata: StemSeparationEngineMetadata
            if context.defersRefinement,
                let composite = stemEngine as? StemRefinementPipelineEngine
            {
                // Base only; the pipeline runs `composite.refine` concurrently with
                // transcription and harmony and merges the refined manifest afterwards.
                result = try await composite.separateBase(request: separationRequest) { value in
                    stageProgress(value.fractionCompleted, value.phase.rawValue)
                }
                recordMetadata = composite.baseEngine.metadata
            } else {
                result = try await stemEngine.separate(request: separationRequest) { value in
                    stageProgress(value.fractionCompleted, value.phase.rawValue)
                }
                recordMetadata = stemEngine.metadata
            }
            let stems = StoredStemFiles(files: result.stems)
            let stemSet = StoredStemSetManifest(manifest: result.stemSet)
            let configurationIdentifier =
                result.stemSet.recipeIdentity.map { "stem-recipe-\($0.stableStorageName)" }
                ?? "six-stem-44.1k-stereo"
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: .recording,
                engine: AnalysisEngineVersion(
                    identifier: recordMetadata.engineIdentifier,
                    version: recordMetadata.engineVersion
                ),
                modelIdentifier: recordMetadata.modelIdentifier,
                modelVersion: recordMetadata.modelVersion,
                configurationIdentifier: configurationIdentifier,
                confidence: nil
            )
            return AnalysisStageOutcome { document in
                document.stems = stems
                document.stemSet = stemSet
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

extension AnalysisStageContext {
    var effectiveStemEngine: (any StemSeparationEngine)? {
        guard let stemEngine else { return nil }
        guard !stemRefiners.isEmpty else { return stemEngine }
        return StemRefinementPipelineEngine(
            baseEngine: stemEngine,
            refiners: stemRefiners,
            sourceDigest: sourceDigest,
            segmentConfiguration: "six-stem-44.1k-stereo"
        )
    }

    var expectedStemRecipeIdentity: StemRecipeIdentity? {
        guard let stemEngine, !stemRefiners.isEmpty else { return nil }
        return StemRecipeIdentity(
            sourceDigest: sourceDigest,
            baseEngine: stemEngine.metadata,
            segmentConfiguration: "six-stem-44.1k-stereo",
            refiners: stemRefiners.map(\.cacheIdentity),
            taxonomyVersion: stemRefiners.map(\.taxonomyVersion).max() ?? 1,
            outputFormat: "wav"
        )
    }

    func isSeparationCacheHit(
        currentEngine: StemSeparationEngineMetadata,
        document: SongAnalysisDocument,
        sourceDigest: String
    ) -> Bool {
        let policy = SeparationCachingPolicy(currentEngine: currentEngine)
        if let expectedStemRecipeIdentity {
            return policy.isStemSetCacheHit(
                record: document.stageRecords[.separation],
                sourceDigest: sourceDigest,
                storedStemSet: document.stemSet,
                expectedRecipe: expectedStemRecipeIdentity
            )
        }
        return policy.isCacheHit(
            record: document.stageRecords[.separation],
            sourceDigest: sourceDigest,
            storedStems: document.stems
        )
    }
}

// MARK: - Transcription

/// Transcribes with EVERY installed engine and keeps, stretch by stretch, the words the vocal stem
/// best supports (`LyricStretchChooser`; Eric, 2026-09-28: reference-quality lyrics by default).
///
/// The requested mode runs first and exactly as before; its stage record, regions and the rest of
/// its document changes stand. Each other installed engine then runs the same stage for its words
/// alone. Skipped — the requested mode's lyrics kept — with reference lyrics (the user's words are
/// the words), without a vocals stem, when the requested mode did not succeed, or when the vocal
/// posteriorgram cannot be computed.
///
/// Measured on Doc Holiday against a reference lyric (2026-09-28, word recall / precision):
/// Whisper alone 0.647 / 0.605 with one line looped 7 times; stretch choice across Whisper and
/// both Parakeet profiles 0.738 / 0.746 with the reference's own three repeats.
struct MultiEngineTranscriptionStage: AnalysisStageRunning {
    let stage: SongAnalysisStage = .transcription

    func run(_ context: AnalysisStageContext) async -> AnalysisStageOutcome {
        let primary = await TranscriptionStage().run(context)
        let requested = context.request.transcriptionMode
        guard !primary.wasCancelled,
            context.document.referenceLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            let vocalsURL = context.document.stems?.resolved().vocals
        else { return primary }
        var primaryDocument = context.document
        primary.apply(&primaryDocument)
        guard primaryDocument.stageRecords[.transcription]?.state == .succeeded,
            !primaryDocument.lyrics.isEmpty
        else { return primary }
        let others = LyricBlendRowBuilder.modeOrder.filter {
            $0 != requested && context.transcriptionEngineFactory.engine(for: $0) != nil
        }
        guard !others.isEmpty,
            let logProbs = try? await Task.detached(
                priority: .userInitiated,
                operation: {
                    try context.vocalPosteriorgram(vocalsURL)
                }
            ).value
        else { return primary }
        // One engine resident at a time: the requested mode's model is done.
        await context.transcriptionEngineFactory.engine(for: requested)?.releaseResources()

        var lyricsByMode: [TranscriptionMode: [TimedLyricSegment]] = [
            requested: primaryDocument.lyrics
        ]
        for mode in others {
            guard !Task.isCancelled else { return primary }
            var request = context.request
            request.transcriptionMode = mode
            let modeContext = AnalysisStageContext(
                request: request, document: context.document, sourceDigest: context.sourceDigest,
                digest: context.digest, cache: context.cache, stemEngine: context.stemEngine,
                stemRefiners: context.stemRefiners,
                transcriptionEngineFactory: context.transcriptionEngineFactory,
                harmonyEngine: context.harmonyEngine, chordProBuilder: context.chordProBuilder,
                chordProReplacementPolicy: context.chordProReplacementPolicy,
                stageProgress: context.stageProgress,
                measureWordTimes: context.measureWordTimes,
                vocalPosteriorgram: context.vocalPosteriorgram)
            let outcome = await TranscriptionStage().run(modeContext)
            await context.transcriptionEngineFactory.engine(for: mode)?.releaseResources()
            guard !outcome.wasCancelled else { return primary }
            var modeDocument = context.document
            outcome.apply(&modeDocument)
            if modeDocument.stageRecords[.transcription]?.state == .succeeded {
                lyricsByMode[mode] = modeDocument.lyrics
            }
        }
        guard lyricsByMode.count > 1 else { return primary }

        let voiced =
            (try? await AudioFileAnalysisService().vocalActivityIntervals(url: vocalsURL)) ?? []
        let choice = LyricStretchChooser.chosen(
            lyricsByMode, logProbs: logProbs, voiced: voiced,
            preference: [requested] + others)
        let counts = Dictionary(grouping: choice.choices, by: \.mode).mapValues(\.count)
        AnalysisResourceLog.checkpoint(
            stage: "lyric-choice",
            event: "stretches=\(choice.choices.count) "
                + LyricBlendRowBuilder.modeOrder.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }
                .joined(separator: " "))
        let rows = LyricBlendRowBuilder.buildRows(
            fastDraft: lyricsByMode[.fastDraft] ?? [],
            balancedDraft: lyricsByMode[.balancedDraft] ?? [],
            accuracy: lyricsByMode[.accuracy] ?? [], qwen: lyricsByMode[.qwen] ?? [])
        return AnalysisStageOutcome { document in
            primary.apply(&document)
            document.lyrics = choice.lyrics
            document.lyricBlendRows = rows
        }
    }
}

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
            // Pitch-preserved slow-decode (Accuracy/Whisper only): transcribe a slowed copy of the
            // vocals to help fast/dense singing, then map timestamps back. Part of the cache key so
            // changing it re-transcribes; constant 1.0 for other modes so it never disturbs them.
            let decodeRate =
                request.transcriptionMode == .accuracy
                ? OfflineExportSettings.timeStretchRate(
                    min(max(request.transcriptionDecodeRate, 0.5), 1.0)) : 1.0
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
                    request.transcriptionMode == .accuracy
                        ? "decode3-\(String(format: "%.4f", decodeRate))-opening-rescue-gap-rescue-2-loop-guard-1"
                        : "decode2-\(String(format: "%.4f", decodeRate))-gap-rescue-2-loop-guard-1",
                    request.transcriptionLanguage.map { "language-\($0)" } ?? "auto",
                ].joined(separator: "|")
            )
            // Strict VAD is needed both for the decode-collapse check below and for the tail
            // gates further down — computed once here.
            let strictVAD = VocalActivityEnvelope.Configuration.strictVocalPresence
            let strictVoiced =
                (try? VocalActivityEnvelope.voicedIntervals(
                    url: audioURL, configuration: strictVAD)) ?? []
            let vocalOnset: TimeInterval? =
                hasStems ? (try? VocalOnsetDetector.firstOnset(url: audioURL)) : nil
            // Sung evidence for the wordless-gap rescue and the untranscribed-region flags below.
            // On the vocals stem it is PITCH salience, not energy — the energy-only strict VAD
            // both flagged loud-section bleed as unsung vocals (phantom "vocals — not
            // transcribed" on true instrumentals) and missed soft melodic vocals entirely
            // (Settle Down's doo-doo intro, below the peak-relative gate). Full-mix fallback
            // keeps strict VAD: on a mix, everything is pitched.
            let sungEvidence =
                hasStems
                ? ((try? VocalPitchSalience.sungIntervals(url: audioURL)) ?? strictVoiced)
                : strictVoiced
            // Vocal-stem onsets: the decode-loop guard's acoustic check and the final onset snap.
            let stemOnsets: [TimeInterval] =
                hasStems ? ((try? InstrumentOnsetDetector.onsets(url: audioURL)) ?? []) : []

            /// One transcription pass at `rate` (slow-rendering a temp copy when < 1.0), with
            /// timestamps mapped back to the real timeline.
            func transcribeOnce(rate requestedRate: Double) async throws -> TranscriptionResult {
                // The rate the time-stretch really plays, so timestamps map back without drift.
                let rate = OfflineExportSettings.timeStretchRate(requestedRate)
                let requestID = UUID()
                let usesSlowDecode = rate < 0.999
                let decodeURL: URL
                if usesSlowDecode {
                    stageProgress(0, "preparingAudio")
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent("decode-\(requestID.uuidString).wav")
                    try await OfflineAudioExporter().export(
                        sourceURL: audioURL, destinationURL: temporary,
                        settings: OfflineExportSettings(pitchSemitones: 0, tempoRate: rate))
                    decodeURL = temporary
                } else {
                    decodeURL = audioURL
                }
                defer {
                    if usesSlowDecode { try? FileManager.default.removeItem(at: decodeURL) }
                }
                let rawResult: TranscriptionResult
                do {
                    rawResult = try await engine.transcribe(
                        request: TranscriptionRequest(
                            id: requestID,
                            audioURL: decodeURL,
                            localeIdentifier: request.transcriptionLanguage
                        )
                    ) { value in
                        stageProgress(value.fractionCompleted, value.phase.rawValue)
                    }
                } catch is CancellationError {
                    await engine.cancel(requestID: requestID)
                    throw CancellationError()
                }
                // Map slowed-decode timestamps back onto the real timeline before caching/use.
                // The slowed file runs at `rate` of normal speed, so a slowed-time t maps to
                // real time t * rate (e.g. 0.85). (Earlier 1/rate over-stretched the timeline
                // and pushed later verses past the song's end.)
                return usesSlowDecode
                    ? TranscriptionTimeScaler.scaled(rawResult, by: rate)
                    : rawResult
            }

            /// One region of `source` (the vocals stem by default), decoded at the same Accuracy
            /// decode rate as the full pass, with times relative to the region start.
            func transcribeRegion(
                _ range: ClosedRange<TimeInterval>, phase: String = "retryingOpeningPhrase",
                from source: URL? = nil
            ) async throws
                -> TranscriptionResult
            {
                let requestID = UUID()
                let regionURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("opening-retry-\(requestID.uuidString).wav")
                let slowedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("opening-retry-slow-\(requestID.uuidString).wav")
                defer {
                    try? FileManager.default.removeItem(at: regionURL)
                    try? FileManager.default.removeItem(at: slowedURL)
                }
                stageProgress(0, phase)
                try AudioRegionExporter().export(
                    sourceURL: source ?? audioURL,
                    destinationURL: regionURL,
                    range: range
                )
                let usesSlowDecode = decodeRate < 0.999
                if usesSlowDecode {
                    try await OfflineAudioExporter().export(
                        sourceURL: regionURL, destinationURL: slowedURL,
                        settings: OfflineExportSettings(pitchSemitones: 0, tempoRate: decodeRate))
                }
                do {
                    let raw = try await engine.transcribe(
                        request: TranscriptionRequest(
                            id: requestID, audioURL: usesSlowDecode ? slowedURL : regionURL,
                            localeIdentifier: request.transcriptionLanguage)
                    ) { value in
                        stageProgress(value.fractionCompleted, value.phase.rawValue)
                    }
                    let mapped =
                        usesSlowDecode ? TranscriptionTimeScaler.scaled(raw, by: decodeRate) : raw
                    return DecodeLoopGuard.removingLoops(
                        mapped, vocalOnsets: stemOnsets.map { $0 - range.lowerBound }
                    ).result
                } catch is CancellationError {
                    await engine.cancel(requestID: requestID)
                    throw CancellationError()
                }
            }

            let result: TranscriptionResult
            let loadedFromCache: Bool
            var cachedResult: TranscriptionResult? = try await context.cache?.value(
                forSourceHash: audioDigest,
                engine: cacheEngine
            )
            // Self-heal poisoned caches: a collapsed decode may already be cached from before
            // the rescue existed. Treat a cached low-coverage Accuracy result as a miss so
            // re-analyzing re-transcribes (and the rescue below can fix it) instead of
            // returning the truncated lyrics forever.
            if let cached = cachedResult, request.transcriptionMode == .accuracy,
                let coverage = TranscriptionVoicedCoverage.fraction(
                    of: cached, voicedIntervals: strictVoiced),
                coverage < 0.6
            {
                cachedResult = nil
            }
            if let cached = cachedResult {
                result = cached
                loadedFromCache = true
                stageProgress(1, "loadedFromCache")
            } else {
                var transcribed = DecodeLoopGuard.removingLoops(
                    try await transcribeOnce(rate: decodeRate), vocalOnsets: stemOnsets
                ).result
                // Decode-collapse rescue: whisper.cpp sometimes aborts mid-file at normal
                // speed — it emits the early segments, then skips to the outro, silently
                // dropping the middle of the song. When the transcription covers far less
                // of the strictly-voiced audio than the VAD hears, retry ONCE at 0.85×
                // (the slowed decode reliably recovers these songs) and keep the better
                // result. Whisper/Accuracy only; never triggered by short instrumentals.
                if request.transcriptionMode == .accuracy, decodeRate > 0.999,
                    let coverage = TranscriptionVoicedCoverage.fraction(
                        of: transcribed, voicedIntervals: strictVoiced),
                    coverage < 0.6
                {
                    stageProgress(0, "retryingSlowedDecode")
                    if let unguarded = try? await transcribeOnce(rate: 0.85),
                        case let retry = DecodeLoopGuard.removingLoops(
                            unguarded, vocalOnsets: stemOnsets
                        ).result,
                        let retryCoverage = TranscriptionVoicedCoverage.fraction(
                            of: retry, voicedIntervals: strictVoiced),
                        retryCoverage > coverage
                    {
                        transcribed = retry
                    }
                }
                if request.transcriptionMode == .accuracy,
                    let vocalOnset,
                    let retryRange = SparseOpeningTranscriptionRescuer.retryRange(
                        for: transcribed,
                        vocalOnset: vocalOnset
                    )
                {
                    do {
                        let retry = try await transcribeRegion(retryRange)
                        transcribed = SparseOpeningTranscriptionRescuer.merged(
                            primary: transcribed,
                            retry: retry,
                            retryStart: retryRange.lowerBound,
                            replacementEnd: transcribed.segments.dropFirst().first?.startTime
                                ?? retryRange.upperBound
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Optional quality rescue: retain the complete primary pass on failure.
                    }
                }
                // Wordless-gap rescue: re-transcribe each sung stretch the pass heard no words
                // in, on a clip with 1 s either side. Stems only — on a full mix everything is
                // voiced, so every instrumental would be retried and hallucinated over.
                if hasStems {
                    for gap in WordlessVocalGapRescuer.gaps(
                        in: transcribed, sungIntervals: sungEvidence)
                    {
                        let start = max(gap.lowerBound - 1, 0)
                        let end = max(
                            gap.upperBound, min(gap.upperBound + 1, transcribed.sourceDuration))
                        do {
                            let retry = try await transcribeRegion(
                                start...end, phase: "retryingWordlessGaps")
                            var rescued = WordlessVocalGapRescuer.merged(
                                primary: transcribed, retry: retry, retryStart: start, gap: gap,
                                sungIntervals: sungEvidence)
                            // The stem can lose a soft phrase the mix still carries: retry the
                            // same region on the original recording, with the same evidence rule.
                            if rescued == transcribed, request.sourceURL != audioURL {
                                let mixRetry = try await transcribeRegion(
                                    start...end, phase: "retryingWordlessGaps",
                                    from: request.sourceURL)
                                rescued = WordlessVocalGapRescuer.merged(
                                    primary: transcribed, retry: mixRetry, retryStart: start,
                                    gap: gap, sungIntervals: sungEvidence)
                            }
                            transcribed = rescued
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Optional quality rescue: keep the full pass on failure.
                        }
                    }
                }
                result = transcribed
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
                    // "|blend-row-overlap-merge": LyricBlendRowBuilder.mergeCrossModeDuplicates
                    // gained a fallback overlap-merge pass (2026-07-06) that resolves stale
                    // cached per-mode segments differently than before (Key West Bar field
                    // case: two disjoint-mode clusters that overlap in time — one a run-on,
                    // the other an orphaned single-mode fragment — now merge into one row
                    // instead of printing as scrambled/doubled words). Without this tag,
                    // songs analyzed before the fix keep their stale, already-corrupted
                    // `lyricBlendRows` forever, since re-clicking "Analyze Song" only
                    // re-groups when the stage record's version actually changes.
                    version: result.engine.engineVersion
                        + "|grouping-50-torn-continuation-rejoin"
                        + "|blend-row-overlap-merge"
                        + "|untranscribed-2-pitch-salience"
                        + "|line-tail-sustain-1"
                        + "|words-stay-on-asr-times-1"
                        + "|no-start-shifts-1"
                        + "|forced-alignment-1"
                        + "|pitch-supported-gate-1"
                        + "|mix-no-energy-gate-1"
                        + "|line-overlap-clip-1"
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
            // When stems exist, drop outro tokens after
            // the last detected vocal offset before grouping.
            let sourceDuration = result.sourceDuration
            let normalizedDuration = sourceDuration > 0 ? sourceDuration : nil
            // Every vocal onset on the stem, used to snap each word to the actual energy burst in
            // the final timing pass below. Only meaningful on the isolated vocals stem.
            let vocalOnsets = stemOnsets
            let detectedOffset: TimeInterval? =
                hasStems ? (try? VocalOffsetDetector.lastOffset(url: audioURL)) : nil
            // strictVoiced computed once above (also feeds the decode-collapse rescue).
            // Energy VAD is vocal evidence only on an isolated vocals stem. It is peak-relative, so
            // on a full mix it hears a fraction of a second of "voice" (Summertime's mix: 0.3 s at
            // 78.5 s) and the tail cutoff and hallucination gate below deleted 167 of 168 Whisper
            // words (corpus baseline, 2026-09-15). Without stems nothing is deleted on its say-so.
            let gatingVoiced = hasStems ? strictVoiced : []
            let tailCutoff = VocalTailCutoffResolver.resolve(
                detectedOffset: detectedOffset,
                strictVoicedIntervals: gatingVoiced,
                sourceDuration: normalizedDuration)
            // Pitch-supported singing past the energy offset is kept: nothing is cut unless both
            // energy and pitch evidence say the voice has stopped.
            let pitchEvidence = hasStems ? sungEvidence : []
            let vocalOffset = VocalHallucinationGate.pitchExtended(
                tailCutoff.effectiveOffset, sungIntervals: pitchEvidence)
            var segmentsForGrouping = result.segments
            if let vocalOffset {
                segmentsForGrouping = TranscriptionOnsetCorrection.preparedSegments(
                    segmentsForGrouping, droppingSegmentsStartingAtOrAfter: vocalOffset)
                segmentsForGrouping = TranscriptionOnsetCorrection.preparedSegments(
                    segmentsForGrouping, droppingAfter: vocalOffset)
            }
            // Drop bare clock/timestamp tokens ("0:00", "00:00", ...) BEFORE the silence gate: a
            // well-documented Whisper hallucination that isn't always isolated by silence on both
            // sides (sometimes stitched onto the end of an otherwise-real line), so it needs a
            // content-based rule rather than relying on TranscriptionSilenceGate's isolation
            // heuristic to catch it.
            let timestampFiltered = TimestampHallucinationFilter.filtered(
                segmentsForGrouping.flatMap(\.tokens))
            let gatedTokens = TranscriptionSilenceGate.filtered(
                timestampFiltered,
                sourceDuration: sourceDuration > 0 ? sourceDuration : nil)
            // Respect the transcriber's segment boundaries as line breaks: Whisper segments per
            // sung line (with ~zero word gaps), so without this its lines run on; Parakeet emits a
            // single segment, so this is a no-op and its lines still come from the grouping rules.
            let groupedRaw = TimedLyricSegmentGrouper.group(
                tokens: gatedTokens,
                lineStartOnsets: TimedLyricSegmentGrouper.lineStartOnsets(of: segmentsForGrouping))
            // Collapse within-line repetition hallucinations (a phrase looped to fill one line).
            let rawGroupedLyrics = RepeatedPhraseCollapser.collapse(groupedRaw)
            // TEXT first: if the user supplied reference lyrics, replace the (error-prone) ASR words
            // with their exact words/lines, borrowing ASR timings as a starting point. Otherwise fix
            // garbled words in REPEATED lines (choruses) by cross-line ≥2/3 consensus — recovers
            // e.g. "slip flops"→"flip flops", "biccuyeckle"→"barbecue" when most repeats heard it
            // right. (No-op without ≥3 similar lines or a clear majority; reference lyrics override.)
            let reference = context.document.referenceLyrics
            let textCorrected =
                reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? RepeatedLyricCorrector().corrected(rawGroupedLyrics)
                : ReferenceLyricAligner.align(
                    referenceText: reference, asrSegments: rawGroupedLyrics)
            // TIMING: words keep the transcriber's times and move only onto a vocal-stem onset
            // (`VocalWordOnsetAligner`, below) — Eric, 2026-09-14: words are "locked immutably to
            // the vocal timeline". Spreading each line's words across strict-VAD voiced regions
            // (the removed `distributeAcrossSignal`) packed Beach Weather's correctly timed
            // opening into 0.3 s and pushed a chorus line 6 s late where the VAD missed singing.
            // The other start-shifting steps (intro re-anchor, stranded-word repair, torn-line
            // rejoin, late-onset pullback) are gone too — "There should be NO shifting code." Only
            // the ±0.15 s onset snap and held-note end extensions remain, by Eric's choice.
            let referenceEmpty =
                reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let lyrics: [TimedLyricSegment]
            if !gatingVoiced.isEmpty {
                let voicedForGating = VocalActivityEnvelope.voicedIntervalsForGating(
                    gatingVoiced, trailingCutoff: vocalOffset)
                // On the pure-ASR path, definitively drop any line with NO real vocal under it —
                // hallucinations over instrumental intro/breaks/outro. With reference lyrics the
                // words are user-supplied, so never gate.
                if referenceEmpty {
                    let lastVoicedEnd = VocalHallucinationGate.pitchExtended(
                        tailCutoff.lastVoicedEnd ?? voicedForGating.map(\.upperBound).max(),
                        sungIntervals: pitchEvidence)
                    var gated = VocalHallucinationGate.filtered(
                        textCorrected,
                        voicedIntervals: voicedForGating,
                        trailingCutoff: vocalOffset,
                        lastVoicedEnd: lastVoicedEnd,
                        sungIntervals: pitchEvidence)
                    gated = TrailingLyricTailPruner.pruned(
                        gated, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset,
                        sourceDuration: normalizedDuration)
                    gated = TrailingDuplicateLineCollapser.collapsed(
                        gated, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset)
                    gated = TrailingEarlierLyricRepeater.filtered(
                        gated, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset,
                        sourceDuration: normalizedDuration)
                    // Split double-phrase ASR lines at long UNVOICED internal pauses so a
                    // chorus line pair doesn't render as one double-length line. ASR path
                    // only — reference lyrics carry authoritative line breaks.
                    lyrics = IntraLinePauseSplitter.split(
                        gated, voicedIntervals: voicedForGating)
                } else {
                    lyrics = textCorrected
                }
            } else {
                lyrics = textCorrected
            }
            // MEASURE the word times. Up to here the times are the transcriber's, which are a
            // by-product of decoding rather than a measurement — the failure that put nine words
            // at 0.00 s against singing that began at 18.8 s. Forced alignment takes the words as
            // known and finds where each is sung, from the audio. There is no fallback to the
            // transcriber's times (Eric, 2026-09-26): words with no vocals stem to measure on, a
            // missing model, or a failed alignment fail the stage.
            let hasWords = lyrics.contains { !$0.words.isEmpty }
            guard !hasWords || hasStems else {
                throw SongAnalysisPipelineError.noVocalsStemToMeasureLyrics
            }
            let measured =
                hasWords
                ? try context.measureWordTimes(lyrics, audioURL, vocalOnsets)
                : (lyrics: lyrics, outcome: MeasuredLyricTiming.Outcome())
            // Counts only, never text. `unmeasured` words are stored with no time.
            AnalysisResourceLog.checkpoint(
                stage: "word-timing",
                event: "ran=\(measured.outcome.ran) measured=\(measured.outcome.measured)"
                    + " from-onsets=\(measured.outcome.filledFromOnsets)"
                    + " unmeasured=\(measured.outcome.unmeasured)")
            // FINAL precision pass: snap each word's onset to the nearest vocal-stem energy onset
            // so words (and everything anchored to them — the ChordPro strip, the bouncing ball,
            // and chords placed over words) land on the actual vocal energy. No-op without a
            // vocals stem (`vocalOnsets` empty).
            let alignedLyrics = VocalWordOnsetAligner.snapped(
                measured.lyrics, toOnsets: vocalOnsets)
            // Melisma repair (audit RC-3): bridge held words across continuously-voiced
            // inter-word gaps, so held notes stop rendering as phantom mid-line pauses. Runs LAST, on the final
            // word timings. No-op when strict VAD is unavailable.
            let spanNormalizedLyrics = VocalWordSpanNormalizer.normalized(
                alignedLyrics, voicedIntervals: strictVoiced)
            // NOTE: `LyricConfidencePlaceholder` is deliberately NOT applied here. The document
            // stores the transcriber's actual words plus each word's confidence; blanking is a
            // PRESENTATION concern applied where lyrics are shown. Baking it in here corrupted
            // every artifact derived from `lyrics` — `chordProSource` and the exported .cho
            // (ChordProDraftBuilder reads `segment.text`), the persisted `lyricBlendRows`, and
            // `ChorusChordConsensus`, which groups lines by identical normalized text and would
            // let two different lines that both blanked to `___` vote on each other's CHORDS.
            // Worst of all, "Fill from current transcription" promotes this text into
            // `referenceLyrics`, the authoritative alignment target for every later analysis —
            // and reference-aligned words carry no confidence, so it could never be undone.
            // Sung spans with no words (audit RC-4): persist so structure decisions and the
            // chart can flag them instead of mislabeling them Instrumental (`sungEvidence`,
            // computed above).
            // Line-final held notes: extend each line's last word through the sung note it ends
            // inside. Stems only — on a full mix everything is voiced, so every line would
            // stretch into the instrumental after it.
            let normalizedLyrics =
                hasStems
                ? LineTailSustainExtender.extended(
                    spanNormalizedLyrics, sungIntervals: sungEvidence)
                : spanNormalizedLyrics
            let untranscribed = UntranscribedVocalRegionDetector.regions(
                voicedIntervals: sungEvidence, lyrics: normalizedLyrics)
            let finalLyrics = LyricLineOverlapClipper.clipped(normalizedLyrics)
            return AnalysisStageOutcome { document in
                document.lyrics = finalLyrics
                // Fresh lyrics change the reconciler's line-onset evidence; drop the stamp so
                // `AnalysisTimingPostPasses` re-derives (from the raw beats it restores itself).
                document.timingPostPassTag = nil
                document.untranscribedVocalRegions = untranscribed
                document.sourceDuration = sourceDuration > 0 ? sourceDuration : nil
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

/// How much of the strictly-voiced (sung) audio a transcription's segments actually cover.
/// Detects whisper.cpp decode collapses: a healthy transcription covers nearly all sung time;
/// an aborted one (early segments, then a jump to the outro) covers a small fraction.
enum TranscriptionVoicedCoverage {
    /// Fraction in 0…1, or nil when there's no voiced audio to measure against.
    static func fraction(
        of result: TranscriptionResult,
        voicedIntervals: [ClosedRange<TimeInterval>]
    ) -> Double? {
        guard !voicedIntervals.isEmpty else { return nil }
        let voicedTotal = voicedIntervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard voicedTotal > 0 else { return nil }
        // Words, not segment spans, and each word only for as long as it can stand for singing
        // (`WordlessVocalGapRescuer.supportedSpan`, padded 0.25 s): a stretched token or a long
        // segment would otherwise count a skipped phrase as covered. Merged so overlaps never
        // double-count.
        let spans = result.segments.flatMap(\.tokens)
            .map {
                let span = WordlessVocalGapRescuer.supportedSpan(
                    start: $0.startTime, end: $0.endTime, text: $0.text)
                return (start: span.lowerBound - 0.25, end: span.upperBound + 0.25)
            }
            .sorted { $0.start < $1.start }
        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        var covered = 0.0
        for voiced in voicedIntervals {
            for span in merged {
                covered += max(
                    0, min(voiced.upperBound, span.end) - max(voiced.lowerBound, span.start))
            }
        }
        return covered / voicedTotal
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
        guard let stems = context.document.stems?.resolved() else { return nil }
        let bassURL = stems.bass
        guard let notes = try? bassLineAnalyzer.analyze(url: bassURL), !notes.isEmpty else {
            return nil
        }
        return notes
    }

    private func detectVocalHarmonies(_ context: AnalysisStageContext)
        async -> [VocalHarmonyObservation]?
    {
        guard (try? Task.checkCancellation()) != nil else { return nil }
        // Deferred refinement: the lead/backing stems may still be separating when this — the
        // tail of the harmony stage — is reached. Wait for them HERE rather than before the
        // stage: everything above this point reads only base stems. A nil result (refiner failed
        // or cancelled) degrades to the whole-vocals path below, same as no refiner at all.
        var refinedManifest: StemSetManifest?
        if let awaitRefined = context.awaitRefinedStemSet {
            context.stageProgress(0.88, "waiting for voice stems")
            refinedManifest = await awaitRefined()
        }
        let vocalSources = vocalHarmonySources(
            in: context.document, refinedManifest: refinedManifest)
        guard !vocalSources.isEmpty else { return nil }
        let analyzer = VocalHarmonyAnalyzer(
            maximumNotesPerFrame: Self.vocalHarmonyMaximumVoices())
        var observations: [VocalHarmonyObservation] = []
        for (index, source) in vocalSources.enumerated() {
            guard
                let notes = try? analyzer.analyze(
                    url: source.url,
                    sourceID: source.id,
                    voiceIndex: index
                )
            else { continue }
            observations.append(contentsOf: notes)
        }
        let withIntervals = VocalHarmonyAnalyzer.addIntervals(observations)
        guard !withIntervals.isEmpty else { return nil }
        // Voice identity is decided ONCE here, across the whole song and all vocal stems, and
        // persisted on each observation. The Review pane then just reads it.
        return VocalHarmonyAnalyzer.assigningVoices(
            withIntervals,
            maximumVoices: Self.vocalHarmonyMaximumVoices())
    }

    private func vocalHarmonySources(
        in document: SongAnalysisDocument,
        refinedManifest: StemSetManifest? = nil
    )
        -> [(id: StemID, url: URL)]
    {
        if let manifest = refinedManifest ?? document.stemSet?.resolved() {
            let assets = manifest.assetsByID
            let children = manifest.descriptors
                .filter { descriptor in
                    descriptor.parentID == StemID(.vocals)
                        && assets[descriptor.id] != nil
                        && (descriptor.id == .vocalLead
                            || descriptor.id == .vocalBacking
                            || descriptor.id.rawValue.contains("harmony"))
                }
                .sorted { lhs, rhs in
                    if lhs.order == rhs.order { return lhs.id < rhs.id }
                    return lhs.order < rhs.order
                }
                .compactMap { descriptor -> (id: StemID, url: URL)? in
                    guard let asset = assets[descriptor.id] else { return nil }
                    return (descriptor.id, asset.audioURL)
                }
            if !children.isEmpty { return children }
            if let asset = assets[StemID(.vocals)] { return [(StemID(.vocals), asset.audioURL)] }
        }
        if let vocals = document.stems?.resolved().vocals {
            return [(StemID(.vocals), vocals)]
        }
        return []
    }

    private static func vocalHarmonyMaximumVoices() -> Int {
        let key = VocalHarmonyPreferences.maximumVoicesUserDefaultsKey
        let stored =
            UserDefaults.standard.object(forKey: key) as? Int
        return VocalHarmonyPreferences.clampedMaximumVoices(
            stored ?? VocalHarmonyPreferences.defaultMaximumVoices)
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
        let vocalHarmonyMaximumVoices = Self.vocalHarmonyMaximumVoices()

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
            let rawResult: SongAudioAnalysis
            let loadedFromCache: Bool
            if let cached: SongAudioAnalysis = try await cache?.value(
                forSourceHash: sourceHash,
                engine: cacheEngine
            ) {
                rawResult = cached
                loadedFromCache = true
            } else {
                // Weighted stem mix, not a single file: guitar leads, piano supports, and the
                // leakage gate drops a phantom stem before it can double-count the guitar. The
                // mix is reflected in `source.configurationIdentifier`, which is part of the
                // cache key above — so a weighting change re-analyses instead of reusing a chord
                // analysis derived from different audio.
                rawResult = try await harmonyEngine.analyze(weighted: source.weightedURLs)
                try await cache?.store(rawResult, forSourceHash: sourceHash, engine: cacheEngine)
                loadedFromCache = false
            }
            // Chord evidence only where a chordal instrument is actually sounding. Cosine chord
            // scoring is blind to level, so the residue in resting stems (the vocal harmony, on an
            // a cappella stretch) scored as confidently as playing. Applied to the cached raw
            // frames, so it needs no re-chroma. Stems only: on a full-mix fallback the voice is in
            // the signal and a level says nothing about the instruments.
            // The ONE stem the chord line listens to (Eric, 2026-10-07: "it's critical that only
            // the guitar stem be used"): the player `analyze(weighted:)` chose — guitar, else the
            // instrument that does play. Its chroma is the only label evidence, and it alone
            // licenses, places and gates changes below. Piano attacks, bass onsets and bass
            // re-rooting each added changes the guitarist never played.
            let chordStem: URL? = {
                guard let stems = context.document.stems?.resolved() else { return nil }
                switch rawResult.chordInstrument.flatMap(StemKind.init) {
                case .guitar: return stems.guitar
                case .piano: return stems.piano
                default: return stems.guitar ?? stems.piano
                }
            }()
            let result: SongAudioAnalysis = {
                // No chords where the chord player rests. A legacy stem set with neither player
                // has nobody to attribute to, and is left as it was.
                guard let chordStem else { return rawResult }
                return SongAudioAnalysis(
                    beat: rawResult.beat,
                    chords: ChordalRestGate.applied(to: rawResult.chords, stemURLs: [chordStem]),
                    estimatedKey: rawResult.estimatedKey,
                    harmonicChangePoints: rawResult.harmonicChangePoints)
            }()
            try Task.checkCancellation()
            stageProgress(0.75, "reducing chords")
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: source.kind,
                // Reducer-version suffix: changes the stage record (so re-analysis re-reduces the
                // cached raw chord observations into events) WITHOUT changing the raw chroma cache
                // key — so no re-chroma is needed when only the ChordEventReducer changes.
                engine: AnalysisEngineVersion(
                    identifier: harmonyEngine.metadata.identifier,
                    version: harmonyEngine.metadata.version
                        // reduce-17: record every placement candidate on each event (beat-
                        // quantized and onset-snapped) so they can be A/B'd against the audio.
                        // Rendered times are unchanged; existing songs re-reduce to gain the
                        // candidates, which is why this needs a version bump at all.
                        + "|reduce-17-placement-candidates"
                        // reduce-18: one-to-one evidence audit (ChordEvidenceAudit) drops chord
                        // markers with no instrument attack and no stable harmonic change under
                        // them. This CHANGES rendered output, so existing songs must re-reduce.
                        + "|reduce-18-evidence-audit"
                        // reduce-19: the audit's harmonic evidence now comes from chroma
                        // change-points rather than frame-label flips. Old cached analyses have
                        // no change-points and keep the label fallback until re-analysed.
                        + "|reduce-19-changepoint-evidence"
                        // reduce-20: quality audit reverts key-prior major/minor overrides from
                        // the frame classifier's own reading of the third, and the repeated-
                        // section vote can no longer flip a confirmed third back.
                        + "|reduce-20-quality-audit"
                        // reduce-21: attack onsets now merge EVERY chordal stem (guitar, piano,
                        // other) instead of just the first one present, so a piano- or
                        // organ-struck chord can license a change and survive the evidence audit.
                        + "|reduce-21-merged-onsets"
                        // reduce-22: duration filter floor 0.8 -> 0.25 of a beat, so a genuine
                        // beat-length change is no longer merged into its predecessor.
                        + "|reduce-22-minbeat-025"
                        // reduce-23: decode on a subdivided grid so a chord change inside a beat
                        // is representable at all.
                        + "|reduce-23-subbeat-decode"
                        // reduce-24: decode grid extended back over a pre-drums intro; per-frame
                        // window evidence so the no-chord floor stops being tempo-dependent.
                        + "|reduce-24-intro-and-nochord"
                        // reduce-25: persist vocal harmony note observations for the Review
                        // pane's optional Harmonies row. Raw chroma cache remains reusable.
                        + "|reduce-25-vocal-harmonies"
                        // reduce-26: harmony detection/display defaults to four voices for choir
                        // use cases, with a persisted 2/3/4 max-voices control.
                        + "|reduce-26-harmony-max-voices"
                        // reduce-27: each harmony observation carries a harmonic-envelope
                        // timbre fingerprint, so voice rows cluster by singer instead of pitch.
                        + "|reduce-27-vocal-timbre"
                        // reduce-28: voice identity is assigned once per song (partitioned by
                        // vocal stem, then subdivided by timbre) and persisted, instead of being
                        // re-clustered inside every lyric-line window at display time.
                        + "|reduce-28-song-level-voices"
                        // reduce-29: evidence audit treats stable frame-label changes as
                        // harmonic even when chroma change-points exist (slow G–D–C walks
                        // never spike frame-to-frame cosine), and drops sub-beat
                        // attack-only markers licensed by jangly picking.
                        + "|reduce-29-label-harmonic-and-attack-sliver"
                        // reduce-30: a refined kick (when available) phase-locks the steady beat
                        // grid. Mixed drums contain fills and cymbal attacks that must not make
                        // the practice metronome wander from beat to beat.
                        + "|reduce-30-kick-steady-grid"
                        // reduce-31: the steady grid's tempo is resolved on the drum onsets past
                        // the tracker's integer-lag quantization (`DrumBeatGrid.refinedBPM`); at
                        // the quantized tempo the rigid grid rotated off the drums on every song.
                        + "|reduce-31-refined-tempo"
                        // reduce-32: no chord evidence where every chordal stem rests
                        // (`ChordalRestGate`), and a bass stem that is only a shadow of the singing
                        // yields no bass notes (`VocalShadowGate`), so none reach the decoder either.
                        + "|reduce-32-rests-and-vocal-shadow"
                        // reduce-33: `other` is in or out per song. Where it carries a tenth of the
                        // song alone, frames with guitar + piano resting take their chord evidence
                        // from it (`ChordSourceFallback`) and it counts in the rest test; otherwise
                        // it is excluded from both.
                        + "|reduce-33-other-when-significant"
                        // reduce-34: a chord must be attributable to the guitarist or the pianist.
                        // `other` is out of the chord source and the rest test on every song.
                        + "|reduce-34-guitar-or-piano-only"
                        // reduce-35: a chord event starts at the first window with evidence for it
                        // (no backfilling into a rest); attacks come from guitar + piano only and
                        // count only where those stems are sounding.
                        + "|reduce-35-chords-arrive-with-the-strum"
                        // reduce-36: a drummer no rigid tempo fits is followed, when the followed
                        // grid proves itself on held-out onsets (`DrumBeatGrid.followedBeatTimes`).
                        + "|reduce-36-follow-a-drifting-drummer"
                        // reduce-37: beats, tempo and downbeats come from the bundled beat model
                        // on the whole recording (`BeatThisTracker`); the autocorrelation tracker
                        // picked 4/3 or 2x the real tempo on 8 of 14 album tracks.
                        + "|reduce-37-beat-model"
                        // reduce-38: the chord line listens to the chord player's stem alone —
                        // its attacks and rests only, no piano attacks, no bass cues or re-rooting.
                        + "|reduce-38-chord-player-only"
                        // reduce-39: every instrument its own source — no chorus vote over the
                        // chords, no vocal filter on the bass, bass notes not rounded to chords.
                        + "|reduce-39-independent-instruments"
                        // reduce-40: one chord chain for every instrument; changes on the nearest
                        // half-beat to the attack.
                        + "|reduce-40-half-beat-chord-line"
                        // reduce-41: the chord line comes from the bundled chord network
                        // (`ChordNetRecognizer`) on the chord player's stem.
                        + "|reduce-41-chord-network"
                ),
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier:
                    source.configurationIdentifier
                    + "|harmonies-max-\(vocalHarmonyMaximumVoices)",
                confidence: AnalysisStageRecordFactory.confidenceSummary(
                    result.chords.map(\.confidence)),
                loadedFromCache: loadedFromCache
            )
            // The bundled beat model on the whole recording, when the pipeline has it (the app
            // always does; tests have no bundle and keep the autocorrelation tracker below).
            stageProgress(0.80, "tracking beats")
            let modelGrid = try context.measureBeatGrid.map { try $0(context.request.sourceURL) }
            let trackedBPM: Double? = modelGrid?.bpm ?? result.beat?.bpm
            var refinedBPM = trackedBPM
            let beatTimes = modelGrid?.beatTimes ?? result.beat?.beatTimes ?? []
            // Phase-lock the steady practice grid to the refined kick when available. A kick may
            // mark every second or fourth beat, so the analysis BPM remains the tempo authority;
            // the kick only chooses phase. The mixed-drums fallback retains compatibility for
            // six-stem analyses that have no drum-piece refinement.
            var drumBeatTimes = beatTimes
            let timingStemURL =
                context.document.stemSet?.resolved().assetsByID[.drumKick]?.audioURL
                ?? context.document.stems?.resolved().drums
            if modelGrid == nil, let timingStemURL,
                let trackedBPM, trackedBPM > 0,
                let onsets = try? InstrumentOnsetDetector.onsets(url: timingStemURL),
                !onsets.isEmpty
            {
                // The tracker's tempo is quantized to an integer autocorrelation lag (~2 %); a
                // rigid grid at that tempo drifts whole beats over a song. Same metrical level,
                // resolved on the onsets — or unchanged when no rigid tempo fits.
                let bpm = DrumBeatGrid.refinedBPM(onsets: onsets, bpm: trackedBPM)
                let duration = max(onsets.last ?? 0, beatTimes.last ?? 0)
                let derived = DrumBeatGrid.beatTimes(onsets: onsets, bpm: bpm, duration: duration)
                if !derived.isEmpty {
                    // A drummer no rigid tempo fits is followed — only when the followed grid
                    // proves itself on onsets it was not fitted to (`followedBeatTimes`).
                    let followed = DrumBeatGrid.followedBeatTimes(onsets: onsets, rigid: derived)
                    drumBeatTimes = followed ?? derived
                    refinedBPM = bpm
                    AnalysisResourceLog.checkpoint(
                        stage: "beat-grid",
                        event: followed == nil ? "rigid" : "follows-the-drummer")
                }
            }
            let estimatedBPM = refinedBPM
            let resolvedBeatTimes = drumBeatTimes
            let estimatedKey: MusicalKey? =
                result.estimatedKey ?? MusicalKeyEstimator().estimate(from: result.chords)
            // Additive: detect the played bass line from the BASS stem (runs
            // whether or not the harmony chord result was a cache hit). A `nil`
            // result (no stem / failure) leaves existing bassNotes untouched.
            stageProgress(0.82, "detecting bass")
            // The bass stem's own notes. Every instrument is its own source (Eric, 2026-10-07):
            // the bass is not filtered against the vocals nor rounded to the guitar's chords.
            let detectedBassNotes = detectBassNotes(context)
            stageProgress(0.88, "detecting harmony notes")
            let detectedVocalHarmonyNotes = await detectVocalHarmonies(context)
            stageProgress(0.92, "aligning chord changes")
            // Attacks from the chord player's stem only: they license the decoder's cheaper
            // switches and are what change times snap to. Piano attacks under a guitar chord line
            // licensed changes the guitarist never made. A legacy stem set with no player keeps
            // its old sources. The detector thresholds against LOCAL level, so in near-silence it
            // fires on noise (Seven Bridges Road: "attacks" under a guitar at -60 dB); an attack
            // counts only where the player is sounding.
            let playerStems: [URL] = chordStem.map { [$0] } ?? []
            let onsetStems: [URL] = {
                guard playerStems.isEmpty, let stems = context.document.stems?.resolved() else {
                    return playerStems
                }
                return [stems.other, stems.accompaniment].compactMap { $0 }
            }()
            let instrumentOnsets: [TimeInterval] = ChordalRestGate.sounding(
                InstrumentOnsetDetector.mergedOnsets(urls: onsetStems), stemURLs: playerStems)
            // Key-aware Viterbi decoding over beat windows: a diatonic prior scales frame
            // evidence and a switch penalty smooths window-to-window flicker, with a no-chord
            // state absorbing weak-evidence windows (quiet intros/fades). Replaces independent
            // per-window voting, which let transient out-of-key chroma noise win 28% of the
            // events on the reference song. Switches landing on instrument onsets are charged
            // a reduced penalty so real one-beat changes survive the smoothing.
            // Harmonic-rhythm prior for the decoder: estimate the bar phase from drum-stem
            // accent energy at the resolved beats (kick/snare land on strong beats regardless
            // of where anything else enters), mirroring the preview's `refreshGrid` cue with
            // the same 0.08 confidence gate. Best-effort — an absent drums stem, degenerate
            // strengths, or a flat/ambiguous accent profile yields `nil` and the decoder keeps
            // its flat-metric behavior. 4/4 assumed, matching the rest of the pipeline.
            // The song's ONE bar grid, estimated here and stored on the document so the decoder,
            // the ChordPro builder, and the chart all read the same answer. Previously each
            // derived its own from a different signal — and the decoder additionally hard-coded
            // `beatsPerBar: 4`, so a non-4/4 song decoded on a different meter than it rendered
            // on.
            let drumStrengths: [Double] = {
                guard modelGrid == nil, let drumsURL = context.document.stems?.resolved().drums,
                    let bpm = estimatedBPM, bpm > 0
                else { return [] }
                return
                    (try? DrumAccentProfile.beatStrengths(
                        url: drumsURL, beatTimes: resolvedBeatTimes, bpm: bpm)) ?? []
            }()
            let barGrid =
                modelGrid?.barGrid
                ?? SongBarGridEstimator.estimate(
                    beatTimes: resolvedBeatTimes,
                    beatStrengths: drumStrengths,
                    lyricLineOnsets: context.document.lyrics.map {
                        $0.words.firstStart ?? $0.start
                    }
                )
            // The guitar's chord line runs the same chain as every other instrument's row
            // (`InstrumentChordPass.chordLine`): this stem's chords and attacks only, changes
            // placed on the nearest half-beat to the attack. The chord network names the chords
            // (Eric, 2026-10-07); the template chain stays only for tests, which have no model.
            let modelSegments = try chordStem.flatMap { stem in
                try context.recognizeChords.map { try $0(stem) }
            }
            // The template chain's audits describe only its own line, so they warn only for it.
            let alignedChords: [EditableChordEvent]
            let auditWarnings: [String]
            if let modelSegments {
                alignedChords = InstrumentChordPass.chordLine(
                    segments: modelSegments, onsets: instrumentOnsets, beats: resolvedBeatTimes,
                    sourceDuration: context.document.sourceDuration)
                auditWarnings = []
            } else {
                let line = InstrumentChordPass.chordLine(
                    frames: result.chords, changePoints: result.harmonicChangePoints ?? [],
                    onsets: instrumentOnsets, key: estimatedKey, beats: resolvedBeatTimes,
                    bpm: estimatedBPM ?? 0, barGrid: barGrid,
                    sourceDuration: context.document.sourceDuration)
                alignedChords = line.events
                auditWarnings = [
                    ChordEvidenceAudit.warning(for: line.evidence),
                    ChordQualityAudit.warning(for: line.quality),
                ].compactMap { $0 }
            }
            stageProgress(1, "completed")
            return AnalysisStageOutcome { document in
                document.estimatedBPM = estimatedBPM
                document.beatTimes = resolvedBeatTimes
                // These ARE the tracker's raw answer now — any prior retune's set-aside copy is
                // stale, and the stamp must drop so `AnalysisTimingPostPasses` re-derives.
                document.preReconciliationTiming = nil
                document.timingPostPassTag = nil
                document.estimatedKey = estimatedKey
                document.chordInstrument = rawResult.chordInstrument.flatMap(StemKind.init)
                // The guitar's chords as its stem heard them: no vote across repeated sung lines.
                document.chords = alignedChords
                // Each bass note at its own onset, on the nearest half-beat.
                if let detectedBassNotes {
                    document.bassNotes = detectedBassNotes.map { note in
                        var snapped = BassNoteObservation(
                            timestamp: HalfBeatGrid.snapped(
                                note.timestamp, beats: resolvedBeatTimes),
                            midiNote: note.midiNote, confidence: note.confidence)
                        snapped.pitch = note.pitch
                        return snapped
                    }
                }
                if let detectedVocalHarmonyNotes {
                    document.vocalHarmonyNotes = detectedVocalHarmonyNotes
                }
                document.chordReviewState = .draft
                // Keep the placement evidence so an uploaded reference chart can be judged
                // against the same recording later without re-analysing.
                document.barGrid = barGrid
                document.instrumentAttackOnsets = instrumentOnsets
                document.harmonicChangePoints = result.harmonicChangePoints
                document.frameChordObservations = result.chords
                var harmonyRecord = record
                let warnings = auditWarnings
                harmonyRecord.qualityWarning =
                    warnings.isEmpty ? nil : warnings.joined(separator: " ")
                document.stageRecords[.harmony] = harmonyRecord
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
            let lyricsForChart = document.lyrics
            let built = context.chordProBuilder.buildResult(
                ChordProDraftInput(
                    title: request.title,
                    tempo: document.estimatedBPM,
                    lyrics: document.lyrics,
                    chords: document.chords,
                    confidenceThreshold: document.chordConfidenceThreshold,
                    beatTimes: document.beatTimes,
                    sourceDuration: document.sourceDuration,
                    untranscribedVocalRegions: document.untranscribedVocalRegions,
                    playerRests: document.instrumentChords?.rests ?? [],
                    estimatedKey: document.estimatedKey,
                    barGrid: document.barGrid,
                    placementPicks: document.chordPlacementPicks
                ))
            let chordProSource = built.source
            let layout = PersistedChartLayout(result: built, lyrics: lyricsForChart)
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: .recording,
                // 4: {key}/{time} directives + trailing chords typeset past the last word.
                engine: AnalysisEngineVersion(identifier: "chordpro-draft-builder", version: "5"),
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier:
                    "confidence-\(Int((document.chordConfidenceThreshold * 100).rounded()))",
                confidence: nil
            )
            return AnalysisStageOutcome { document in
                document.chordProSource = chordProSource
                document.chartLayout = layout
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
