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
            let result = try await stemEngine.separate(
                request: StemSeparationRequest(
                    inputURL: context.request.sourceURL,
                    outputDirectory: context.request.outputDirectory
                )
            ) { value in
                stageProgress(value.fractionCompleted, value.phase.rawValue)
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
                    identifier: stemEngine.metadata.engineIdentifier,
                    version: stemEngine.metadata.engineVersion
                ),
                modelIdentifier: stemEngine.metadata.modelIdentifier,
                modelVersion: stemEngine.metadata.modelVersion,
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
                    request.transcriptionMode == .accuracy
                        ? "decode3-\(String(format: "%.2f", decodeRate))-opening-rescue"
                        : "decode2-\(String(format: "%.2f", decodeRate))",
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
                            audioURL: decodeURL
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

            func transcribeRegion(_ range: ClosedRange<TimeInterval>) async throws
                -> TranscriptionResult
            {
                let requestID = UUID()
                let regionURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("opening-retry-\(requestID.uuidString).wav")
                defer { try? FileManager.default.removeItem(at: regionURL) }
                stageProgress(0, "retryingOpeningPhrase")
                try AudioRegionExporter().export(
                    sourceURL: audioURL,
                    destinationURL: regionURL,
                    range: range
                )
                do {
                    return try await engine.transcribe(
                        request: TranscriptionRequest(id: requestID, audioURL: regionURL)
                    ) { value in
                        stageProgress(value.fractionCompleted, value.phase.rawValue)
                    }
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
                    // Rejoin a phrase torn across two lines by ASR timestamp drift over
                    // untranscribed intro vocals ("I used" | "to stay out late at night"),
                    // vacating the sung-but-wordless region so the untranscribed-vocals
                    // detector below can flag it (Settle Down doo-doo intro, 2026-08-10).
                    let rejoined = TornContinuationLineRejoiner.rejoined(
                        repaired, voicedIntervals: voicedForGating)
                    // Split double-phrase ASR lines at long UNVOICED internal pauses so a
                    // chorus line pair doesn't render as one double-length line. ASR path
                    // only — reference lyrics carry authoritative line breaks.
                    lyrics = IntraLinePauseSplitter.split(
                        rejoined, voicedIntervals: voicedForGating)
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
            // chart can flag them instead of mislabeling them Instrumental. On the vocals stem
            // the evidence is PITCH salience, not energy — the energy-only strict VAD both
            // flagged loud-section bleed as unsung vocals (phantom "vocals — not transcribed"
            // on true instrumentals) and missed soft melodic vocals entirely (Settle Down's
            // doo-doo intro, below the peak-relative gate). Full-mix fallback keeps strict
            // VAD: on a mix, everything is pitched.
            let sungEvidence =
                hasStems
                ? ((try? VocalPitchSalience.sungIntervals(url: audioURL)) ?? strictVoiced)
                : strictVoiced
            let untranscribed = UntranscribedVocalRegionDetector.regions(
                voicedIntervals: sungEvidence, lyrics: normalizedLyrics)
            return AnalysisStageOutcome { document in
                document.lyrics = normalizedLyrics
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

    private func detectVocalHarmonies(_ context: AnalysisStageContext)
        -> [VocalHarmonyObservation]?
    {
        guard (try? Task.checkCancellation()) != nil else { return nil }
        let vocalSources = vocalHarmonySources(in: context.document)
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

    private func vocalHarmonySources(in document: SongAnalysisDocument)
        -> [(id: StemID, url: URL)]
    {
        if let manifest = document.stemSet?.resolved() {
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
            let result: SongAudioAnalysis
            let loadedFromCache: Bool
            if let cached: SongAudioAnalysis = try await cache?.value(
                forSourceHash: sourceHash,
                engine: cacheEngine
            ) {
                result = cached
                loadedFromCache = true
            } else {
                // Weighted stem mix, not a single file: guitar leads, piano supports, and the
                // leakage gate drops a phantom stem before it can double-count the guitar. The
                // mix is reflected in `source.configurationIdentifier`, which is part of the
                // cache key above — so a weighting change re-analyses instead of reusing a chord
                // analysis derived from different audio.
                result = try await harmonyEngine.analyze(weighted: source.weightedURLs)
                try await cache?.store(result, forSourceHash: sourceHash, engine: cacheEngine)
                loadedFromCache = false
            }
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
            stageProgress(0.82, "detecting bass")
            let detectedBassNotes = detectBassNotes(context)
            stageProgress(0.88, "detecting harmony notes")
            let detectedVocalHarmonyNotes = detectVocalHarmonies(context)
            stageProgress(0.92, "aligning chord changes")
            // Instrumental onsets from the GUITAR stem (falling back to "other"/accompaniment):
            // computed BEFORE decoding so the Viterbi can discount its switch penalty for beat
            // windows that start on an attack, then reused to snap event times. Best-effort —
            // any failure or missing stem yields [] and both uses degrade gracefully.
            // Attacks from EVERY chordal stem, not just the loudest one. This used to read
            // `guitar ?? other ?? accompaniment` — first match wins — so a chord struck on piano
            // or on an organ living in `other` produced no attack evidence at all, even though
            // the chroma mix already listens to guitar AND piano. A piano-led change then had
            // nothing to license it: the decoder charged full switch penalty, and
            // `ChordEvidenceAudit` saw an unsupported marker.
            //
            // Vocals, drums, and bass stay out by design — a sung third flips a power chord to
            // major, drums are broadband noise, and bass moves under held chords.
            // Loaded one stem at a time (each is released before the next) so this costs no
            // extra peak memory over the single-stem version.
            let onsetStems: [URL] = {
                guard let stems = context.document.stems?.resolved() else { return [] }
                let candidates = [stems.guitar, stems.piano, stems.other]
                let present = candidates.compactMap { $0 }
                return present.isEmpty ? [stems.accompaniment].compactMap { $0 } : present
            }()
            let instrumentOnsets: [TimeInterval] = InstrumentOnsetDetector.mergedOnsets(
                urls: onsetStems)
            // Key-aware Viterbi decoding over beat windows: a diatonic prior scales frame
            // evidence and a switch penalty smooths window-to-window flicker, with a no-chord
            // state absorbing weak-evidence windows (quiet intros/fades). Replaces independent
            // per-window voting, which let transient out-of-key chroma noise win 28% of the
            // events on the reference song. Switches landing on instrument onsets are charged
            // a reduced penalty so real one-beat changes survive the smoothing.
            // Switch-discount cues for the decoder: instrument attacks PLUS confident bass
            // note onsets — chord changes co-occur with bass root movement, so a beat window
            // starting on either cue pays the reduced switch penalty. (Snapping below keeps
            // using the pure instrument onsets: bass onsets mark WHEN changes are plausible,
            // not the exact instrumental attack to align the label to.)
            let bassCues = (detectedBassNotes ?? context.document.bassNotes)
                .filter { $0.confidence >= 0.5 }
                .map(\.timestamp)
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
                guard let drumsURL = context.document.stems?.resolved().drums,
                    let bpm = estimatedBPM, bpm > 0
                else { return [] }
                return
                    (try? DrumAccentProfile.beatStrengths(
                        url: drumsURL, beatTimes: resolvedBeatTimes, bpm: bpm)) ?? []
            }()
            let barGrid = SongBarGridEstimator.estimate(
                beatTimes: resolvedBeatTimes,
                beatStrengths: drumStrengths,
                lyricLineOnsets: context.document.lyrics.map { $0.words.first?.start ?? $0.start }
            )
            // A phase the accents did not actually measure must not drive the decoder's metric
            // prior — anchoring to beat 0 is the right DISPLAY convention but it is not evidence
            // about where the downbeats are.
            let meter: ChordTimelineDecoder.BarMeter? =
                barGrid.phaseSource == .drumAccents
                ? ChordTimelineDecoder.BarMeter(
                    beatsPerBar: barGrid.beatsPerBar, barPhase: barGrid.barPhase)
                : nil
            // Decode at sub-beat resolution. The decoder emits at most one chord per window, so
            // on the raw beat grid a change landing inside a beat cannot be expressed at all —
            // which is why relaxing the duration filter alone could not recover eighth-note
            // changes. Only the decode grid is subdivided; `resolvedBeatTimes` still governs
            // snapping, the duration filter, and everything the chart draws.
            // Cover audio before the first drum hit: the drum-locked grid starts at the first
            // hit, so a solo-guitar intro had no decode windows and produced no chords at all.
            let decodeSubdivision = HarmonyDecodeResolution.subdivision(
                beatLength: MetricalLevelReconciler.medianBeatLength(
                    beatTimes: resolvedBeatTimes, bpm: estimatedBPM ?? 0) ?? 0)
            let decodeBeatTimes = ChordTimelineDecoder.subdivided(
                ChordTimelineDecoder.extendedBackward(
                    resolvedBeatTimes,
                    toCover: result.chords.first?.timestamp ?? 0),
                by: decodeSubdivision)
            // The meter is expressed in windows, so it has to be restated on the finer grid or
            // "beat 1 of the bar" would point at the wrong window.
            let decodeMeter = meter.map {
                ChordTimelineDecoder.BarMeter(
                    beatsPerBar: $0.beatsPerBar * decodeSubdivision,
                    barPhase: $0.barPhase * decodeSubdivision
                )
            }
            // The switch penalty is per state-change; windows are now `decodeSubdivision`
            // times shorter, so an unscaled penalty would make flicker `decodeSubdivision`
            // times cheaper per beat — one noisy frame alone in a thin window could buy a
            // chord. Scaling by the subdivision keeps per-beat flicker economics identical to
            // the beat-window contract, while a GENUINE sub-beat change still gets in through
            // the onset/downbeat discounts (real changes attack; stray frames don't).
            var decoder = ChordTimelineDecoder()
            decoder.switchPenalty *= Float(decodeSubdivision)
            var chords = BassInformedChordRefiner().refine(
                decoder.events(
                    from: result,
                    key: estimatedKey,
                    bassNotes: detectedBassNotes ?? context.document.bassNotes,
                    instrumentOnsets: instrumentOnsets + bassCues,
                    // Decode on the SAME drum-locked grid every downstream consumer (snap,
                    // duration filter, consensus, ChordPro, playback) uses — not the harmony
                    // engine's own pre-lock estimate embedded in `result`.
                    beatTimes: decodeBeatTimes,
                    meter: decodeMeter
                ),
                bassNotes: detectedBassNotes ?? []
            )
            // Record the decoder's OWN placement before anything moves it. These times sit
            // exactly on `resolvedBeatTimes` by construction (`windowEvidence` pools evidence
            // between consecutive beats), which is precisely why chord-vs-beat agreement can
            // never be used as evidence that the beat grid is right.
            for index in chords.indices {
                chords[index].placementCandidates[ChordPlacementVariant.beatQuantized.rawValue] =
                    chords[index].time
            }
            // Snap chord-change times to where the instrumental actually changes. The beat grid
            // guards the snap: it must never compress two real events to sub-beat spacing (the
            // duration filter below would then delete a genuine change).
            if !instrumentOnsets.isEmpty {
                chords = ChordOnsetAligner.snap(
                    chords, toOnsets: instrumentOnsets, beatTimes: resolvedBeatTimes)
                // The snapped placement, recorded as an ALTERNATIVE rather than silently becoming
                // the only answer. It is still what `time` carries, so nothing renders
                // differently — but the two can now be auditioned against the recording, which is
                // the only way to tell which is right: the `.cho` charts are untimed AND were
                // generated by earlier versions of this pipeline, so there is no external timing
                // ground truth to score against. Deliberately NOT recorded when the snap did not
                // run: an absent candidate means "unavailable", and duplicating the beat time
                // under this key would fake an alternative that was never computed.
                for index in chords.indices {
                    chords[index].placementCandidates[
                        ChordPlacementVariant.instrumentOnset.rawValue] = chords[index].time
                }
            }
            // Onset snapping (and its nondecreasing clamp) can compress neighbouring events to
            // sub-beat spacing; merge those slivers into the preceding chord. Runs LAST so it
            // sees final event times on the resolved (drum-locked) beat grid.
            chords = ChordEventDurationFilter.merge(
                chords,
                beatTimes: resolvedBeatTimes,
                sourceDuration: context.document.sourceDuration
            )
            // One-to-one evidence audit: a marker is a claim that a chordal instrument ATTACKED
            // here, so every surviving event must map to either an instrument attack or a stable
            // harmonic change in the frame-level observations. Events nothing supports are the
            // decoder reporting active harmony rather than a played change — the main source of
            // over-segmentation — and are dropped before they can reach the chart. Self-guarding:
            // when MOST events look unsupported the stem is the suspect (bleed, a quiet
            // fingerpicked part with no discrete attacks), so the audit reports and drops nothing.
            let evidence = ChordEvidenceAudit.filtered(
                events: chords,
                frameObservations: result.chords,
                attackOnsets: instrumentOnsets,
                changePoints: result.harmonicChangePoints
            )
            chords = evidence.events
            // Quality audit: the frame-level classifier read the third straight from chroma with
            // no key prior, so where it decisively disagrees with the decoded major/minor it wins.
            // This is the counterweight to `KeyPriorChordRescorer` discounting a parallel-minor
            // tonic — the `Dm`-corrected-to-`D` failure.
            let quality = ChordQualityAudit.corrected(
                events: chords,
                frameObservations: result.chords,
                sourceDuration: context.document.sourceDuration
            )
            chords = quality.events
            // Events whose third the audio positively confirmed. The repeated-section vote below
            // may not flip these back on the strength of the other choruses.
            let qualityProtectedIDs = Set(
                quality.audit.confirmedEventIndices.compactMap { index in
                    chords.indices.contains(index) ? chords[index].id : nil
                })
            let alignedChords = chords
            let evidenceAudit = evidence.audit
            let qualityAudit = quality.audit
            stageProgress(1, "completed")
            // With the chord timeline final, re-arbitrate BORDERLINE bass-note roundings
            // against it — ambiguous fractional pitches snap to the concurrent chord's
            // tone; decisive ones stay (see `BassChordReconciler`).
            let reconciledBassNotes = detectedBassNotes.map {
                BassChordReconciler.snapped($0, chords: alignedChords)
            }
            return AnalysisStageOutcome { document in
                document.estimatedBPM = estimatedBPM
                document.beatTimes = resolvedBeatTimes
                // These ARE the tracker's raw answer now — any prior retune's set-aside copy is
                // stale, and the stamp must drop so `AnalysisTimingPostPasses` re-derives.
                document.preReconciliationTiming = nil
                document.timingPostPassTag = nil
                document.estimatedKey = estimatedKey
                // A3: identically-sung lines vote on one shared progression (label rewrite
                // only), so repeated choruses can't decode to different chords. No-op when
                // lyrics aren't available yet.
                document.chords = ChorusChordConsensus.applied(
                    chords: alignedChords,
                    lyrics: document.lyrics,
                    beatTimes: resolvedBeatTimes,
                    protectedIDs: qualityProtectedIDs)
                if let reconciledBassNotes {
                    document.bassNotes = reconciledBassNotes
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
                let warnings = [
                    ChordEvidenceAudit.warning(for: evidenceAudit),
                    ChordQualityAudit.warning(for: qualityAudit),
                ].compactMap { $0 }
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
            let chordProSource = context.chordProBuilder.build(
                ChordProDraftInput(
                    title: request.title,
                    tempo: document.estimatedBPM,
                    lyrics: document.lyrics,
                    chords: document.chords,
                    confidenceThreshold: document.chordConfidenceThreshold,
                    beatTimes: document.beatTimes,
                    sourceDuration: document.sourceDuration,
                    untranscribedVocalRegions: document.untranscribedVocalRegions,
                    estimatedKey: document.estimatedKey,
                    barGrid: document.barGrid,
                    bassNotes: document.bassNotes
                ))
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
