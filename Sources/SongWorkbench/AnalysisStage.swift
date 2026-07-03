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
            // Pitch-preserved slow-decode (Accuracy/Whisper only): transcribe a slowed copy of the
            // vocals to help fast/dense singing, then map timestamps back. Part of the cache key so
            // changing it re-transcribes; constant 1.0 for other modes so it never disturbs them.
            let decodeRate =
                request.transcriptionMode == .accuracy
                ? min(max(request.transcriptionDecodeRate, 0.5), 1.0) : 1.0
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
                    "decode2-\(String(format: "%.2f", decodeRate))",
                ].joined(separator: "|")
            )
            // Strict VAD is needed both for the decode-collapse check below and for the tail
            // gates further down — computed once here.
            let strictVAD = VocalActivityEnvelope.Configuration.strictVocalPresence
            let strictVoiced =
                (try? VocalActivityEnvelope.voicedIntervals(
                    url: audioURL, configuration: strictVAD)) ?? []

            /// One transcription pass at `rate` (slow-rendering a temp copy when < 1.0), with
            /// timestamps mapped back to the real timeline.
            func transcribeOnce(rate: Double) async throws -> TranscriptionResult {
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
                            localeIdentifier: Locale.current.language.languageCode?.identifier
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
                var transcribed = try await transcribeOnce(rate: decodeRate)
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
                    if let retry = try? await transcribeOnce(rate: 0.85),
                        let retryCoverage = TranscriptionVoicedCoverage.fraction(
                            of: retry, voicedIntervals: strictVoiced),
                        retryCoverage > coverage
                    {
                        transcribed = retry
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
                    version: result.engine.engineVersion + "|grouping-41-keep-voiced-tail"
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
            // When stems exist, re-anchor/drop intro hallucinations and drop outro tokens after
            // the last detected vocal offset before grouping.
            let sourceDuration = result.sourceDuration
            let normalizedDuration = sourceDuration > 0 ? sourceDuration : nil
            let vocalOnset: TimeInterval? =
                hasStems ? (try? VocalOnsetDetector.firstOnset(url: audioURL)) : nil
            // Every vocal onset on the stem, used to snap each word to the actual energy burst in
            // the final timing pass below. Only meaningful on the isolated vocals stem.
            let vocalOnsets: [TimeInterval] =
                hasStems ? ((try? InstrumentOnsetDetector.onsets(url: audioURL)) ?? []) : []
            let detectedOffset: TimeInterval? =
                hasStems ? (try? VocalOffsetDetector.lastOffset(url: audioURL)) : nil
            // strictVoiced computed once above (also feeds the decode-collapse rescue).
            let tailCutoff = VocalTailCutoffResolver.resolve(
                detectedOffset: detectedOffset,
                strictVoicedIntervals: strictVoiced,
                sourceDuration: normalizedDuration)
            let vocalOffset = tailCutoff.effectiveOffset
            var segmentsForGrouping: [TimedTranscriptionSegment]
            if let vocalOnset {
                segmentsForGrouping = TranscriptionOnsetCorrection.preparedSegments(
                    result.segments, onset: vocalOnset)
            } else {
                segmentsForGrouping = result.segments
            }
            if let vocalOffset {
                segmentsForGrouping = TranscriptionOnsetCorrection.preparedSegments(
                    segmentsForGrouping, droppingSegmentsStartingAtOrAfter: vocalOffset)
                segmentsForGrouping = TranscriptionOnsetCorrection.preparedSegments(
                    segmentsForGrouping, droppingAfter: vocalOffset)
            }
            let gatedTokens = TranscriptionSilenceGate.filtered(
                segmentsForGrouping.flatMap(\.tokens),
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
            // TIMING last: pin the FINAL words (ASR or reference) to the actual singing — distribute
            // each line's words across the voiced regions near it so words land only on
            // signal and silent gaps stay wordless. Per-line + non-destructive; vocals stem when
            // present, otherwise the full mix (weaker but better than no VAD).
            let referenceEmpty =
                reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let lyrics: [TimedLyricSegment]
            if !strictVoiced.isEmpty {
                let voicedForGating = VocalActivityEnvelope.voicedIntervalsForGating(
                    strictVoiced, trailingCutoff: vocalOffset)
                let distributed = VocalAlignmentCorrector.distributeAcrossSignal(
                    textCorrected, voicedIntervals: voicedForGating)
                // On the pure-ASR path, definitively drop any line with NO real vocal under it —
                // hallucinations over instrumental intro/breaks/outro. With reference lyrics the
                // words are user-supplied, so never gate.
                if referenceEmpty {
                    let lastVoicedEnd =
                        tailCutoff.lastVoicedEnd ?? voicedForGating.map(\.upperBound).max()
                    var gated = VocalHallucinationGate.filtered(
                        distributed,
                        voicedIntervals: voicedForGating,
                        trailingCutoff: vocalOffset,
                        lastVoicedEnd: lastVoicedEnd)
                    gated = TrailingLyricTailPruner.pruned(
                        gated, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset,
                        sourceDuration: normalizedDuration)
                    gated = TrailingDuplicateLineCollapser.collapsed(
                        gated, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset)
                    gated = TrailingEarlierLyricRepeater.filtered(
                        gated, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset,
                        sourceDuration: normalizedDuration)
                    // Pull line-leading words stranded on a weak blip (ASR early-padding after an
                    // instrumental) forward to the line's main body when the gap is unvoiced.
                    let repaired = StrandedLeadingWordRepairer.repaired(
                        gated, voicedIntervals: voicedForGating)
                    // Split double-phrase ASR lines at long UNVOICED internal pauses so a
                    // chorus line pair doesn't render as one double-length line. ASR path
                    // only — reference lyrics carry authoritative line breaks.
                    lyrics = IntraLinePauseSplitter.split(
                        repaired, voicedIntervals: voicedForGating)
                } else {
                    lyrics = StrandedLeadingWordRepairer.repaired(
                        distributed, voicedIntervals: voicedForGating)
                }
            } else {
                lyrics = textCorrected
            }
            // FINAL precision pass: after words are distributed onto voiced regions, snap each word's
            // onset to the nearest vocal-stem energy onset so words (and everything anchored to them
            // — the ChordPro strip, the bouncing ball, and chords placed over words) land on the
            // actual vocal energy. No-op without a vocals stem (`vocalOnsets` empty).
            let alignedLyrics = VocalWordOnsetAligner.snapped(lyrics, toOnsets: vocalOnsets)
            // Melisma repair (audit RC-3): bridge held words across continuously-voiced
            // inter-word gaps and pull late ASR onsets back to the voiced re-entry edge, so
            // held notes stop rendering as phantom mid-line pauses. Runs LAST, on the final
            // word timings. No-op when strict VAD is unavailable.
            let normalizedLyrics = VocalWordSpanNormalizer.normalized(
                alignedLyrics, voicedIntervals: strictVoiced)
            // Sung spans with no words (audit RC-4): persist so structure decisions and the
            // chart can flag them instead of mislabeling them Instrumental.
            let untranscribed = UntranscribedVocalRegionDetector.regions(
                voicedIntervals: strictVoiced, lyrics: normalizedLyrics)
            return AnalysisStageOutcome { document in
                document.lyrics = normalizedLyrics
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
        // Merge segment spans so overlaps never double-count.
        let spans = result.segments
            .map { (start: $0.startTime, end: max($0.endTime, $0.startTime)) }
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
                    version: harmonyEngine.metadata.version
                        + "|reduce-11-chorus-consensus"
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
            // Make the click track follow the song's REAL beats: keep the estimated tempo as a
            // spacing prior, but phase-lock the grid to the DRUMS stem's onsets and snap each beat
            // onto the nearest actual drum hit. Best-effort & non-destructive — any failure (no drum
            // stem, unreadable file, no onsets, bad BPM, empty result) keeps the uniform beatTimes.
            var drumBeatTimes = beatTimes
            if let drumsURL = context.document.stems?.resolved().drums,
                let bpm = estimatedBPM, bpm > 0,
                let onsets = try? InstrumentOnsetDetector.onsets(url: drumsURL), !onsets.isEmpty
            {
                let duration = max(onsets.last ?? 0, beatTimes.last ?? 0)
                let derived = DrumBeatGrid.beatTimes(onsets: onsets, bpm: bpm, duration: duration)
                if !derived.isEmpty { drumBeatTimes = derived }
            }
            let resolvedBeatTimes = drumBeatTimes
            let estimatedKey: MusicalKey? =
                result.estimatedKey ?? MusicalKeyEstimator().estimate(from: result.chords)
            // Additive: detect the played bass line from the BASS stem (runs
            // whether or not the harmony chord result was a cache hit). A `nil`
            // result (no stem / failure) leaves existing bassNotes untouched.
            let detectedBassNotes = detectBassNotes(context)
            // Key-aware Viterbi decoding over beat windows: a diatonic prior scales frame
            // evidence and a switch penalty smooths window-to-window flicker, with a no-chord
            // state absorbing weak-evidence windows (quiet intros/fades). Replaces independent
            // per-window voting, which let transient out-of-key chroma noise win 28% of the
            // events on the reference song.
            var chords = BassInformedChordRefiner().refine(
                ChordTimelineDecoder().events(
                    from: result,
                    key: estimatedKey,
                    bassNotes: detectedBassNotes ?? context.document.bassNotes
                ),
                bassNotes: detectedBassNotes ?? []
            )
            // Snap chord-change times to where the instrumental actually changes: onsets detected
            // on the GUITAR stem (falling back to the "other"/accompaniment stem). Best-effort and
            // non-destructive — any failure or missing stem leaves the chord times unchanged.
            let instrumentURL: URL? =
                context.document.stems?.resolved().guitar
                ?? context.document.stems?.resolved().other
                ?? context.document.stems?.resolved().accompaniment
            if let instrumentURL,
                let onsets = try? InstrumentOnsetDetector.onsets(url: instrumentURL),
                !onsets.isEmpty
            {
                chords = ChordOnsetAligner.snap(chords, toOnsets: onsets)
            }
            // Onset snapping (and its nondecreasing clamp) can compress neighbouring events to
            // sub-beat spacing; merge those slivers into the preceding chord. Runs LAST so it
            // sees final event times on the resolved (drum-locked) beat grid.
            chords = ChordEventDurationFilter.merge(
                chords,
                beatTimes: resolvedBeatTimes,
                sourceDuration: context.document.sourceDuration
            )
            let alignedChords = chords
            return AnalysisStageOutcome { document in
                document.estimatedBPM = estimatedBPM
                document.beatTimes = resolvedBeatTimes
                document.estimatedKey = estimatedKey
                // A3: identically-sung lines vote on one shared progression (label rewrite
                // only), so repeated choruses can't decode to different chords. No-op when
                // lyrics aren't available yet.
                document.chords = ChorusChordConsensus.applied(
                    chords: alignedChords,
                    lyrics: document.lyrics,
                    beatTimes: resolvedBeatTimes)
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
                    beatTimes: document.beatTimes,
                    sourceDuration: document.sourceDuration,
                    estimatedKey: document.estimatedKey
                ))
            let record = AnalysisStageRecordFactory.successfulRecord(
                sourceDigest: sourceDigest,
                sourceKind: .recording,
                // 4: {key}/{time} directives + trailing chords typeset past the last word.
                engine: AnalysisEngineVersion(identifier: "chordpro-draft-builder", version: "4"),
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
