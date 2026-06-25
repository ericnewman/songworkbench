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
    /// Start a new line at a word whose first letter is uppercase (the way the
    /// transcriber capitalizes the first word of each line/sentence) when at least
    /// this much silence precedes it. The gap requirement keeps mid-line capitals
    /// such as "I" or proper nouns from breaking a line. The `maximumGap` /
    /// `maximumDuration` / `maximumTokens` bounds are generous safety nets so that
    /// line breaks are driven primarily by capitalization and sentence punctuation.
    let capitalizedLineStartGap: TimeInterval

    init(
        maximumGap: TimeInterval = 3,
        maximumDuration: TimeInterval = 15,
        maximumTokens: Int = 32,
        capitalizedLineStartGap: TimeInterval = 0.2
    ) {
        self.maximumGap = max(maximumGap, 0)
        self.maximumDuration = max(maximumDuration, 0)
        self.maximumTokens = max(maximumTokens, 1)
        self.capitalizedLineStartGap = max(capitalizedLineStartGap, 0)
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

    /// Re-groups already-segmented lyrics into lines using the current rules, driven by
    /// each segment's stored per-word timings (which preserve word case, so capitalized
    /// line-starts are honored). Lets songs analyzed before a grouping change adopt the
    /// new line breaks on load without re-transcribing. Idempotent for lyrics already
    /// grouped under the current rules.
    static func regroup(
        _ segments: [TimedLyricSegment],
        configuration: TimedLyricGroupingConfiguration = .init()
    ) -> [TimedLyricSegment] {
        // Re-grouping re-splits lines from per-word timings. Without word-level data on
        // every segment we can't find sub-line boundaries, and collapsing each line to a
        // single atomic token would merge or mangle lines — so leave the lyrics untouched.
        guard !segments.isEmpty, segments.allSatisfy({ !$0.words.isEmpty }) else {
            return segments
        }
        let tokens = segments.flatMap { segment in
            segment.words.map {
                TimedTranscriptionToken(
                    text: $0.text, startTime: $0.start, endTime: $0.end, confidence: nil)
            }
        }
        return group(tokens: tokens, configuration: configuration)
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
                let capitalizedLineStart =
                    beginsCapitalizedWord(token.text)
                    && gap >= configuration.capitalizedLineStartGap
                if isSentenceEnding(previous.text)
                    || capitalizedLineStart
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
            let layout = renderedLayout(tokens.map(\.text))
            let text = layout.text
            let start = tokens[0].startTime
            let end = tokens.map(\.endTime).max() ?? tokens[0].endTime
            return TimedLyricSegment(
                id: stableID(text: text, start: start, end: end),
                start: start,
                end: end,
                text: text,
                words: words(from: tokens, layout: layout)
            )
        }
    }

    /// Aggregates the placed tokens into words (maximal runs of tokens joined WITHOUT a
    /// separating space) and stamps each with the onset of its first token and the offset
    /// of its last token. A token that opened a new word is one a space was inserted
    /// before; attached punctuation/contraction/opening-bracket tokens (and the first
    /// token) continue the current word.
    private static func words(
        from tokens: [TimedTranscriptionToken],
        layout: RenderedLayout
    ) -> [TimedLyricWord] {
        let characters = Array(layout.text)
        var words: [TimedLyricWord] = []
        var wordStartTokenIndex = 0

        func flush(throughTokenIndex endIndex: Int) {
            let lower = layout.tokenRanges[wordStartTokenIndex].lowerBound
            let upper = layout.tokenRanges[endIndex].upperBound
            let range = lower..<upper
            words.append(
                TimedLyricWord(
                    text: String(characters[range]),
                    start: tokens[wordStartTokenIndex].startTime,
                    end: tokens[endIndex].endTime,
                    characterRange: range
                )
            )
        }

        for index in tokens.indices {
            // `index == 0` always starts the first word; otherwise a token that a space
            // preceded begins a new word, so close the previous one first.
            if index > 0, layout.tokenStartsNewWord[index] {
                flush(throughTokenIndex: index - 1)
                wordStartTokenIndex = index
            }
        }
        if !tokens.isEmpty {
            flush(throughTokenIndex: tokens.count - 1)
        }
        return words
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    /// Whether the token begins a new word started with an uppercase letter — the
    /// transcriber's signal for the first word of a line/sentence. Attached
    /// punctuation and contraction tokens (",", "'re", ...) start lowercase and so
    /// are excluded, as are mid-word continuations.
    private static func beginsCapitalizedWord(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    private static func isSentenceEnding(_ text: String) -> Bool {
        let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "}"]
        let finalContentCharacter = text.reversed().first { !closingCharacters.contains($0) }
        return finalContentCharacter.map { ".!?".contains($0) } ?? false
    }

    /// The rendered segment text plus, per token, the half-open Character-index range it
    /// occupies within that text and whether a separating space was inserted before it
    /// (i.e. it begins a new word). Mirrors the spacing rules previously implemented in
    /// `renderedText` so the produced `text` is byte-for-byte identical.
    struct RenderedLayout {
        var text: String
        var tokenRanges: [Range<Int>]
        var tokenStartsNewWord: [Bool]
    }

    private static func renderedLayout(_ tokens: [String]) -> RenderedLayout {
        let attachedPrefixes = CharacterSet(charactersIn: ",.;:!?%)]}")
        let attachedWords = ["'d", "'ll", "'m", "'re", "'s", "'t", "'ve"]

        var characters: [Character] = []
        var tokenRanges: [Range<Int>] = []
        var tokenStartsNewWord: [Bool] = []

        for token in tokens {
            let startsWithAttachedPunctuation =
                token.unicodeScalars.first
                .map(attachedPrefixes.contains) ?? false
            let attachesToPrevious =
                startsWithAttachedPunctuation
                || attachedWords.contains(where: { token.lowercased().hasPrefix($0) })
            let previousOpensGroup = characters.last.map { "([{\"".contains($0) } ?? false

            let attaches = characters.isEmpty || attachesToPrevious || previousOpensGroup
            if !attaches {
                characters.append(" ")
            }
            let lower = characters.count
            characters.append(contentsOf: token)
            tokenRanges.append(lower..<characters.count)
            // A token starts a new word exactly when a separating space preceded it.
            tokenStartsNewWord.append(!attaches)
        }

        return RenderedLayout(
            text: String(characters),
            tokenRanges: tokenRanges,
            tokenStartsNewWord: tokenStartsNewWord
        )
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
