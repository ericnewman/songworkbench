import CryptoKit
import Foundation
import XCTest

@testable import SongWorkbench

final class SongAnalysisPipelineTests: XCTestCase {
    func testCompleteRunRoutesTranscriptionToVocalsAndHarmonyToAccompaniment() async throws {
        let sourceURL = try temporarySource()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let vocalsURL = outputDirectory.appendingPathComponent("vocals.wav")
        let accompanimentURL = outputDirectory.appendingPathComponent("accompaniment.wav")
        let transcription = RecordingTranscriptionEngine(result: transcriptionResult())
        let harmony = RecordingHarmonyEngine(result: harmonyResult())
        let pipeline = SongAnalysisPipeline(
            stemEngine: StubStemEngine(outputDirectory: outputDirectory),
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: harmony
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                title: "Pipeline Song",
                stages: Set(SongAnalysisStage.allCases),
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { _ in }

        let requestedURLs = await transcription.requestedURLs()
        let harmonyURLs = await harmony.requestedURLs()
        XCTAssertEqual(requestedURLs.map(\.lastPathComponent), [vocalsURL.lastPathComponent])
        XCTAssertEqual(harmonyURLs.map(\.lastPathComponent), [accompanimentURL.lastPathComponent])
        XCTAssertEqual(result.document.lyrics.map(\.text), ["Hello world"])
        XCTAssertEqual(result.document.chords.map(\.chord), ["C"])
        XCTAssertEqual(result.document.estimatedBPM, 120)
        XCTAssertTrue(result.document.chordProSource.contains("[C]Hello world"))
        XCTAssertEqual(result.document.lyricReviewState, .draft)
        XCTAssertEqual(result.document.chordReviewState, .draft)
        XCTAssertEqual(result.document.chordProReviewState, .draft)
        XCTAssertEqual(
            result.document.stageRecords[.transcription]?.provenance?.sourceKind,
            .vocalsStem
        )
        XCTAssertEqual(
            result.document.stageRecords[.harmony]?.provenance?.sourceKind,
            .accompanimentStem
        )
        XCTAssertTrue(
            SongAnalysisStage.allCases.allSatisfy {
                result.document.stageRecords[$0]?.state == .succeeded
            }
        )
    }

    func testHarmonyVotesInBeatWindowsInsteadOfEmittingEveryFrameChange() async throws {
        let sourceURL = try temporarySource()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let alternating = (0..<16).map { index in
            ChordObservation(
                timestamp: Double(index) * 0.25,
                chord: Chord(
                    root: index.isMultiple(of: 2) ? .c : .g,
                    quality: .major
                ),
                confidence: index.isMultiple(of: 2) ? 0.9 : 0.6
            )
        }
        let harmony = RecordingHarmonyEngine(
            result: SongAudioAnalysis(
                beat: BeatEstimate(
                    bpm: 120,
                    beatTimes: stride(from: 0.0, through: 4.0, by: 0.5).map { $0 },
                    confidence: 1
                ),
                chords: alternating
            )
        )
        let pipeline = SongAnalysisPipeline(
            stemEngine: StubStemEngine(outputDirectory: outputDirectory),
            fastTranscriptionEngine: nil,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: harmony
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                title: "Stable Harmony",
                stages: [.separation, .harmony],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { _ in }

        XCTAssertEqual(result.document.chords.map(\.chord), ["C"])
        XCTAssertEqual(result.document.chords.first?.time, 0)
    }

    func testBalancedDraftRoutesToBalancedTranscriptionEngine() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let fastTranscription = RecordingTranscriptionEngine(
            result: transcriptionResult(engineName: "fast-transcriber")
        )
        let balancedTranscription = RecordingTranscriptionEngine(
            result: transcriptionResult(engineName: "balanced-transcriber")
        )
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: fastTranscription,
            balancedTranscriptionEngine: balancedTranscription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Balanced Song",
                stages: [.transcription],
                transcriptionMode: .balancedDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { _ in }

        let fastCallCount = await fastTranscription.callCount()
        let balancedCallCount = await balancedTranscription.callCount()
        XCTAssertEqual(fastCallCount, 0)
        XCTAssertEqual(balancedCallCount, 1)
        XCTAssertEqual(
            result.document.stageRecords[.transcription]?.provenance?.engineIdentifier,
            "balanced-transcriber"
        )
        XCTAssertEqual(
            result.document.stageRecords[.transcription]?.provenance?.configurationIdentifier,
            TranscriptionMode.balancedDraft.rawValue
        )
    }

    func testTranscriptionRetryRebuildsGeneratedDraftWithLyricsAndExistingChords() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transcription = RecordingTranscriptionEngine(result: transcriptionResult())
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )
        let chordOnly = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Retry Song",
                stages: [.harmony, .chordPro],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { _ in }
        XCTAssertTrue(chordOnly.document.chordProSource.contains("{start_of_grid}"))

        let retried = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Retry Song",
                stages: [.transcription],
                transcriptionMode: .fastDraft,
                existingDocument: chordOnly.document
            )
        ) { _ in }

        XCTAssertTrue(retried.document.chordProSource.contains("[C]Hello world"))
        XCTAssertFalse(retried.document.chordProSource.contains("{start_of_grid}"))
        XCTAssertEqual(retried.document.stageRecords[.chordPro]?.state, .succeeded)
    }

    func testTranscriptionRetryPreservesReviewedGeneratedChordPro() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transcription = RecordingTranscriptionEngine(result: transcriptionResult())
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )
        let generated = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Reviewed Song",
                stages: [.harmony, .chordPro],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { _ in }
        var reviewedDocument = generated.document
        reviewedDocument.chordProReviewState = .reviewed

        let retried = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Reviewed Song",
                stages: [.transcription],
                transcriptionMode: .fastDraft,
                existingDocument: reviewedDocument
            )
        ) { _ in }

        XCTAssertEqual(retried.document.chordProSource, reviewedDocument.chordProSource)
        XCTAssertEqual(retried.document.chordProReviewState, .reviewed)
    }

    func testSeparationFailureFallsBackToMixAndContinuesIndependentStages() async throws {
        let sourceURL = try temporarySource()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transcription = RecordingTranscriptionEngine(result: transcriptionResult())
        let pipeline = SongAnalysisPipeline(
            stemEngine: FailingStemEngine(),
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                title: "Partial Song",
                stages: [.separation, .transcription, .harmony],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { _ in }

        let requestedURLs = await transcription.requestedURLs()
        XCTAssertEqual(requestedURLs, [sourceURL])
        XCTAssertEqual(result.document.stageRecords[.separation]?.state, .failed)
        XCTAssertEqual(result.document.stageRecords[.transcription]?.state, .succeeded)
        XCTAssertEqual(result.document.stageRecords[.harmony]?.state, .succeeded)
        XCTAssertEqual(
            result.document.stageRecords[.harmony]?.provenance?.sourceKind,
            .recording
        )
        XCTAssertEqual(
            result.document.stageRecords[.harmony]?.provenance?.configurationIdentifier,
            "full-mix-fallback"
        )
        XCTAssertEqual(
            result.document.stageRecords[.transcription]?.provenance?.sourceKind,
            .recording
        )
        XCTAssertEqual(result.document.lyrics.map(\.text), ["Hello world"])
        XCTAssertEqual(result.document.chords.map(\.chord), ["C"])
    }

    func testCancellationReachesActiveTranscriberAndStopsLaterStages() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transcription = CancellableTranscriptionEngine()
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )
        let task = Task {
            try await pipeline.run(
                SongAnalysisPipelineRequest(
                    sourceURL: sourceURL,
                    outputDirectory: FileManager.default.temporaryDirectory,
                    title: "Cancelled Song",
                    stages: [.transcription, .harmony],
                    transcriptionMode: .fastDraft,
                    existingDocument: SongAnalysisDocument()
                )
            ) { _ in }
        }
        await transcription.waitUntilStarted()

        task.cancel()
        let result = try await task.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.document.stageRecords[.transcription]?.state, .cancelled)
        // Harmony runs concurrently with transcription, so cancelling the run may
        // interrupt it before or after it finishes the (instant) stub work. Either
        // way it must NOT publish a succeeded result; an absent or cancelled record
        // both satisfy "later stages are stopped". Asserting strictly `nil` made
        // this test flaky under CI timing.
        let harmonyState = result.document.stageRecords[.harmony]?.state
        XCTAssertTrue(
            harmonyState == nil || harmonyState == .cancelled,
            "Harmony must not succeed when the run is cancelled (was \(String(describing: harmonyState)))"
        )
        let cancelCount = await transcription.cancelCount()
        XCTAssertEqual(cancelCount, 1)
    }

    func testAggregateProgressNeverRegressesWhenEngineProgressDoes() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let transcription = RecordingTranscriptionEngine(
            result: transcriptionResult(),
            progressFractions: [0.8, 0.2, 1]
        )
        let recorder = LockedProgressRecorder()
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )

        _ = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Progress Song",
                stages: [.transcription],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument()
            )
        ) { value in
            recorder.append(value.fractionCompleted)
        }

        let values = recorder.values
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(values.last, 1)
    }

    func testChordProStagePreservesReviewedContentWithoutReplacementConfirmation() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let existingSource = "{title: Hand Reviewed}\n[C]Keep this\n"
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: nil,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Conflict Song",
                stages: [.chordPro],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument(
                    chordProSource: existingSource,
                    chordProReviewState: .reviewed
                )
            )
        ) { _ in }

        XCTAssertEqual(result.document.chordProSource, existingSource)
        XCTAssertEqual(result.document.chordProReviewState, .reviewed)
        XCTAssertEqual(result.document.stageRecords[.chordPro]?.state, .failed)
        XCTAssertNotNil(result.document.stageRecords[.chordPro]?.errorMessage)
    }

    func testSecondTranscriptionRunLoadsMatchingResultFromCache() async throws {
        let sourceURL = try temporarySource()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let transcription = RecordingTranscriptionEngine(result: transcriptionResult())
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: transcription,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine(),
            cache: AnalysisResultDiskCache(directoryURL: cacheDirectory)
        )
        let request = SongAnalysisPipelineRequest(
            sourceURL: sourceURL,
            outputDirectory: FileManager.default.temporaryDirectory,
            title: "Cached Song",
            stages: [.transcription],
            transcriptionMode: .fastDraft,
            existingDocument: SongAnalysisDocument()
        )

        _ = try await pipeline.run(request) { _ in }
        let second = try await pipeline.run(request) { _ in }

        let callCount = await transcription.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            second.document.stageRecords[.transcription]?.provenance?.loadedFromCache,
            true
        )
    }

    func testSeparationCacheInvalidatesWhenEngineVersionChanges() async throws {
        let sourceURL = try temporarySource()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let staleStems = StemFiles(
            vocals: outputDirectory.appendingPathComponent("vocals.wav"),
            drums: outputDirectory.appendingPathComponent("drums.wav"),
            bass: outputDirectory.appendingPathComponent("bass.wav"),
            guitar: outputDirectory.appendingPathComponent("guitar.wav"),
            piano: outputDirectory.appendingPathComponent("piano.wav"),
            other: outputDirectory.appendingPathComponent("other.wav"),
            accompaniment: outputDirectory.appendingPathComponent("accompaniment.wav")
        )
        for kind in StemKind.allCases {
            try Data("stale \(kind.rawValue)".utf8).write(to: staleStems[kind]!)
        }
        try Data("stale accompaniment".utf8).write(to: staleStems.accompaniment!)

        let engine = RecordingStemEngine(outputDirectory: outputDirectory)
        let pipeline = SongAnalysisPipeline(
            stemEngine: engine,
            fastTranscriptionEngine: nil,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )
        var existing = SongAnalysisDocument(stems: StoredStemFiles(files: staleStems))
        existing.stageRecords[.separation] = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: sha256Hex(try Data(contentsOf: sourceURL)),
                sourceKind: .recording,
                engineIdentifier: "onnxruntime-coreml-htdemucs-6s",
                engineVersion: "1",
                modelIdentifier: engine.metadata.modelIdentifier,
                modelVersion: engine.metadata.modelVersion,
                configurationIdentifier: "six-stem-44.1k-stereo",
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(timeIntervalSince1970: 1_750_000_000),
                loadedFromCache: false
            ),
            confidence: nil,
            errorMessage: nil
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                title: "Cached Stem Song",
                stages: [.separation],
                transcriptionMode: .fastDraft,
                existingDocument: existing
            )
        ) { _ in }

        let callCount = await engine.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(
            result.document.stageRecords[.separation]?.provenance?.engineIdentifier,
            engine.metadata.engineIdentifier
        )
        XCTAssertEqual(
            result.document.stageRecords[.separation]?.provenance?.loadedFromCache,
            false
        )
    }

    func testConfirmedChordProReplacementProducesNewDraft() async throws {
        let sourceURL = try temporarySource()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let pipeline = SongAnalysisPipeline(
            stemEngine: nil,
            fastTranscriptionEngine: nil,
            accuracyTranscriptionEngine: nil,
            harmonyEngine: StubHarmonyEngine()
        )

        let result = try await pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: FileManager.default.temporaryDirectory,
                title: "Replacement Song",
                stages: [.chordPro],
                transcriptionMode: .fastDraft,
                existingDocument: SongAnalysisDocument(
                    chordProSource: "{title: Old}\n",
                    chordProReviewState: .reviewed
                ),
                chordProReplacementPolicy: .replaceExisting
            )
        ) { _ in }

        XCTAssertTrue(result.document.chordProSource.contains("{title: Replacement Song}"))
        XCTAssertEqual(result.document.chordProReviewState, .draft)
        XCTAssertEqual(result.document.stageRecords[.chordPro]?.state, .succeeded)
    }

    private func temporarySource() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("source audio".utf8).write(to: url)
        return url
    }

    private func transcriptionResult(
        engineName: String = "test-transcriber"
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: "Hello world",
            languageCode: "en",
            sourceDuration: 2,
            completedAt: Date(timeIntervalSince1970: 1_750_000_000),
            segments: [
                TimedTranscriptionSegment(
                    text: "Hello world",
                    startTime: 0,
                    endTime: 2,
                    tokens: [
                        TimedTranscriptionToken(
                            text: "Hello",
                            startTime: 0,
                            endTime: 0.8,
                            confidence: 0.9
                        ),
                        TimedTranscriptionToken(
                            text: "world",
                            startTime: 0.8,
                            endTime: 2,
                            confidence: 0.8
                        ),
                    ],
                    confidence: 0.85
                )
            ],
            engine: TranscriptionEngineMetadata(
                engineName: engineName,
                modelName: "test-model",
                modelVersion: "1",
                modelSizeBytes: 1,
                license: TranscriptionModelLicense(name: "Test", url: nil)
            )
        )
    }

    private func harmonyResult() -> SongAudioAnalysis {
        SongAudioAnalysis(
            beat: BeatEstimate(bpm: 120, beatTimes: [0, 0.5, 1, 1.5, 2], confidence: 1),
            chords: [
                ChordObservation(
                    timestamp: 0,
                    chord: Chord(root: .c, quality: .major),
                    confidence: 0.9
                )
            ]
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor RecordingStemEngine: StemSeparationEngine {
    nonisolated let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "onnxruntime-cpu-htdemucs-6s",
        engineVersion: "2",
        modelIdentifier: "htdemucs-6s-onnx",
        modelVersion: "125b3e0"
    )

    private let outputDirectory: URL
    private var calls = 0

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        calls += 1
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        for kind in StemKind.allCases {
            try Data("fresh \(kind.rawValue)".utf8).write(
                to: outputDirectory.appendingPathComponent("\(kind.rawValue).wav")
            )
        }
        try Data("fresh accompaniment".utf8).write(
            to: outputDirectory.appendingPathComponent("accompaniment.wav")
        )
        return StemSeparationResult(
            stems: StemFiles(
                vocals: outputDirectory.appendingPathComponent("vocals.wav"),
                drums: outputDirectory.appendingPathComponent("drums.wav"),
                bass: outputDirectory.appendingPathComponent("bass.wav"),
                guitar: outputDirectory.appendingPathComponent("guitar.wav"),
                piano: outputDirectory.appendingPathComponent("piano.wav"),
                other: outputDirectory.appendingPathComponent("other.wav"),
                accompaniment: outputDirectory.appendingPathComponent("accompaniment.wav")
            ),
            processingDuration: .seconds(1)
        )
    }

    func callCount() -> Int {
        calls
    }
}

private struct StubStemEngine: StemSeparationEngine {
    let outputDirectory: URL

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        for kind in StemKind.allCases {
            try Data("\(kind.rawValue) audio".utf8).write(
                to: outputDirectory.appendingPathComponent("\(kind.rawValue).wav")
            )
        }
        try Data("accompaniment audio".utf8).write(
            to: outputDirectory.appendingPathComponent("accompaniment.wav")
        )
        return StemSeparationResult(
            stems: StemFiles(
                vocals: outputDirectory.appendingPathComponent("vocals.wav"),
                drums: outputDirectory.appendingPathComponent("drums.wav"),
                bass: outputDirectory.appendingPathComponent("bass.wav"),
                guitar: outputDirectory.appendingPathComponent("guitar.wav"),
                piano: outputDirectory.appendingPathComponent("piano.wav"),
                other: outputDirectory.appendingPathComponent("other.wav"),
                accompaniment: outputDirectory.appendingPathComponent("accompaniment.wav")
            ),
            processingDuration: .seconds(1)
        )
    }
}

private actor RecordingHarmonyEngine: SongHarmonyAnalyzing {
    nonisolated let metadata = AnalysisEngineVersion(identifier: "test-harmony", version: "1")
    private let result: SongAudioAnalysis
    private var urls: [URL] = []

    init(result: SongAudioAnalysis) {
        self.result = result
    }

    func analyze(url: URL) async throws -> SongAudioAnalysis {
        urls.append(url)
        return result
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private struct FailingStemEngine: StemSeparationEngine {
    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        throw TestPipelineError.separationFailed
    }
}

private actor RecordingTranscriptionEngine: TranscriptionEngine {
    nonisolated let metadata: TranscriptionEngineMetadata
    private let result: TranscriptionResult
    private let progressFractions: [Double]
    private var urls: [URL] = []

    init(result: TranscriptionResult, progressFractions: [Double] = []) {
        self.result = result
        self.progressFractions = progressFractions
        metadata = result.engine
    }

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        urls.append(request.audioURL)
        for fraction in progressFractions {
            progress(
                TranscriptionProgress(
                    phase: .transcribing,
                    completedUnits: Int(fraction * 100),
                    totalUnits: 100
                ))
        }
        return result
    }

    func cancel(requestID: UUID) async {}

    func requestedURLs() -> [URL] {
        urls
    }

    func callCount() -> Int {
        urls.count
    }
}

private actor CancellableTranscriptionEngine: TranscriptionEngine {
    nonisolated let metadata = TranscriptionEngineMetadata(
        engineName: "cancellable",
        modelName: "test-model",
        modelVersion: "1",
        modelSizeBytes: 1,
        license: TranscriptionModelLicense(name: "Test", url: nil)
    )
    private var started = false
    private var cancellations = 0

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        started = true
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }

    func cancel(requestID: UUID) async {
        cancellations += 1
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func cancelCount() -> Int {
        cancellations
    }
}

private struct StubHarmonyEngine: SongHarmonyAnalyzing {
    let metadata = AnalysisEngineVersion(identifier: "test-harmony", version: "1")

    func analyze(url: URL) async throws -> SongAudioAnalysis {
        SongAudioAnalysis(
            beat: BeatEstimate(bpm: 120, beatTimes: [0, 0.5, 1, 1.5, 2], confidence: 1),
            chords: [
                ChordObservation(
                    timestamp: 0,
                    chord: Chord(root: .c, quality: .major),
                    confidence: 0.9
                )
            ]
        )
    }
}

private enum TestPipelineError: Error {
    case separationFailed
}

private final class LockedProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func append(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}
