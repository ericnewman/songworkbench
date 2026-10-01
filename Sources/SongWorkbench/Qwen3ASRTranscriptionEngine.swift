import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

/// Qwen3-ASR's text for a vocals stem. Separated from the engine so tests need no model.
protocol Qwen3ASRTranscribing: Sendable {
    func transcribe(audioURL: URL, language: String?) async throws -> String
    func releaseResources() async
}

/// Places a transcript's words on the audio they were sung in. Qwen3-ASR returns text with no
/// times, and line grouping needs times; the default is the app's own forced aligner on the same
/// vocals stem (`ForcedLyricAligner`), the measurement every word time comes from anyway.
typealias Qwen3WordTimer =
    @Sendable (_ words: [String], _ audioURL: URL) throws -> [ForcedLyricAligner.AlignedWord]

/// Lyric transcription with Qwen3-ASR-1.7B on MLX (Eric, 2026-10-01: the preferred engine).
///
/// Measured on Doc Holiday's vocals stem against a reference lyric (2026-09-30): 0.851 word recall,
/// 0.833 precision, against Whisper large-v3-turbo's 0.647 / 0.605 with a looped hook — the only
/// open model with published results on songs, and an independent study found it loops in under
/// 4 % of masked-audio cases where Whisper loops in 35 %.
///
/// Its words are timed here with the app's forced aligner because the grouper breaks lines on
/// time. A word the aligner cannot place goes with the word before it — a zero-length position for
/// line grouping only, never a stored time: the transcription stage re-measures every word and
/// stores none for a word it still cannot place (`MeasuredLyricTiming`).
actor Qwen3ASRTranscriptionEngine: TranscriptionEngine {
    nonisolated let metadata: TranscriptionEngineMetadata

    private let runtime: any Qwen3ASRTranscribing
    private let timeWords: Qwen3WordTimer
    private var activeTasks: [UUID: Task<String, Error>] = [:]

    init(
        modelDirectory: URL,
        modelSizeBytes: UInt64,
        runtime: (any Qwen3ASRTranscribing)? = nil,
        timeWords: @escaping Qwen3WordTimer = Qwen3ASRTranscriptionEngine.alignedWithBundledModel
    ) {
        metadata = TranscriptionEngineMetadata(
            engineName: "MLX",
            modelName: "Qwen3-ASR 1.7B 8-bit",
            modelVersion: ModelCatalog.qwen3ASRRevision,
            modelSizeBytes: modelSizeBytes,
            license: TranscriptionModelLicense(
                name: "Apache-2.0",
                url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")
            ),
            // 2: both channels averaged and a drained resample, not MLXAudioCore's left channel.
            // 3: mlx-audio-swift's corrected mel frontend (Slaney scale, periodic Hann window).
            engineVersion: "3"
        )
        self.runtime = runtime ?? Qwen3ASRRuntime(modelDirectory: modelDirectory)
        self.timeWords = timeWords
    }

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        progress(
            TranscriptionProgress(
                phase: .transcribing, completedUnits: 0, totalUnits: 1,
                message: "Transcribing with Qwen3-ASR"))
        let language = request.localeIdentifier.flatMap(Self.languageName(for:))
        let task = Task { [runtime] in
            try await runtime.transcribe(audioURL: request.audioURL, language: language)
        }
        activeTasks[request.id] = task
        defer { activeTasks[request.id] = nil }
        let text = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()

        progress(
            TranscriptionProgress(
                phase: .finalizing, completedUnits: 1, totalUnits: 1,
                message: "Placing words on the vocals"))
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let aligned = words.isEmpty ? [] : try timeWords(words, request.audioURL)
        let tokens = Self.tokens(for: aligned)
        let duration = try Self.duration(of: request.audioURL)
        let segment = TimedTranscriptionSegment(
            text: text, startTime: tokens.first?.startTime ?? 0,
            endTime: tokens.last?.endTime ?? duration, tokens: tokens, confidence: nil)
        return TranscriptionResult(
            text: text, languageCode: request.localeIdentifier, sourceDuration: duration,
            completedAt: Date(), segments: tokens.isEmpty ? [] : [segment], engine: metadata)
    }

    func cancel(requestID: UUID) async {
        activeTasks[requestID]?.cancel()
    }

    func releaseResources() async {
        await runtime.releaseResources()
    }

    /// Timed tokens for aligned words. An unplaced word takes the previous word's end (the next
    /// word's start when it leads) as a zero-length position for line grouping; see the type note.
    static func tokens(for aligned: [ForcedLyricAligner.AlignedWord]) -> [TimedTranscriptionToken] {
        guard let firstPlaced = aligned.first(where: { $0.start != nil })?.start else { return [] }
        var position = firstPlaced
        return aligned.map { word in
            guard let start = word.start else {
                return TimedTranscriptionToken(
                    text: word.text, startTime: position, endTime: position, confidence: nil)
            }
            let end = max(word.end ?? start, start)
            position = end
            return TimedTranscriptionToken(
                text: word.text, startTime: start, endTime: end, confidence: nil)
        }
    }

    /// Qwen3-ASR takes a language NAME; nil lets it detect the language.
    static func languageName(for identifier: String) -> String? {
        Locale(identifier: "en").localizedString(
            forLanguageCode: Locale(identifier: identifier).language.languageCode?.identifier
                ?? identifier)
    }

    /// The forced aligner over the vocals stem, with the bundled model.
    @Sendable
    static func alignedWithBundledModel(_ words: [String], audioURL: URL) throws
        -> [ForcedLyricAligner.AlignedWord]
    {
        guard let model = CoreMLLyricsAcousticModel.load() else {
            throw SongAnalysisPipelineError.missingBundledModel("LyricsAlignmentMTL")
        }
        let samples = try MeasuredLyricTiming.monoSamples(at: audioURL)
        guard !samples.isEmpty else { throw MeasuredLyricTiming.Failure.emptyVocalsStem }
        return try ForcedLyricAligner.align(samples: samples, words: words, model: model)
    }

    private static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Loads Qwen3-ASR from the installed package once and keeps it until released. MLX work runs on
/// one model at a time; a lock guards the lazily loaded instance.
private final class Qwen3ASRRuntime: Qwen3ASRTranscribing, @unchecked Sendable {
    private let modelDirectory: URL
    private let lock = NSLock()
    private var model: Qwen3ASRModel?

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        let model = try await loadedModel()
        // Not MLXAudioCore's `loadAudioArray`: it reads only the LEFT channel and resamples in one
        // converter pull. Both channels averaged, then a fully drained conversion — the same path
        // forced alignment uses (`MeasuredLyricTiming.monoSamples`).
        let samples = try MeasuredLyricTiming.monoSamples(
            at: audioURL, sampleRate: Double(model.sampleRate))
        let audio = MLXArray(samples)
        try Task.checkCancellation()
        return model.generate(audio: audio, language: language).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func releaseResources() async {
        lock.withLock { model = nil }
        MLX.GPU.clearCache()
    }

    private func loadedModel() async throws -> Qwen3ASRModel {
        if let model = lock.withLock({ model }) { return model }
        let loaded = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
        lock.withLock { model = loaded }
        return loaded
    }
}
