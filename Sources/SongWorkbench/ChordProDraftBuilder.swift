import Foundation

struct ChordProDraftInput: Equatable, Sendable {
    let title: String
    let tempo: Double?
    let lyrics: [TimedLyricSegment]
    let chords: [EditableChordEvent]
    var confidenceThreshold: Float = 0.5
}

struct ChordProDraftBuilder: Sendable {
    func build(_ input: ChordProDraftInput) -> String {
        build(
            input,
            comment: "Generated analysis draft - review required",
            chordLabel: \.chord
        )
    }

    fileprivate func build(
        _ input: ChordProDraftInput,
        comment: String,
        chordLabel: @Sendable (EditableChordEvent) -> String?
    ) -> String {
        var lines = [
            "{title: \(directiveValue(input.title))}"
        ]
        if let tempo = input.tempo {
            lines.append("{tempo: \(formattedTempo(tempo))}")
        }
        lines.append("{comment: \(directiveValue(comment))}")
        lines.append("")

        let lyrics = input.lyrics.sorted {
            if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        let chords = input.chords.compactMap { event -> RenderableChordEvent? in
            guard event.confidence.map({ $0 >= input.confidenceThreshold }) ?? true else {
                return nil
            }
            guard let label = chordLabel(event), !label.isEmpty else { return nil }
            return RenderableChordEvent(
                time: event.time,
                label: label,
                confidence: event.confidence
            )
        }.sorted {
            if $0.time == $1.time, $0.label == $1.label {
                return ($0.confidence ?? 1) > ($1.confidence ?? 1)
            }
            if $0.time == $1.time { return $0.label < $1.label }
            return $0.time < $1.time
        }

        if lyrics.isEmpty, !chords.isEmpty {
            lines.append("{start_of_grid}")
            for start in stride(from: 0, to: chords.count, by: 8) {
                let row = chords[start..<min(start + 8, chords.count)]
                    .map(\.label)
                    .joined(separator: " | ")
                lines.append("| \(row) |")
            }
            lines.append("{end_of_grid}")
        }

        for (index, segment) in lyrics.enumerated() {
            if index > 0, segment.start - lyrics[index - 1].end > 1.5 {
                lines.append("")
            }
            let segmentChords = chords.filter {
                $0.time >= segment.start && $0.time < segment.end
            }
            lines.append(render(segment: segment, chords: segmentChords))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func render(
        segment: TimedLyricSegment,
        chords: [RenderableChordEvent]
    ) -> String {
        guard !segment.text.isEmpty, !chords.isEmpty else { return segment.text }
        let characters = Array(segment.text)
        let wordStarts = wordStartOffsets(in: characters)
        let duration = max(segment.end - segment.start, 0.001)
        var chordsByOffset: [Int: [String]] = [:]
        for event in chords {
            let relative = min(max((event.time - segment.start) / duration, 0), 1)
            let desired = Int((relative * Double(characters.count)).rounded())
            let offset =
                wordStarts.min {
                    let leftDistance = abs($0 - desired)
                    let rightDistance = abs($1 - desired)
                    return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
                } ?? 0
            chordsByOffset[offset, default: []].append(event.label)
        }

        var output = ""
        for offset in 0...characters.count {
            for chord in chordsByOffset[offset] ?? [] {
                output += "[\(chord)]"
            }
            if offset < characters.count {
                output.append(characters[offset])
            }
        }
        return output
    }

    private func wordStartOffsets(in characters: [Character]) -> [Int] {
        guard !characters.isEmpty else { return [0] }
        var offsets = [0]
        for index in 1..<characters.count
        where characters[index - 1].isWhitespace && !characters[index].isWhitespace {
            offsets.append(index)
        }
        return offsets
    }

    private func directiveValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
    }

    private func formattedTempo(_ tempo: Double) -> String {
        tempo.rounded() == tempo ? String(Int(tempo)) : String(format: "%.1f", tempo)
    }
}

struct BassNoteChordProDraftBuilder: Sendable {
    func build(_ input: ChordProDraftInput) -> String {
        ChordProDraftBuilder().build(
            input,
            comment: "Generated bass-note analysis draft - review required"
        ) { event in
            Self.bassNoteLabel(from: event.chord)
        }
    }

    static func bassNoteLabel(from chord: String) -> String? {
        let trimmed = chord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        if components.count == 2, let bass = parseNote(components[1]) {
            return bass
        }
        return parseNote(components[0])
    }

    private static func parseNote(_ source: Substring) -> String? {
        guard let first = source.first else { return nil }
        let letter = String(first).uppercased()
        guard ["A", "B", "C", "D", "E", "F", "G"].contains(letter) else { return nil }
        let remainder = source.dropFirst()
        if remainder.first == "#" || remainder.first == "b" {
            return letter + String(remainder.first!)
        }
        return letter
    }
}

private struct RenderableChordEvent: Equatable {
    let time: TimeInterval
    let label: String
    let confidence: Float?
}
