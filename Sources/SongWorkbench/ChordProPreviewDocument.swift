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
        let sortedLyrics =
            lyricSegments
            .filter { !$0.text.isEmpty }
            .sorted {
                if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
        guard
            let lyricIndex = sortedLyrics.firstIndex(where: {
                currentTime >= $0.start && currentTime < $0.end
            })
        else {
            activeLyricOrdinal = nil
            lineHighlight = nil
            return
        }

        let lyric = sortedLyrics[lyricIndex]
        activeLyricOrdinal = lyricIndex
        lineHighlight = ChordProLinePlaybackHighlight(
            wordRange: Self.activeWordRange(in: lyric, at: currentTime),
            chordLabels: Self.activeChordLabels(
                at: currentTime,
                in: lyric,
                chordEvents: chordEvents,
                confidenceThreshold: confidenceThreshold,
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

    private static func activeWordRange(
        in lyric: TimedLyricSegment,
        at currentTime: TimeInterval
    ) -> Range<Int>? {
        let ranges = wordRanges(in: lyric.text)
        guard !ranges.isEmpty else { return nil }
        let duration = max(lyric.end - lyric.start, 0.001)
        let relative = min(max((currentTime - lyric.start) / duration, 0), 0.999_999)
        let index = min(Int(relative * Double(ranges.count)), ranges.count - 1)
        return ranges[index]
    }

    private static func activeChordLabels(
        at currentTime: TimeInterval,
        in lyric: TimedLyricSegment,
        chordEvents: [EditableChordEvent],
        confidenceThreshold: Float,
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
            return BassNoteChordProDraftBuilder.bassNoteLabel(from: active.chord).map { [$0] } ?? []
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
