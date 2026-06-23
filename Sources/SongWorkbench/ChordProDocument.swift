import Foundation

struct ChordProDocument: Equatable, Sendable {
    let elements: [ChordProElement]

    init(parsing source: String) throws {
        elements = try ChordProParser.parse(source)
    }

    private init(elements: [ChordProElement]) {
        self.elements = elements
    }

    func transposed(by semitones: Int) -> ChordProDocument {
        let interval = semitones % 12
        guard interval != 0 else { return self }

        return ChordProDocument(
            elements: elements.map { element in
                switch element {
                case .chord(let chord):
                    return .chord(chord.transposed(by: interval))
                case .directive(let source):
                    return .directive(Self.transposeKeyDirective(source, by: interval))
                case .text:
                    return element
                }
            })
    }

    func export() -> String {
        elements.map(\.sourceText).joined()
    }

    private static func transposeKeyDirective(_ source: String, by semitones: Int) -> String {
        let pattern = #"(?i)(\{\s*(?:key|k)\s*:\s*)([A-G](?:#|b)?)([^}]*)\}"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ),
            let noteRange = Range(match.range(at: 2), in: source),
            let note = ChordProNote.parse(source[noteRange])
        else { return source }

        let spelling: ChordProNote.Spelling
        if note.accidental == .flat {
            spelling = .flats
        } else if note.accidental == .sharp {
            spelling = .sharps
        } else {
            spelling = semitones < 0 ? .flats : .sharps
        }
        var result = source
        result.replaceSubrange(
            noteRange,
            with: note.transposed(by: semitones, spelling: spelling).description
        )
        return result
    }
}

enum ChordProElement: Equatable, Sendable {
    case text(String)
    case directive(String)
    case chord(ChordProChord)

    fileprivate var sourceText: String {
        switch self {
        case .text(let text), .directive(let text):
            return text
        case .chord(let chord):
            return "[\(chord.leadingWhitespace)\(chord.description)\(chord.trailingWhitespace)]"
        }
    }
}

struct ChordProChord: Equatable, Sendable, CustomStringConvertible {
    let root: ChordProNote
    let suffix: String
    let bass: ChordProNote?
    fileprivate let leadingWhitespace: String
    fileprivate let trailingWhitespace: String

    var description: String {
        var result = root.description + suffix
        if let bass {
            result += "/" + bass.description
        }
        return result
    }

    fileprivate func transposed(by semitones: Int) -> ChordProChord {
        let spelling = preferredSpelling(for: semitones)
        return ChordProChord(
            root: root.transposed(by: semitones, spelling: spelling),
            suffix: suffix,
            bass: bass?.transposed(by: semitones, spelling: spelling),
            leadingWhitespace: leadingWhitespace,
            trailingWhitespace: trailingWhitespace
        )
    }

    private func preferredSpelling(for semitones: Int) -> ChordProNote.Spelling {
        if root.accidental == .flat || bass?.accidental == .flat { return .flats }
        if root.accidental == .sharp || bass?.accidental == .sharp { return .sharps }
        return semitones < 0 ? .flats : .sharps
    }
}

struct ChordProNote: Equatable, Sendable, CustomStringConvertible {
    enum Accidental: String, Equatable, Sendable {
        case flat = "b"
        case sharp = "#"
    }

    fileprivate enum Spelling {
        case flats
        case sharps
    }

    let letter: Character
    let accidental: Accidental?

    var description: String {
        String(letter) + (accidental?.rawValue ?? "")
    }

    fileprivate func transposed(by semitones: Int, spelling: Spelling) -> ChordProNote {
        let pitchClass =
            Self.pitchClass(for: letter) + (accidental == .sharp ? 1 : 0)
            - (accidental == .flat ? 1 : 0)
        let transposedPitchClass = (pitchClass + semitones + 24) % 12
        let name = (spelling == .flats ? Self.flatNames : Self.sharpNames)[transposedPitchClass]
        return Self.parse(name[...])!
    }

    fileprivate static func parse(_ source: Substring) -> ChordProNote? {
        guard let first = source.first else { return nil }
        let normalizedLetter = Character(String(first).uppercased())
        guard "ABCDEFG".contains(normalizedLetter) else { return nil }

        let remainder = source.dropFirst()
        let accidental: Accidental?
        if remainder == "#" {
            accidental = .sharp
        } else if remainder == "b" {
            accidental = .flat
        } else if remainder.isEmpty {
            accidental = nil
        } else {
            return nil
        }
        return ChordProNote(letter: first, accidental: accidental)
    }

    private static func pitchClass(for letter: Character) -> Int {
        switch Character(String(letter).uppercased()) {
        case "C": 0
        case "D": 2
        case "E": 4
        case "F": 5
        case "G": 7
        case "A": 9
        case "B": 11
        default: preconditionFailure("ChordProNote validates note letters at initialization")
        }
    }

    private static let sharpNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]
    private static let flatNames = [
        "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B",
    ]
}

enum ChordProParseError: Error, Equatable, Sendable, LocalizedError {
    case unmatchedOpeningBracket(characterOffset: Int)
    case unmatchedClosingBracket(characterOffset: Int)
    case emptyChord(characterOffset: Int)
    case invalidChord(String, characterOffset: Int)

    var errorDescription: String? {
        switch self {
        case .unmatchedOpeningBracket(let offset):
            "Unmatched opening bracket at character \(offset)."
        case .unmatchedClosingBracket(let offset):
            "Unmatched closing bracket at character \(offset)."
        case .emptyChord(let offset):
            "Empty chord brackets at character \(offset)."
        case .invalidChord(let chord, let offset):
            "Invalid chord '\(chord)' at character \(offset); expected a root note from A through G."
        }
    }
}

private enum ChordProParser {
    static func parse(_ source: String) throws -> [ChordProElement] {
        var elements: [ChordProElement] = []
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let newline = source[lineStart...].firstIndex { character in
                character == "\n" || character == "\r\n" || character == "\r"
            }
            let lineEnd = newline.map { source.index(after: $0) } ?? source.endIndex
            let line = source[lineStart..<lineEnd]

            if isDirectiveLine(line) {
                elements.append(.directive(String(line)))
            } else {
                try parseLyricLine(line, in: source, into: &elements)
            }
            lineStart = lineEnd
        }

        return elements
    }

    private static func isDirectiveLine(_ line: Substring) -> Bool {
        let withoutLeadingWhitespace = line.drop(while: { $0.isWhitespace })
        let content = withoutLeadingWhitespace.reversed().drop(while: { $0.isWhitespace })
            .reversed()
        return content.first == "{" && content.last == "}"
    }

    private static func parseLyricLine(
        _ line: Substring,
        in source: String,
        into elements: inout [ChordProElement]
    ) throws {
        var textStart = line.startIndex
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "[" && !isEscaped(index, in: source) {
                if textStart < index {
                    appendText(String(source[textStart..<index]), to: &elements)
                }

                let contentStart = source.index(after: index)
                guard
                    let closingBracket = firstUnescapedClosingBracket(
                        from: contentStart, to: line.endIndex, in: source)
                else {
                    throw ChordProParseError.unmatchedOpeningBracket(
                        characterOffset: source.distance(from: source.startIndex, to: index))
                }
                let content = source[contentStart..<closingBracket]
                elements.append(.chord(try parseChord(content, openingBracket: index, in: source)))
                index = source.index(after: closingBracket)
                textStart = index
                continue
            }

            if character == "]" && !isEscaped(index, in: source) {
                throw ChordProParseError.unmatchedClosingBracket(
                    characterOffset: source.distance(from: source.startIndex, to: index))
            }
            index = source.index(after: index)
        }

        if textStart < line.endIndex {
            appendText(String(source[textStart..<line.endIndex]), to: &elements)
        }
    }

    private static func parseChord(
        _ content: Substring,
        openingBracket: String.Index,
        in source: String
    ) throws -> ChordProChord {
        let leading = content.prefix(while: { $0.isWhitespace })
        let afterLeading = content.dropFirst(leading.count)
        let trailing = afterLeading.reversed().prefix(while: { $0.isWhitespace }).reversed()
        let chordText = afterLeading.dropLast(trailing.count)
        let offset = source.distance(from: source.startIndex, to: openingBracket)

        guard !chordText.isEmpty else {
            throw ChordProParseError.emptyChord(characterOffset: offset)
        }

        let rootLength = chordText.dropFirst().first.map { $0 == "#" || $0 == "b" ? 2 : 1 } ?? 1
        let rootEnd =
            chordText.index(
                chordText.startIndex, offsetBy: rootLength, limitedBy: chordText.endIndex)
            ?? chordText.endIndex
        guard let root = ChordProNote.parse(chordText[..<rootEnd]) else {
            throw ChordProParseError.invalidChord(String(chordText), characterOffset: offset)
        }

        var suffix = chordText[rootEnd...]
        var bass: ChordProNote?
        if let slash = suffix.lastIndex(of: "/") {
            let candidate = suffix[suffix.index(after: slash)...]
            if let parsedBass = ChordProNote.parse(candidate) {
                bass = parsedBass
                suffix = suffix[..<slash]
            }
        }

        return ChordProChord(
            root: root,
            suffix: String(suffix),
            bass: bass,
            leadingWhitespace: String(leading),
            trailingWhitespace: String(trailing)
        )
    }

    private static func firstUnescapedClosingBracket(
        from start: String.Index,
        to end: String.Index,
        in source: String
    ) -> String.Index? {
        var index = start
        while index < end {
            if source[index] == "]" && !isEscaped(index, in: source) { return index }
            index = source.index(after: index)
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount % 2 == 1
    }

    private static func appendText(_ text: String, to elements: inout [ChordProElement]) {
        guard !text.isEmpty else { return }
        if case .text(let previous) = elements.last {
            elements[elements.count - 1] = .text(previous + text)
        } else {
            elements.append(.text(text))
        }
    }
}
