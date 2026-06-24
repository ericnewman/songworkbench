import Foundation

struct ChordProPreviewDocument: Equatable, Sendable {
    let blocks: [ChordProPreviewBlock]

    init(parsing source: String) throws {
        self.init(document: try ChordProDocument(parsing: source))
    }

    init(document: ChordProDocument) {
        var builder = Builder()
        for element in document.elements {
            builder.append(element)
        }
        blocks = builder.finish()
    }
}

enum ChordProPreviewBlock: Equatable, Sendable {
    case title(String)
    case metadata(label: String, value: String)
    case section(String)
    case comment(String)
    case lyric(ChordProPreviewLine)
    case directive(String)
}

struct ChordProPreviewLine: Equatable, Sendable {
    let lyric: String
    let chords: [ChordProPreviewChord]
}

struct ChordProPreviewChord: Equatable, Sendable {
    let name: String
    let column: Int
}

enum ChordProPlaybackHighlightStyle: Sendable {
    case chord
    case bassNote
}

struct ChordProLinePlaybackHighlight: Equatable, Sendable {
    let wordRange: Range<Int>?
    let chordLabels: Set<String>
}

/// Concentrates the per-frame playback-highlight derivation. Construct it once from the
/// timed lyric/chord inputs (which it sorts and prepares up front) and then issue the
/// separate queries below for whatever `currentTime` the playhead is at.
struct ChordProHighlightDeriver: Sendable {
    private let sortedLyrics: [TimedLyricSegment]
    private let chordEvents: [EditableChordEvent]
    private let confidenceThreshold: Float

    init(
        lyricSegments: [TimedLyricSegment],
        chordEvents: [EditableChordEvent],
        confidenceThreshold: Float
    ) {
        sortedLyrics =
            lyricSegments
            .filter { !$0.text.isEmpty }
            .sorted {
                if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
        self.chordEvents = chordEvents
        self.confidenceThreshold = confidenceThreshold
    }

    /// The ordinal (index into the sorted lyric segments) of the lyric active at
    /// `currentTime`, where a lyric is active for `currentTime` in `[start, end)`.
    func lyricOrdinal(at currentTime: TimeInterval) -> Int? {
        sortedLyrics.firstIndex(where: {
            currentTime >= $0.start && currentTime < $0.end
        })
    }

    /// The ordinal of the next lyric beginning strictly after `currentTime` — used,
    /// when no lyric is currently active, to park the waiting ball at the start of the
    /// upcoming line during an instrumental gap.
    func upcomingLyricOrdinal(at currentTime: TimeInterval) -> Int? {
        sortedLyrics.firstIndex(where: { currentTime < $0.start })
    }

    /// The sorted lyric segment at `ordinal`, or `nil` when out of range. Lets callers
    /// recover the active segment's start/end/text to drive the beat-synced ball.
    func segment(atOrdinal ordinal: Int) -> TimedLyricSegment? {
        guard sortedLyrics.indices.contains(ordinal) else { return nil }
        return sortedLyrics[ordinal]
    }

    /// The character range of the word active at `currentTime` within the lyric at `ordinal`.
    func wordRange(inLyricOrdinal ordinal: Int, at currentTime: TimeInterval) -> Range<Int>? {
        guard sortedLyrics.indices.contains(ordinal) else { return nil }
        return wordRange(in: sortedLyrics[ordinal], at: currentTime)
    }

    /// The character range of the word active at `currentTime` within `lyric`.
    ///
    /// When the segment carries real per-word timings, the active word is the one whose
    /// `[start, end)` contains `currentTime`, else the most recent word with `start <=
    /// currentTime` (so the final word stays lit until the segment ends), clamped to the
    /// segment text length. Without word timings it falls back to even interpolation.
    func wordRange(in lyric: TimedLyricSegment, at currentTime: TimeInterval) -> Range<Int>? {
        if !lyric.words.isEmpty {
            return Self.wordRange(in: lyric.words, textLength: lyric.text.count, at: currentTime)
        }
        let ranges = Self.wordRanges(in: lyric.text)
        guard !ranges.isEmpty else { return nil }
        let duration = max(lyric.end - lyric.start, 0.001)
        let relative = min(max((currentTime - lyric.start) / duration, 0), 0.999_999)
        let index = min(Int(relative * Double(ranges.count)), ranges.count - 1)
        return ranges[index]
    }

    private static func wordRange(
        in words: [TimedLyricWord],
        textLength: Int,
        at currentTime: TimeInterval
    ) -> Range<Int>? {
        let active: TimedLyricWord?
        if let containing = words.last(where: { $0.start <= currentTime && currentTime < $0.end }) {
            active = containing
        } else {
            active = words.last(where: { $0.start <= currentTime })
        }
        guard let word = active else { return nil }
        let lower = min(max(word.characterRange.lowerBound, 0), textLength)
        let upper = min(max(word.characterRange.upperBound, lower), textLength)
        return lower..<upper
    }

    /// The active chord labels at `currentTime` within the lyric at `ordinal`, rendered
    /// per `style` (raw chord symbols vs. derived bass-note labels).
    func activeChordLabels(
        at currentTime: TimeInterval,
        forLyricOrdinal ordinal: Int,
        style: ChordProPlaybackHighlightStyle
    ) -> Set<String> {
        guard sortedLyrics.indices.contains(ordinal) else { return [] }
        return activeChordLabels(at: currentTime, in: sortedLyrics[ordinal], style: style)
    }

    func activeChordLabels(
        at currentTime: TimeInterval,
        in lyric: TimedLyricSegment,
        style: ChordProPlaybackHighlightStyle
    ) -> Set<String> {
        let included =
            chordEvents
            .filter { event in
                event.time >= lyric.start
                    && event.time < lyric.end
                    && (event.confidence.map { $0 >= confidenceThreshold } ?? true)
                    && event.time <= currentTime
            }
            .sorted {
                if $0.time == $1.time { return $0.chord < $1.chord }
                return $0.time < $1.time
            }
        guard let active = included.last else { return [] }
        switch style {
        case .chord:
            return [active.chord]
        case .bassNote:
            return BassNote(chordSymbol: active.chord).map { [$0.label] } ?? []
        }
    }

    private static func wordRanges(in text: String) -> [Range<Int>] {
        let characters = Array(text)
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in characters.indices {
            if characters[index].isWhitespace {
                if let wordStart = start {
                    ranges.append(wordStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let wordStart = start {
            ranges.append(wordStart..<characters.count)
        }
        return ranges
    }
}

/// Pure, unit-tested geometry for the karaoke "bouncing ball" that taps the word
/// coinciding with each beat at the beat moment, arcs up to an apex around mid-beat,
/// then descends to tap the next beat's word. Construct it with the beat times that
/// fall within (or just around) the active lyric segment plus the target x-position of
/// the word each beat lands on; query `position(at:)` for the playhead's current time.
struct BouncingBall: Sendable {
    /// The ordered beat times the ball travels along (ascending).
    let beatTimes: [TimeInterval]
    /// The horizontal target (word center x) for the beat at the same index.
    let beatX: [CGFloat]

    /// Chooses the beats relevant to a lyric segment.
    ///
    /// If `beatTimes` has entries inside `[segmentStart, segmentEnd]`, those are used
    /// (sorted, filtered to the range) plus, when present, the last beat at or before
    /// `segmentStart` and the first beat at or after `segmentEnd` so the arc has
    /// neighbors on both ends. When `beatTimes` is empty, beats are synthesized from
    /// `bpm` (guarded to be non-nil and positive) at `segmentStart + k*beatDuration`
    /// for `k = 0, 1, ...` while `<= segmentEnd`, plus one extra beat beyond the end.
    static func beats(
        in segmentStart: TimeInterval,
        _ segmentEnd: TimeInterval,
        beatTimes: [TimeInterval],
        bpm: Double?
    ) -> [TimeInterval] {
        let sorted = beatTimes.sorted()
        let within = sorted.filter { $0 >= segmentStart && $0 <= segmentEnd }
        if !within.isEmpty {
            var result = within
            if let neighborBefore = sorted.last(where: { $0 < segmentStart }) {
                result.insert(neighborBefore, at: 0)
            }
            if let neighborAfter = sorted.first(where: { $0 > segmentEnd }) {
                result.append(neighborAfter)
            }
            return result
        }

        guard let bpm, bpm > 0 else { return [] }
        let beatDuration = 60.0 / bpm
        guard beatDuration > 0 else { return [] }
        var result: [TimeInterval] = []
        var k = 0
        while true {
            let time = segmentStart + Double(k) * beatDuration
            if time <= segmentEnd {
                result.append(time)
                k += 1
            } else {
                // One extra beat beyond the end to give the final tap a neighbor.
                result.append(time)
                break
            }
        }
        return result
    }

    /// The ball position at `currentTime`: the horizontal `x` and a normalized `lift`
    /// in `0...1` (0 = tapping the word, 1 = apex). Returns `nil` before the first beat
    /// or after the last beat.
    func position(at currentTime: TimeInterval) -> (x: CGFloat, lift: CGFloat)? {
        guard let first = beatTimes.first, let last = beatTimes.last else { return nil }
        guard currentTime >= first, currentTime <= last else { return nil }

        // prevBeat = last beat <= currentTime; nextBeat = first beat > currentTime.
        var prevIndex = 0
        for index in beatTimes.indices where beatTimes[index] <= currentTime {
            prevIndex = index
        }
        let nextIndex: Int
        if let found = beatTimes.indices.first(where: { beatTimes[$0] > currentTime }) {
            nextIndex = found
        } else {
            nextIndex = prevIndex  // clamp to last
        }

        let prevBeat = beatTimes[prevIndex]
        let nextBeat = beatTimes[nextIndex]
        let xPrev = beatX[prevIndex]
        let xNext = beatX[nextIndex]

        let p = min(max((currentTime - prevBeat) / max(nextBeat - prevBeat, 0.0001), 0), 1)
        let x = Self.lerp(xPrev, xNext, CGFloat(Self.smoothstep(p)))
        let lift = Self.lift(forFraction: p)
        return (x: x, lift: CGFloat(lift))
    }

    /// Slow rise, quick descent: 0 at beats (tap), 1 at mid-beat (apex).
    static func lift(forFraction p: Double) -> Double {
        if p < 0.5 {
            return easeOut(p / 0.5)
        } else {
            return 1 - easeIn((p - 0.5) / 0.5)
        }
    }

    static func smoothstep(_ p: Double) -> Double { p * p * (3 - 2 * p) }
    static func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
    static func easeIn(_ t: Double) -> Double { t * t }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

struct ChordProPlaybackHighlightContext: Equatable, Sendable {
    private let activeLyricOrdinal: Int?
    private let lineHighlight: ChordProLinePlaybackHighlight?

    init(
        currentTime: TimeInterval,
        lyricSegments: [TimedLyricSegment],
        chordEvents: [EditableChordEvent],
        confidenceThreshold: Float,
        style: ChordProPlaybackHighlightStyle
    ) {
        let deriver = ChordProHighlightDeriver(
            lyricSegments: lyricSegments,
            chordEvents: chordEvents,
            confidenceThreshold: confidenceThreshold
        )
        guard let lyricIndex = deriver.lyricOrdinal(at: currentTime) else {
            activeLyricOrdinal = nil
            lineHighlight = nil
            return
        }

        activeLyricOrdinal = lyricIndex
        lineHighlight = ChordProLinePlaybackHighlight(
            wordRange: deriver.wordRange(inLyricOrdinal: lyricIndex, at: currentTime),
            chordLabels: deriver.activeChordLabels(
                at: currentTime,
                forLyricOrdinal: lyricIndex,
                style: style
            )
        )
    }

    /// The ordinal of the currently active lyric line, or `nil` when nothing is playing.
    /// Used to drive auto-scroll of the preview to the highlighted line.
    var currentLyricOrdinal: Int? { activeLyricOrdinal }

    func highlight(forLyricOrdinal ordinal: Int?) -> ChordProLinePlaybackHighlight? {
        guard ordinal == activeLyricOrdinal else { return nil }
        return lineHighlight
    }
}

extension ChordProPreviewDocument {
    fileprivate struct Builder {
        private(set) var blocks: [ChordProPreviewBlock] = []
        private var lyric = ""
        private var chords: [ChordProPreviewChord] = []
        private var hasLineContent = false

        mutating func append(_ element: ChordProElement) {
            switch element {
            case .chord(let chord):
                chords.append(ChordProPreviewChord(name: chord.description, column: lyric.count))
                hasLineContent = true
            case .text(let text):
                appendText(text)
            case .directive(let source):
                flushLyricLineIfNeeded()
                if let block = Self.previewBlock(forDirective: source) {
                    blocks.append(block)
                }
            }
        }

        mutating func finish() -> [ChordProPreviewBlock] {
            flushLyricLineIfNeeded()
            return blocks
        }

        private mutating func appendText(_ text: String) {
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == "\n" || character == "\r\n" || character == "\r" {
                    flushLyricLine(includingBlank: true)
                } else if character == "\\" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "[" || text[next] == "]" {
                        lyric.append(text[next])
                        hasLineContent = true
                        index = next
                    } else {
                        lyric.append(character)
                        hasLineContent = true
                    }
                } else {
                    lyric.append(character)
                    hasLineContent = true
                }
                index = text.index(after: index)
            }
        }

        private mutating func flushLyricLineIfNeeded() {
            guard hasLineContent else { return }
            flushLyricLine(includingBlank: false)
        }

        private mutating func flushLyricLine(includingBlank: Bool) {
            if hasLineContent || includingBlank {
                blocks.append(.lyric(ChordProPreviewLine(lyric: lyric, chords: chords)))
            }
            lyric = ""
            chords = []
            hasLineContent = false
        }

        private static func previewBlock(forDirective source: String) -> ChordProPreviewBlock? {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{", trimmed.last == "}" else {
                return .directive(trimmed)
            }

            let body = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return .directive(trimmed) }
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = normalize(String(parts[0]))
            let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            switch key {
            case "title", "t":
                return value.isEmpty ? nil : .title(value)
            case "subtitle", "st":
                return value.isEmpty ? nil : .metadata(label: "Subtitle", value: value)
            case "artist":
                return value.isEmpty ? nil : .metadata(label: "Artist", value: value)
            case "key", "k":
                return value.isEmpty ? nil : .metadata(label: "Key", value: value)
            case "capo":
                return value.isEmpty ? nil : .metadata(label: "Capo", value: value)
            case "tempo", "metronome":
                return value.isEmpty ? nil : .metadata(label: "Tempo", value: value)
            case "comment", "c":
                return value.isEmpty ? nil : .comment(value)
            case "start_of_chorus", "soc":
                return .section(value.isEmpty ? "Chorus" : value)
            case "start_of_verse", "sov":
                return .section(value.isEmpty ? "Verse" : value)
            case "start_of_bridge", "sob":
                return .section(value.isEmpty ? "Bridge" : value)
            case "start_of_grid", "sog":
                return .section(value.isEmpty ? "Instrumental" : value)
            case "end_of_chorus", "eoc", "end_of_verse", "eov", "end_of_bridge", "eob",
                "end_of_grid", "eog":
                return nil
            default:
                return .directive(trimmed)
            }
        }

        private static func normalize(_ key: String) -> String {
            key.trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        }
    }
}
