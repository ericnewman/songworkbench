import FluidAudio
import Foundation
import whisper

struct WhisperCPPTranscriptToken: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}

struct WhisperCPPTranscriptSegment: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let tokens: [WhisperCPPTranscriptToken]
}

struct WhisperCPPTranscript: Equatable, Sendable {
    let text: String
    let duration: TimeInterval
    let languageCode: String?
    let segments: [WhisperCPPTranscriptSegment]
}

protocol WhisperCPPTranscribing: Sendable {
    func transcribe(
        audioURL: URL,
        noContext: Bool,
        cancellation: WhisperCPPCancellationToken
    ) async throws -> WhisperCPPTranscript
}

final class WhisperCPPCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

actor WhisperCPPTranscriptionEngine: TranscriptionEngine {
    private struct ActiveRequest {
        let task: Task<WhisperCPPTranscript, Error>
        let cancellation: WhisperCPPCancellationToken
    }

    nonisolated let metadata: TranscriptionEngineMetadata

    private let runtime: any WhisperCPPTranscribing
    private var activeRequests: [UUID: ActiveRequest] = [:]

    init(
        modelURL: URL,
        modelSizeBytes: UInt64,
        useGPU: Bool = false,
        runtime: (any WhisperCPPTranscribing)? = nil
    ) {
        metadata = TranscriptionEngineMetadata(
            engineName: "whisper.cpp",
            modelName: "Whisper Large V3 Turbo Q5_0",
            modelVersion: "large-v3-turbo-q5_0",
            modelSizeBytes: modelSizeBytes,
            license: TranscriptionModelLicense(
                name: "MIT",
                url: URL(string: "https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE")
            ),
            engineVersion: "4"
        )
        self.runtime = runtime ?? WhisperCPPRuntime(modelURL: modelURL, useGPU: useGPU)
    }

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        progress(
            TranscriptionProgress(
                phase: .loadingModel,
                completedUnits: 0,
                totalUnits: 3,
                message: "Loading accuracy model"
            ))
        let cancellation = WhisperCPPCancellationToken()
        let task = Task { [runtime] in
            try await runtime.transcribe(
                audioURL: request.audioURL,
                noContext: true,
                cancellation: cancellation
            )
        }
        activeRequests[request.id] = ActiveRequest(task: task, cancellation: cancellation)
        defer { activeRequests[request.id] = nil }
        progress(
            TranscriptionProgress(
                phase: .transcribing,
                completedUnits: 1,
                totalUnits: 3,
                message: "Transcribing with no previous-text context"
            ))

        let rawTranscript = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
        try Task.checkCancellation()
        // The repetition filter now drops only the runaway-loop region and keeps
        // any distinct content after it, so it is always safe to apply directly.
        let transcript = WhisperCPPRepetitionFilter.filter(rawTranscript)
        progress(
            TranscriptionProgress(
                phase: .finalizing,
                completedUnits: 3,
                totalUnits: 3,
                message: "Finalizing accuracy transcript"
            ))

        let segments = transcript.segments.map { segment in
            let tokens = segment.tokens.compactMap { token -> TimedTranscriptionToken? in
                let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TimedTranscriptionToken(
                    text: text,
                    startTime: token.start,
                    endTime: max(token.end, token.start),
                    confidence: token.confidence
                )
            }
            let confidence: Float? =
                tokens.isEmpty
                ? nil
                : tokens.compactMap(\.confidence).reduce(0, +) / Float(tokens.count)
            return TimedTranscriptionSegment(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startTime: segment.start,
                endTime: max(segment.end, segment.start),
                tokens: tokens,
                confidence: confidence
            )
        }
        return TranscriptionResult(
            text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: transcript.languageCode,
            sourceDuration: transcript.duration,
            completedAt: Date(),
            segments: segments,
            engine: metadata
        )
    }

    func cancel(requestID: UUID) async {
        activeRequests[requestID]?.cancellation.cancel()
        activeRequests[requestID]?.task.cancel()
    }

}

private actor WhisperCPPRuntime: WhisperCPPTranscribing {
    private let modelURL: URL
    private let useGPU: Bool
    private var contextHandle: WhisperCPPContextHandle?

    init(modelURL: URL, useGPU: Bool) {
        self.modelURL = modelURL
        self.useGPU = useGPU
    }

    func transcribe(
        audioURL: URL,
        noContext: Bool,
        cancellation: WhisperCPPCancellationToken
    ) async throws -> WhisperCPPTranscript {
        let context = try loadedContext()
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        try Task.checkCancellation()
        // Beam search + non-speech-token suppression markedly reduce the
        // hallucination/repetition loops Whisper falls into on sung vocals, where
        // greedy decoding repeats a phrase indefinitely. The default entropy /
        // logprob / no-speech thresholds (and temperature fallback) stay enabled.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.suppress_blank = true
        params.suppress_nst = true
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = noContext
        params.no_timestamps = false
        params.token_timestamps = true
        params.single_segment = false
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<WhisperCPPCancellationToken>
                .fromOpaque(userData)
                .takeUnretainedValue()
                .isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        let status = samples.withUnsafeBufferPointer {
            whisper_full(context, params, $0.baseAddress, Int32($0.count))
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard status == 0 else { throw WhisperCPPError.inferenceFailed(status) }

        let segmentCount = whisper_full_n_segments(context)
        var segments: [WhisperCPPTranscriptSegment] = []
        for segmentIndex in 0..<segmentCount {
            let segmentText = String(
                cString: whisper_full_get_segment_text(context, segmentIndex)
            )
            let tokenCount = whisper_full_n_tokens(context, segmentIndex)
            var tokens: [WhisperCPPTranscriptToken] = []
            for tokenIndex in 0..<tokenCount {
                let data = whisper_full_get_token_data(context, segmentIndex, tokenIndex)
                guard
                    WhisperCPPTokenFilter.isText(
                        tokenID: data.id,
                        endOfTextTokenID: whisper_token_eot(context)
                    )
                else { continue }
                let text = String(
                    cString: whisper_full_get_token_text(context, segmentIndex, tokenIndex)
                )
                tokens.append(
                    WhisperCPPTranscriptToken(
                        text: text,
                        start: Double(data.t0) / 100,
                        end: Double(data.t1) / 100,
                        confidence: data.p
                    ))
            }
            segments.append(
                WhisperCPPTranscriptSegment(
                    text: segmentText,
                    start: Double(whisper_full_get_segment_t0(context, segmentIndex)) / 100,
                    end: Double(whisper_full_get_segment_t1(context, segmentIndex)) / 100,
                    tokens: tokens
                ))
        }
        let languageID = whisper_full_lang_id(context)
        let languageCode = whisper_lang_str(languageID).map(String.init(cString:))
        return WhisperCPPTranscript(
            text: segments.map(\.text).joined(),
            duration: Double(samples.count) / 16_000,
            languageCode: languageCode,
            segments: segments
        )
    }

    private func loadedContext() throws -> OpaquePointer {
        if let contextHandle { return contextHandle.context }
        var parameters = whisper_context_default_params()
        parameters.use_gpu = useGPU
        parameters.flash_attn = useGPU
        guard
            let context = whisper_init_from_file_with_params(
                modelURL.path,
                parameters
            )
        else {
            throw WhisperCPPError.modelLoadFailed(modelURL)
        }
        contextHandle = WhisperCPPContextHandle(context: context)
        return context
    }
}

enum WhisperCPPTokenFilter {
    static func isText(tokenID: whisper_token, endOfTextTokenID: whisper_token) -> Bool {
        tokenID >= 0 && tokenID < endOfTextTokenID
    }
}

enum WhisperCPPRepetitionFilter {
    static func filter(
        _ transcript: WhisperCPPTranscript,
        phraseLength: Int = 6,
        maximumOccurrences: Int = 3,
        horizon: TimeInterval = 30
    ) -> WhisperCPPTranscript {
        guard phraseLength > 0, maximumOccurrences > 0 else { return transcript }
        let orderedTokens = transcript.segments.flatMap(\.tokens).sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        // Build the full normalized-word stream (skipping punctuation/blank tokens),
        // keeping a map back to the source token index for each normalized word.
        var normalizedTokens: [String] = []
        var sourceIndices: [Int] = []
        for (sourceIndex, token) in orderedTokens.enumerated() {
            let normalized = token.text
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined()
            guard !normalized.isEmpty else { continue }
            normalizedTokens.append(normalized)
            sourceIndices.append(sourceIndex)
        }
        guard normalizedTokens.count >= phraseLength else { return transcript }

        // First over-repeated phrase: the point where a length-`phraseLength` phrase
        // recurs more than `maximumOccurrences` times within `horizon` seconds.
        var occurrences: [String: [TimeInterval]] = [:]
        var cutoffTime: TimeInterval?
        var offendingPhrase: String?
        for end in (phraseLength - 1)..<normalizedTokens.count {
            let start = end - (phraseLength - 1)
            let phrase = normalizedTokens[start...end].joined(separator: " ")
            let tokenStart = orderedTokens[sourceIndices[end]].start
            var times = occurrences[phrase, default: []]
            times.append(tokenStart)
            times.removeAll { tokenStart - $0 > horizon }
            occurrences[phrase] = times
            if times.count > maximumOccurrences {
                cutoffTime = orderedTokens[sourceIndices[start]].start
                offendingPhrase = phrase
                break
            }
        }

        guard let cutoffTime, let offendingPhrase else { return transcript }

        // Find where the runaway repetition of the offending phrase ends, so that
        // distinct content AFTER the loop is preserved rather than truncated. We
        // drop only the loop region [cutoffTime, resumeTime); the first
        // `maximumOccurrences` copies (before cutoff) and any later distinct
        // content (at/after resume) are kept.
        var resumeTime = cutoffTime
        for end in (phraseLength - 1)..<normalizedTokens.count {
            let start = end - (phraseLength - 1)
            if normalizedTokens[start...end].joined(separator: " ") == offendingPhrase {
                resumeTime = max(resumeTime, orderedTokens[sourceIndices[end]].end)
            }
        }

        let keep: (WhisperCPPTranscriptToken) -> Bool = {
            $0.start < cutoffTime || $0.start >= resumeTime
        }
        let filteredSegments: [WhisperCPPTranscriptSegment] = transcript.segments.compactMap {
            segment -> WhisperCPPTranscriptSegment? in
            let tokens = segment.tokens.filter(keep)
            guard !tokens.isEmpty else { return nil }
            return WhisperCPPTranscriptSegment(
                text: tokens.map(\.text).joined(),
                start: tokens.first?.start ?? segment.start,
                end: tokens.last?.end ?? segment.end,
                tokens: tokens
            )
        }
        return WhisperCPPTranscript(
            text: filteredSegments.map(\.text).joined(),
            duration: transcript.duration,
            languageCode: transcript.languageCode,
            segments: filteredSegments
        )
    }
}

private final class WhisperCPPContextHandle: @unchecked Sendable {
    let context: OpaquePointer

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }
}

enum WhisperCPPError: LocalizedError, Equatable {
    case modelLoadFailed(URL)
    case inferenceFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let url):
            "Could not load the whisper.cpp model at \(url.path)."
        case .inferenceFailed(let status):
            "whisper.cpp inference failed with status \(status)."
        }
    }
}
