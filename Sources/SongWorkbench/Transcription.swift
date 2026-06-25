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
        capitalizedLineStartGap: TimeInterval = 0.3
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
                // A capitalized word starts a new line — but only past the first token, so a
                // run of consecutive capitalized words (e.g. "Charcoal Crackle Sparks") sung
                // together isn't split into one-word orphan lines.
                let capitalizedLineStart =
                    beginsCapitalizedWord(token.text)
                    && gap >= configuration.capitalizedLineStartGap
                    && current.count >= 2
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

/// Repairs garbled words in REPEATED song lines (choruses) using cross-line consensus.
///
/// Transcribers mishear the same chorus differently on each pass — "flip flops" becomes
/// "slip flops", "bruise" becomes "Brooms". When a line recurs three or more times we can
/// recover the intended word by majority vote: align the repeats word-for-word and, at each
/// column where a strict two-thirds majority of the repeats agree, rewrite the dissenters to
/// match.
///
/// The corrector is deliberately conservative. It votes only WITHIN a cluster of near-duplicate
/// lines (never song-wide, which would let common theme words overrun correct rare ones), aligns
/// with real word-level sequence alignment (never by positional index, which corrupts lines whose
/// content has shifted), and changes a word only when a clear ≥2/3 majority disagrees with it.
/// With no clear consensus it is a no-op, and applying it twice changes nothing.
struct RepeatedLyricCorrector: Sendable {
    /// Minimum Jaccard similarity of two lines' normalized word sets to cluster them together.
    private let clusterSimilarityThreshold = 0.6
    /// Minimum cluster size to attempt correction — need enough repeats for a real majority.
    private let minimumClusterSize = 3

    /// A normalized comparison word plus the index of the `segment.words` token it came from.
    private struct ComparisonWord {
        var core: String
        var wordIndex: Int
    }

    func corrected(_ segments: [TimedLyricSegment]) -> [TimedLyricSegment] {
        // Comparison words per segment; nil for segments we leave untouched (empty `words`).
        // Each carries the originating `segment.words` index so a voted column maps back to the
        // exact token to rewrite — all-punctuation tokens (empty core) are excluded from voting.
        let comparisonWords = segments.map { segment -> [ComparisonWord]? in
            guard !segment.words.isEmpty else { return nil }
            let words = segment.words.enumerated().compactMap {
                index, word -> ComparisonWord? in
                let normalized = core(of: word.text).lowercased()
                return normalized.isEmpty ? nil : ComparisonWord(core: normalized, wordIndex: index)
            }
            return words.isEmpty ? nil : words
        }

        let clusters = cluster(comparisonWords)

        var result = segments
        for cluster in clusters where cluster.count >= minimumClusterSize {
            applyConsensus(
                to: &result,
                members: cluster,
                comparisonWords: comparisonWords
            )
        }
        return result
    }

    // MARK: - Clustering

    /// Greedily groups segment indices whose normalized word SETS have Jaccard similarity
    /// ≥ threshold with the cluster's seed line. Segments without comparison words are skipped.
    private func cluster(_ comparisonWords: [[ComparisonWord]?]) -> [[Int]] {
        var clusters: [[Int]] = []
        var seedSets: [Set<String>] = []

        for index in comparisonWords.indices {
            guard let words = comparisonWords[index], !words.isEmpty else { continue }
            let set = Set(words.map(\.core))
            if let match = seedSets.indices.first(where: {
                jaccard(seedSets[$0], set) >= clusterSimilarityThreshold
            }) {
                clusters[match].append(index)
            } else {
                clusters.append([index])
                seedSets.append(set)
            }
        }
        return clusters
    }

    private func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    // MARK: - Consensus

    private func applyConsensus(
        to segments: inout [TimedLyricSegment],
        members: [Int],
        comparisonWords: [[ComparisonWord]?]
    ) {
        let memberWords = members.map { comparisonWords[$0] ?? [] }

        // Reference = the member whose word count is the most common length; ties break toward
        // the earliest member. Aligning every other member onto this reference gives a stable set
        // of columns to vote over.
        guard let referenceLocal = referenceMemberIndex(memberWords) else { return }
        let referenceCores = memberWords[referenceLocal].map(\.core)
        guard !referenceCores.isEmpty else { return }

        // For each member, the index into that member's comparison words aligned to each reference
        // column (nil = gap).
        let alignedIndices = memberWords.map {
            alignWithIndices(reference: referenceCores, other: $0.map(\.core))
        }

        // Consensus core per reference column, or nil when no strict ≥2/3 majority winner exists.
        var consensus: [String?] = Array(repeating: nil, count: referenceCores.count)
        let required = Int((Double(members.count) * 2.0 / 3.0).rounded(.up))
        for column in referenceCores.indices {
            var counts: [String: Int] = [:]
            for member in members.indices {
                if let index = alignedIndices[member][column] {
                    counts[memberWords[member][index].core, default: 0] += 1
                }
            }
            let ranked = counts.sorted { $0.value > $1.value }
            if let top = ranked.first, top.value >= required,
                ranked.count == 1 || ranked[1].value < top.value
            {
                consensus[column] = top.key
            }
        }

        // Rewrite each member that disagrees with a consensus column.
        for (local, segmentIndex) in members.enumerated() {
            var replacements: [Int: String] = [:]  // segment word index -> new core
            for column in referenceCores.indices {
                guard let target = consensus[column] else { continue }
                guard let index = alignedIndices[local][column] else { continue }
                let comparison = memberWords[local][index]
                if comparison.core != target {
                    replacements[comparison.wordIndex] = target
                }
            }
            if !replacements.isEmpty,
                let rewritten = rewrite(segments[segmentIndex], replacements: replacements)
            {
                segments[segmentIndex] = rewritten
            }
        }
    }

    private func referenceMemberIndex(_ memberWords: [[ComparisonWord]]) -> Int? {
        let lengths = memberWords.map(\.count).filter { $0 > 0 }
        guard !lengths.isEmpty else { return nil }
        var frequency: [Int: Int] = [:]
        for length in lengths { frequency[length, default: 0] += 1 }
        let mostCommon = frequency.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.first
        guard let targetLength = mostCommon?.key else { return nil }
        return memberWords.firstIndex { $0.count == targetLength }
    }

    // MARK: - Word-level alignment (Needleman–Wunsch)

    /// Aligns `other` onto `reference`, returning the index into `other` for each reference column
    /// (nil = gap). Words inserted by `other` that don't line up with any reference column are
    /// dropped (they can't be voted on against the reference's columns).
    private func alignWithIndices(reference: [String], other: [String]) -> [Int?] {
        let n = reference.count
        let m = other.count
        let gapPenalty = -1
        let mismatch = -1
        let match = 1

        var scores = Array(
            repeating: Array(repeating: 0, count: m + 1),
            count: n + 1
        )
        for i in 0...n { scores[i][0] = i * gapPenalty }
        for j in 0...m { scores[0][j] = j * gapPenalty }
        for i in 1...max(n, 1) where n > 0 {
            for j in 1...max(m, 1) where m > 0 {
                let cost = reference[i - 1] == other[j - 1] ? match : mismatch
                let diagonal = scores[i - 1][j - 1] + cost
                let up = scores[i - 1][j] + gapPenalty
                let left = scores[i][j - 1] + gapPenalty
                scores[i][j] = Swift.max(diagonal, up, left)
            }
        }

        // Traceback. `columnWord[i]` is the `other` index aligned to reference column i, or nil.
        var columnWord: [Int?] = Array(repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let cost = reference[i - 1] == other[j - 1] ? match : mismatch
                if scores[i][j] == scores[i - 1][j - 1] + cost {
                    columnWord[i - 1] = j - 1
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, scores[i][j] == scores[i - 1][j] + gapPenalty {
                // Reference word i-1 aligned to a gap in `other`.
                i -= 1
                continue
            }
            // Otherwise an `other` word j-1 aligned to a gap in reference; drop it.
            j -= 1
        }
        return columnWord
    }

    // MARK: - Rewriting

    /// Replaces the alphanumeric core of the indicated words with new cores, preserving each
    /// token's surrounding punctuation and leading capitalization, then recomputes character
    /// ranges. Returns nil (caller keeps the original) if the rewrite would change the word count.
    private func rewrite(
        _ segment: TimedLyricSegment,
        replacements: [Int: String]
    ) -> TimedLyricSegment? {
        var newWordTexts = segment.words.map(\.text)
        for (index, newCore) in replacements {
            guard index >= 0, index < newWordTexts.count else { return nil }
            newWordTexts[index] = replacingCore(in: newWordTexts[index], with: newCore)
        }

        // Rebuild the segment text right-to-left by character range so earlier ranges stay valid.
        var characters = Array(segment.text)
        for index in segment.words.indices.sorted(by: >) {
            let range = segment.words[index].characterRange
            guard range.lowerBound >= 0, range.upperBound <= characters.count else { return nil }
            characters.replaceSubrange(range, with: Array(newWordTexts[index]))
        }
        let newText = String(characters)

        // Recompute character ranges by re-scanning whitespace-delimited tokens. A mismatched
        // token count means our edit disturbed the spacing — fall back to leaving it unchanged.
        let tokens = whitespaceTokens(in: newText)
        guard tokens.count == segment.words.count else { return nil }

        var newWords = segment.words
        for index in newWords.indices {
            newWords[index].text = String(Array(newText)[tokens[index]])
            newWords[index].characterRange = tokens[index]
        }

        var corrected = segment
        corrected.text = newText
        corrected.words = newWords
        return corrected
    }

    /// Whitespace-delimited token ranges (half-open Character-index ranges) within `text`.
    private func whitespaceTokens(in text: String) -> [Range<Int>] {
        let characters = Array(text)
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in characters.indices {
            if characters[index].isWhitespace {
                if let begin = start {
                    ranges.append(begin..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { ranges.append(begin..<characters.count) }
        return ranges
    }

    /// Replaces the leading alphanumeric run of `token` with `core`, matching the original run's
    /// leading capitalization, and keeps all surrounding (and trailing) punctuation. "Brooms" with
    /// core "bruise" → "Bruise"; "barbecue," → "bruise,".
    private func replacingCore(in token: String, with core: String) -> String {
        let characters = Array(token)
        var coreStart = 0
        while coreStart < characters.count, !characters[coreStart].isLetter,
            !characters[coreStart].isNumber
        {
            coreStart += 1
        }
        var coreEnd = coreStart
        while coreEnd < characters.count,
            characters[coreEnd].isLetter || characters[coreEnd].isNumber
        {
            coreEnd += 1
        }
        guard coreStart < coreEnd else { return token }

        let originalFirst = characters[coreStart]
        let cased: String
        if originalFirst.isUppercase {
            cased = core.prefix(1).uppercased() + core.dropFirst()
        } else {
            cased = core
        }

        let prefix = String(characters[0..<coreStart])
        let suffix = String(characters[coreEnd..<characters.count])
        return prefix + cased + suffix
    }

    /// The lowercased alphanumeric core of a word token (strips surrounding punctuation).
    private func core(of token: String) -> String {
        String(token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// Drops stray, low-confidence tokens that sit isolated in a long silence, restoring the
/// instrumental/intro/outro gaps that the ChordPro chart renders.
///
/// Some transcription engines hallucinate a stray low-confidence word during an instrumental
/// or silent section. A single mis-heard word dropped into a 10-second instrumental break fills
/// the gap and erases the section. This gate removes such tokens — but only when they are
/// *clearly* spurious, never when they could be a real (if quietly sung) lyric.
///
/// The gate is deliberately conservative. It only considers "islands": maximal runs of tokens
/// fenced off from their neighbours (and, at the song edges, from the song boundary) by a long
/// silence on BOTH sides. An island is dropped only when EVERY one of its tokens is low
/// confidence (and none has nil confidence), the island is short (few tokens), and its total sung
/// duration is small. Any nil-confidence token, any high-confidence token, a longer run, or a
/// token that isn't isolated keeps the whole island — so real lyric lines are never removed.
/// Applying the gate twice changes nothing.
enum TranscriptionSilenceGate {
    struct Configuration: Equatable, Sendable {
        /// Minimum silence (seconds) that must fence an island on BOTH sides for it to be
        /// eligible for dropping. At the song's very start/end the distance to time 0 / the last
        /// token's end is the silence on that side.
        let isolationSilence: TimeInterval
        /// An island is eligible only if every token's confidence is below this threshold.
        let confidenceThreshold: Float
        /// An island is eligible only if it has at most this many tokens.
        let maxIslandTokens: Int
        /// An island is eligible only if its total sung duration (sum of token spans) is at most
        /// this many seconds.
        let maxIslandDuration: TimeInterval
        /// A single low-confidence token whose span exceeds this many seconds is treated as a
        /// "padded stray" and dropped outright, independent of the island logic. Whisper pads the
        /// first word after a silence to the next vocal onset, so a hallucinated word over an
        /// instrumental section can report a span of many seconds (e.g. a 20s "Grass" at 0.0 with
        /// 0.045 confidence). No real word is sung this long, and the padding hides the surrounding
        /// silence from the gap-based island split, so it must be caught directly.
        let maxPlausibleWordDuration: TimeInterval

        init(
            isolationSilence: TimeInterval = 2.0,
            confidenceThreshold: Float = 0.5,
            maxIslandTokens: Int = 4,
            maxIslandDuration: TimeInterval = 1.5,
            maxPlausibleWordDuration: TimeInterval = 5.0
        ) {
            self.isolationSilence = max(isolationSilence, 0)
            self.confidenceThreshold = max(confidenceThreshold, 0)
            self.maxIslandTokens = max(maxIslandTokens, 1)
            self.maxIslandDuration = max(maxIslandDuration, 0)
            self.maxPlausibleWordDuration = max(maxPlausibleWordDuration, 0)
        }
    }

    /// Filters the flattened, time-sorted tokens (the `result.segments.flatMap(\.tokens)`
    /// ordering is the input contract), returning the survivors in their original relative order.
    static func filtered(
        _ tokens: [TimedTranscriptionToken],
        configuration: Configuration = .init()
    ) -> [TimedTranscriptionToken] {
        guard !tokens.isEmpty else { return tokens }

        // Pre-pass: drop "padded strays" — a lyric token sustained implausibly long with low
        // confidence (Whisper padding a hallucinated word over an instrumental section). Its long
        // span hides the surrounding silence from the gap-based island split below, so it must be
        // removed first. Whitespace tokens are never strays.
        let paddedStrayIndices = Set(
            tokens.enumerated().compactMap { offset, token -> Int? in
                guard !isWhitespace(token.text),
                    let confidence = token.confidence,
                    confidence < configuration.confidenceThreshold,
                    token.endTime - token.startTime > configuration.maxPlausibleWordDuration
                else { return nil }
                return offset
            }
        )

        // Sort the non-stray tokens by startTime (stably, by original index). Padded strays are
        // excluded so the island split sees the true silence they were masking.
        let ordered = tokens.enumerated()
            .filter { !paddedStrayIndices.contains($0.offset) }
            .sorted {
                if $0.element.startTime != $1.element.startTime {
                    return $0.element.startTime < $1.element.startTime
                }
                return $0.offset < $1.offset
            }

        // Whitespace-only tokens shouldn't define or split islands, but their time spans still
        // count toward gap math. Split the ordered tokens into islands at every gap >= the
        // isolation silence, then decide per island whether to drop it.
        let droppedOriginalIndices = droppedIndices(
            ordered: ordered,
            configuration: configuration
        )
        .union(paddedStrayIndices)
        guard !droppedOriginalIndices.isEmpty else { return tokens }

        return tokens.enumerated()
            .filter { !droppedOriginalIndices.contains($0.offset) }
            .map(\.element)
    }

    /// The set of ORIGINAL token indices to drop. An entry in `ordered` is `(offset, element)`
    /// where `offset` is the index into the caller's array.
    private static func droppedIndices(
        ordered: [(offset: Int, element: TimedTranscriptionToken)],
        configuration: Configuration
    ) -> Set<Int> {
        // Group into islands: a new island starts whenever the gap from the previous token's end
        // to this token's start is >= the isolation silence.
        var islands: [[(offset: Int, element: TimedTranscriptionToken)]] = []
        var current: [(offset: Int, element: TimedTranscriptionToken)] = []
        for entry in ordered {
            if let previous = current.last {
                let gap = entry.element.startTime - previous.element.endTime
                if gap >= configuration.isolationSilence {
                    islands.append(current)
                    current = []
                }
            }
            current.append(entry)
        }
        if !current.isEmpty { islands.append(current) }

        // The song's start and end are treated as fully isolating silence boundaries (see the
        // preceding/following silence comments below).
        var dropped = Set<Int>()
        for index in islands.indices {
            let island = islands[index]

            // Outer silence on the preceding side: a real gap to the prior island, or — for the
            // first island — the song's start. Nothing is sung before the song begins, so the
            // start boundary counts as fully isolating silence; this lets a leading stray (e.g.
            // Whisper hallucinating a word at 0.0 before the first real line) be dropped. Real
            // opening lines survive via the shouldDrop guards (low-confidence AND short).
            let precedingSilence: TimeInterval
            if index == 0 {
                precedingSilence = configuration.isolationSilence
            } else {
                precedingSilence =
                    (island.first?.element.startTime ?? 0)
                    - (islands[index - 1].last?.element.endTime ?? 0)
            }

            // Following silence: a real gap to the next island, or — for the last island — the
            // song's end, treated symmetrically as fully isolating silence so a trailing stray can
            // be dropped.
            let followingSilence: TimeInterval
            if index == islands.count - 1 {
                followingSilence = configuration.isolationSilence
            } else {
                followingSilence =
                    (islands[index + 1].first?.element.startTime ?? 0)
                    - (island.last?.element.endTime ?? 0)
            }

            let isolated =
                precedingSilence >= configuration.isolationSilence
                && followingSilence >= configuration.isolationSilence
            guard isolated else { continue }

            if shouldDrop(island: island.map(\.element), configuration: configuration) {
                for entry in island { dropped.insert(entry.offset) }
            }
        }
        return dropped
    }

    /// Whether an isolated island is a stray hallucination safe to drop. Conservative AND: every
    /// token low-confidence (none nil), few tokens, small total sung duration. Whitespace-only
    /// tokens are ignored for the count/duration/confidence checks (they carry no lyric), but an
    /// island of only whitespace is never dropped.
    private static func shouldDrop(
        island: [TimedTranscriptionToken],
        configuration: Configuration
    ) -> Bool {
        let lyricTokens = island.filter { !isWhitespace($0.text) }
        guard !lyricTokens.isEmpty else { return false }

        guard lyricTokens.count <= configuration.maxIslandTokens else { return false }

        let totalDuration = lyricTokens.reduce(0.0) {
            $0 + max($1.endTime - $1.startTime, 0)
        }
        guard totalDuration <= configuration.maxIslandDuration else { return false }

        // Every lyric token must be present-and-low confidence. A nil or high-confidence token
        // could be a real sung word, so the whole island is kept.
        for token in lyricTokens {
            guard let confidence = token.confidence,
                confidence < configuration.confidenceThreshold
            else { return false }
        }
        return true
    }

    private static func isWhitespace(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
