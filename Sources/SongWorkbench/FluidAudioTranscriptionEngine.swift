import FluidAudio
import Foundation

struct FluidAudioTranscriptToken: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}

struct FluidAudioTranscript: Equatable, Sendable {
    let text: String
    let duration: TimeInterval
    let confidence: Float
    let tokens: [FluidAudioTranscriptToken]
}

protocol FluidAudioTranscribing: Sendable {
    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FluidAudioTranscript
}

enum FluidAudioDraftProfile: String, Equatable, Sendable {
    case fastDraft
    case balancedDraft

    var displayName: String {
        switch self {
        case .fastDraft: "Fast Draft"
        case .balancedDraft: "Balanced Draft"
        }
    }

    var asrConfig: ASRConfig {
        switch self {
        case .fastDraft:
            ASRConfig(
                parallelChunkConcurrency: 1,
                melChunkContext: false
            )
        case .balancedDraft:
            ASRConfig(
                parallelChunkConcurrency: 1,
                melChunkContext: true
            )
        }
    }
}

actor FluidAudioTranscriptionEngine: TranscriptionEngine {
    nonisolated let metadata: TranscriptionEngineMetadata

    private let runtime: any FluidAudioTranscribing
    private var activeTasks: [UUID: Task<FluidAudioTranscript, Error>] = [:]

    init(
        modelDirectory: URL,
        modelSizeBytes: UInt64,
        profile: FluidAudioDraftProfile = .fastDraft,
        runtime: (any FluidAudioTranscribing)? = nil
    ) {
        metadata = TranscriptionEngineMetadata(
            engineName: "FluidAudio",
            modelName: "Parakeet TDT 0.6B v3 Core ML \(profile.displayName)",
            modelVersion: "v3-int8",
            modelSizeBytes: modelSizeBytes,
            license: TranscriptionModelLicense(
                name: "CC-BY-4.0",
                url: URL(string: "https://creativecommons.org/licenses/by/4.0/")
            ),
            engineVersion: "2"
        )
        self.runtime =
            runtime
            ?? FluidAudioRuntime(
                modelDirectory: modelDirectory,
                profile: profile
            )
    }

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        let task = Task { [runtime] in
            try await runtime.transcribe(audioURL: request.audioURL) { fraction, message in
                let phase: TranscriptionProgress.Phase =
                    message.localizedCaseInsensitiveContains("model")
                    ? .loadingModel : .transcribing
                progress(
                    TranscriptionProgress(
                        phase: phase,
                        completedUnits: Int(min(max(fraction, 0), 1) * 1_000),
                        totalUnits: 1_000,
                        message: message
                    ))
            }
        }
        activeTasks[request.id] = task
        defer { activeTasks[request.id] = nil }

        let transcript = try await task.value
        try Task.checkCancellation()
        progress(
            TranscriptionProgress(
                phase: .finalizing,
                completedUnits: 1,
                totalUnits: 1,
                message: "Finalizing transcription"
            ))

        let tokens = FluidAudioWordTokenGrouper.group(transcript.tokens).map {
            TimedTranscriptionToken(
                text: $0.text,
                startTime: $0.start,
                endTime: max($0.end, $0.start),
                confidence: $0.confidence
            )
        }
        let segment = TimedTranscriptionSegment(
            text: transcript.text,
            startTime: tokens.first?.startTime ?? 0,
            endTime: tokens.last?.endTime ?? transcript.duration,
            tokens: tokens,
            confidence: transcript.confidence
        )
        return TranscriptionResult(
            text: transcript.text,
            languageCode: nil,
            sourceDuration: transcript.duration,
            completedAt: Date(),
            segments: transcript.text.isEmpty && tokens.isEmpty ? [] : [segment],
            engine: metadata
        )
    }

    func cancel(requestID: UUID) async {
        activeTasks[requestID]?.cancel()
    }
}

enum FluidAudioWordTokenGrouper {
    static func group(_ pieces: [FluidAudioTranscriptToken]) -> [FluidAudioTranscriptToken] {
        var words: [FluidAudioTranscriptToken] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidenceTotal: Float = 0
        var pieceCount = 0

        func word() -> FluidAudioTranscriptToken? {
            guard !text.isEmpty, pieceCount > 0 else { return nil }
            return FluidAudioTranscriptToken(
                text: text,
                start: start,
                end: end,
                confidence: confidenceTotal / Float(pieceCount)
            )
        }

        for piece in pieces {
            let startsWord = piece.text.first?.isWhitespace == true
            let pieceText = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pieceText.isEmpty else { continue }
            if startsWord, let completed = word() {
                words.append(completed)
                text = ""
                confidenceTotal = 0
                pieceCount = 0
            }
            if text.isEmpty {
                start = piece.start
            }
            text += pieceText
            end = max(piece.end, piece.start)
            confidenceTotal += piece.confidence
            pieceCount += 1
        }
        if let completed = word() {
            words.append(completed)
        }
        return words
    }
}

actor FluidAudioRuntime: FluidAudioTranscribing {
    private let modelDirectory: URL
    private let profile: FluidAudioDraftProfile
    private var manager: AsrManager?
    private var modelLayout: FluidAudioModelLayout?

    init(modelDirectory: URL, profile: FluidAudioDraftProfile = .fastDraft) {
        self.modelDirectory = modelDirectory
        self.profile = profile
        DownloadUtils.enforceOffline = true
    }

    deinit {
        modelLayout?.removeStagingDirectory()
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FluidAudioTranscript {
        let manager = try await loadedManager(progress: progress)
        try Task.checkCancellation()
        progress(0.25, "Preparing audio")
        var decoderState = TdtDecoderState.make(decoderLayers: 2)
        let result = try await manager.transcribe(
            audioURL,
            decoderState: &decoderState
        )
        try Task.checkCancellation()
        progress(1, "Transcription complete")
        let tokens = (result.tokenTimings ?? []).map {
            FluidAudioTranscriptToken(
                text: $0.token,
                start: $0.startTime,
                end: $0.endTime,
                confidence: $0.confidence
            )
        }
        return FluidAudioTranscript(
            text: result.text,
            duration: max(result.duration, tokens.last?.end ?? 0),
            confidence: result.confidence,
            tokens: tokens
        )
    }

    private func loadedManager(
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> AsrManager {
        if let manager { return manager }
        progress(0, "Loading model")
        let modelLayout = try FluidAudioModelLayout.prepare(modelDirectory: modelDirectory)
        let models = try await AsrModels.load(
            from: modelLayout.loadDirectory,
            version: .v3,
            encoderPrecision: .int8
        ) { value in
            progress(value.fractionCompleted * 0.2, "Loading model")
        }
        let manager = AsrManager(
            config: profile.asrConfig)
        try await manager.loadModels(models)
        self.modelLayout = modelLayout
        self.manager = manager
        progress(0.2, "Model loaded")
        return manager
    }
}

struct FluidAudioModelLayout: Equatable, Sendable {
    static let expectedFolderName = Repo.parakeetV3.folderName

    let loadDirectory: URL
    let stagingDirectory: URL?

    static func prepare(
        modelDirectory: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard modelDirectory.lastPathComponent != expectedFolderName else {
            return Self(loadDirectory: modelDirectory, stagingDirectory: nil)
        }

        let stagingDirectory =
            temporaryDirectory
            .appendingPathComponent("SongWorkbench-FluidAudio", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let loadDirectory = stagingDirectory.appendingPathComponent(
            expectedFolderName,
            isDirectory: true
        )
        do {
            try fileManager.createSymbolicLink(
                at: loadDirectory,
                withDestinationURL: modelDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
        return Self(loadDirectory: loadDirectory, stagingDirectory: stagingDirectory)
    }

    func removeStagingDirectory(fileManager: FileManager = .default) {
        guard let stagingDirectory else { return }
        try? fileManager.removeItem(at: stagingDirectory)
    }
}
