import Foundation

struct TranscriptionRequest: Equatable, Sendable {
    let id: UUID
    let audioURL: URL
    let localeIdentifier: String?

    init(
        id: UUID = UUID(),
        audioURL: URL,
        localeIdentifier: String? = nil
    ) {
        self.id = id
        self.audioURL = audioURL
        self.localeIdentifier = localeIdentifier
    }
}

struct TranscriptionModelLicense: Codable, Equatable, Sendable {
    let name: String
    let url: URL?
}

struct TranscriptionEngineMetadata: Codable, Equatable, Sendable {
    let engineName: String
    let modelName: String
    let modelVersion: String?
    let modelSizeBytes: UInt64
    let license: TranscriptionModelLicense
    let engineVersion: String

    init(
        engineName: String,
        modelName: String,
        modelVersion: String?,
        modelSizeBytes: UInt64,
        license: TranscriptionModelLicense,
        engineVersion: String = "1"
    ) {
        self.engineName = engineName
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.modelSizeBytes = modelSizeBytes
        self.license = license
        self.engineVersion = engineVersion
    }
}

struct TimedTranscriptionToken: Codable, Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float?
}

struct TimedTranscriptionSegment: Codable, Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let tokens: [TimedTranscriptionToken]
    let confidence: Float?
}

struct TranscriptionResult: Codable, Equatable, Sendable {
    let text: String
    let languageCode: String?
    let sourceDuration: TimeInterval
    let completedAt: Date
    let segments: [TimedTranscriptionSegment]
    let engine: TranscriptionEngineMetadata
}

struct TranscriptionProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case loadingModel
        case preparingAudio
        case transcribing
        case finalizing
    }

    let phase: Phase
    let completedUnits: Int
    let totalUnits: Int
    let message: String?

    init(
        phase: Phase,
        completedUnits: Int,
        totalUnits: Int,
        message: String? = nil
    ) {
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.message = message
    }

    var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
    }
}

protocol TranscriptionEngine: Sendable {
    var metadata: TranscriptionEngineMetadata { get }

    func transcribe(
        request: TranscriptionRequest,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult

    func cancel(requestID: UUID) async
}

struct TimedLyricGroupingConfiguration: Equatable, Sendable {
    let maximumGap: TimeInterval
    let maximumDuration: TimeInterval
    let maximumTokens: Int

    init(
        maximumGap: TimeInterval = 1.25,
        maximumDuration: TimeInterval = 8,
        maximumTokens: Int = 16
    ) {
        self.maximumGap = max(maximumGap, 0)
        self.maximumDuration = max(maximumDuration, 0)
        self.maximumTokens = max(maximumTokens, 1)
    }
}

enum TimedLyricSegmentGrouper {
    static func group(
        result: TranscriptionResult,
        configuration: TimedLyricGroupingConfiguration = .init()
    ) -> [TimedLyricSegment] {
        group(
            tokens: result.segments.flatMap(\.tokens),
            configuration: configuration
        )
    }

    static func group(
        tokens: [TimedTranscriptionToken],
        configuration: TimedLyricGroupingConfiguration = .init()
    ) -> [TimedLyricSegment] {
        let orderedTokens = tokens.enumerated()
            .compactMap { index, token -> (Int, TimedTranscriptionToken)? in
                let text = normalized(token.text)
                guard !text.isEmpty else { return nil }
                return (
                    index,
                    TimedTranscriptionToken(
                        text: text,
                        startTime: token.startTime,
                        endTime: max(token.endTime, token.startTime),
                        confidence: token.confidence
                    )
                )
            }
            .sorted {
                if $0.1.startTime != $1.1.startTime {
                    return $0.1.startTime < $1.1.startTime
                }
                if $0.1.endTime != $1.1.endTime {
                    return $0.1.endTime < $1.1.endTime
                }
                return $0.0 < $1.0
            }
            .map(\.1)

        guard !orderedTokens.isEmpty else { return [] }

        var groups: [[TimedTranscriptionToken]] = []
        var current: [TimedTranscriptionToken] = []

        for token in orderedTokens {
            if let first = current.first, let previous = current.last {
                let gap = token.startTime - previous.endTime
                let duration = token.endTime - first.startTime
                if isSentenceEnding(previous.text)
                    || gap > configuration.maximumGap
                    || duration > configuration.maximumDuration
                    || current.count >= configuration.maximumTokens
                {
                    groups.append(current)
                    current = []
                }
            }
            current.append(token)
        }
        groups.append(current)

        return groups.map { tokens in
            let text = renderedText(tokens.map(\.text))
            let start = tokens[0].startTime
            let end = tokens.map(\.endTime).max() ?? tokens[0].endTime
            return TimedLyricSegment(
                id: stableID(text: text, start: start, end: end),
                start: start,
                end: end,
                text: text
            )
        }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func isSentenceEnding(_ text: String) -> Bool {
        let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "}"]
        let finalContentCharacter = text.reversed().first { !closingCharacters.contains($0) }
        return finalContentCharacter.map { ".!?".contains($0) } ?? false
    }

    private static func renderedText(_ tokens: [String]) -> String {
        let attachedPrefixes = CharacterSet(charactersIn: ",.;:!?%)]}")
        let attachedWords = ["'d", "'ll", "'m", "'re", "'s", "'t", "'ve"]

        return tokens.reduce(into: "") { result, token in
            let startsWithAttachedPunctuation =
                token.unicodeScalars.first
                .map(attachedPrefixes.contains) ?? false
            let attachesToPrevious =
                startsWithAttachedPunctuation
                || attachedWords.contains(where: { token.lowercased().hasPrefix($0) })
            let previousOpensGroup = result.last.map { "([{\"".contains($0) } ?? false

            if result.isEmpty || attachesToPrevious || previousOpensGroup {
                result += token
            } else {
                result += " " + token
            }
        }
    }

    private static func stableID(
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> UUID {
        var inputBytes = Array(text.utf8)
        inputBytes.append(contentsOf: bytes(of: start.bitPattern))
        inputBytes.append(contentsOf: bytes(of: end.bitPattern))

        let first = fnv1a(inputBytes, offset: 0xcbf2_9ce4_8422_2325)
        let second = fnv1a(inputBytes, offset: 0x8422_2325_cbf2_9ce4)
        var uuidBytes = bytes(of: first) + bytes(of: second)
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x80
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80

        return UUID(
            uuid: (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            ))
    }

    private static func fnv1a(_ bytes: [UInt8], offset: UInt64) -> UInt64 {
        bytes.reduce(offset) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
    }

    private static func bytes(of value: UInt64) -> [UInt8] {
        (0..<8).map { shift in
            UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
        }
    }
}
