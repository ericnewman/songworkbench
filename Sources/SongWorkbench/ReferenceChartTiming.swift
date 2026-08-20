import Foundation

/// Gives an uploaded, UNTIMED reference chart real timestamps, so it can be held against the same
/// audio evidence the generated chart is held against.
///
/// A reference chart is chords typeset over lyrics: the only positional information it carries is
/// a character column. `ReferenceChartComparator` compares reference text against generated text,
/// which can show that the two disagree but never which one the recording supports. Timing the
/// reference is what turns it into something `ChordEvidenceAudit` can judge.
///
/// Alignment is deliberately by WORD INDEX, not character offset. A reference chart carries the
/// real lyrics while our segments carry ASR output, so the two texts differ in spelling, elisions,
/// and punctuation — a character column from one does not address the other. Word index survives
/// those differences: the third word of a line is the third word in both.
enum ReferenceChartTiming {
    struct TimedReference: Equatable, Sendable {
        /// Reference chords that could be placed on the timeline.
        let events: [EditableChordEvent]
        /// Chords on reference lines that matched no transcribed line, so no honest time exists
        /// for them. Reported rather than guessed — a chord timed by assumption would then be
        /// "validated" against audio at a position nothing put it at.
        let untimedChordCount: Int
        /// Reference lyric lines that matched one of ours.
        let matchedLineCount: Int
        let referenceLineCount: Int
    }

    /// Minimum normalized-token overlap for two lyric lines to be considered the same line. Same
    /// threshold and monotonic-greedy shape `ReferenceChartComparator` uses, so the two agree
    /// about which lines correspond.
    static let lineMatchThreshold = 0.5
    /// How far ahead of the cursor a match may be found. Bounds the search and keeps verses in
    /// order, so a repeated chorus line can't pull the alignment backwards.
    static let lineMatchLookahead = 6

    /// Time every chord in `reference` against `lyricSegments`.
    ///
    /// A chord's time is the start of the word it sits over. A chord typeset before the first word
    /// (a line-opening chord) takes the line's start; one past the last word takes the last word's
    /// start, since it is still that word being sung when it lands.
    static func timedEvents(
        reference: String,
        lyricSegments: [TimedLyricSegment]
    ) throws -> TimedReference {
        let referenceLines = try sungLines(from: reference)
        let ours =
            lyricSegments
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
        guard !referenceLines.isEmpty, !ours.isEmpty else {
            return TimedReference(
                events: [],
                untimedChordCount: referenceLines.reduce(0) { $0 + $1.chords.count },
                matchedLineCount: 0,
                referenceLineCount: referenceLines.count
            )
        }

        var events: [EditableChordEvent] = []
        var untimed = 0
        var matched = 0
        var cursor = 0
        for referenceLine in referenceLines {
            guard let match = bestMatch(for: referenceLine, in: ours, from: cursor) else {
                untimed += referenceLine.chords.count
                continue
            }
            matched += 1
            cursor = match + 1
            let segment = ours[match]
            let ourWords = segment.words.sorted { $0.start < $1.start }

            for chord in referenceLine.chords.sorted(by: { $0.column < $1.column }) {
                let time: TimeInterval
                if ourWords.isEmpty {
                    // Line-level timing only: every chord on the line gets the line's start. It is
                    // the honest resolution available, and the audit will judge it on that basis.
                    time = segment.start
                } else {
                    let wordIndex = referenceLine.wordIndex(atColumn: chord.column)
                    time = ourWords[min(max(wordIndex, 0), ourWords.count - 1)].start
                }
                events.append(
                    EditableChordEvent(time: time, chord: chord.name, confidence: nil))
            }
        }

        return TimedReference(
            events: events.sorted { $0.time < $1.time },
            untimedChordCount: untimed,
            matchedLineCount: matched,
            referenceLineCount: referenceLines.count
        )
    }

    // MARK: - Reference parsing

    struct ReferenceLine: Equatable, Sendable {
        let lyric: String
        let tokens: Set<String>
        let chords: [ChordProPreviewChord]
        /// Character range of each word in `lyric`, in order.
        let wordRanges: [Range<Int>]

        /// Index of the word a chord at `column` sits over: the word containing the column, else
        /// the last word starting at or before it, else the first word.
        func wordIndex(atColumn column: Int) -> Int {
            if let index = wordRanges.firstIndex(where: { $0.contains(column) }) { return index }
            if let index = wordRanges.lastIndex(where: { $0.lowerBound <= column }) { return index }
            return 0
        }
    }

    static func sungLines(from source: String) throws -> [ReferenceLine] {
        let document = try ChordProPreviewDocument(parsing: source)
        return document.blocks.compactMap { block -> ReferenceLine? in
            guard case .lyric(let line) = block, line.hasSungText else { return nil }
            let lyric = line.lyric
            return ReferenceLine(
                lyric: lyric.trimmingCharacters(in: .whitespaces),
                tokens: normalizedTokens(lyric),
                chords: line.chords,
                wordRanges: wordRanges(in: lyric)
            )
        }
    }

    static func normalizedTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 })
    }

    /// Character ranges of whitespace-delimited words, measured in Characters so they line up with
    /// the columns `ChordProPreviewChord` records.
    static func wordRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, character) in text.enumerated() {
            if character.isWhitespace {
                if let begin = start { ranges.append(begin..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { ranges.append(begin..<text.count) }
        return ranges
    }

    private static func bestMatch(
        for line: ReferenceLine,
        in segments: [TimedLyricSegment],
        from cursor: Int
    ) -> Int? {
        guard cursor < segments.count else { return nil }
        var best: (index: Int, score: Double)?
        for index in cursor..<min(cursor + lineMatchLookahead, segments.count) {
            let score = similarity(line.tokens, normalizedTokens(segments[index].text))
            if score >= lineMatchThreshold, score > (best?.score ?? 0) {
                best = (index, score)
            }
        }
        return best?.index
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
