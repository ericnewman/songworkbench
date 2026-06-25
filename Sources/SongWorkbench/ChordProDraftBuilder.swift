import Foundation

struct ChordProDraftInput: Equatable, Sendable {
    let title: String
    let tempo: Double?
    let lyrics: [TimedLyricSegment]
    let chords: [EditableChordEvent]
    var confidenceThreshold: Float = 0.5
    /// Detected beat times, used to measure instrumental gaps in bars (4/4).
    var beatTimes: [TimeInterval] = []
}

struct ChordProDraftBuilder: Sendable {
    /// Comment header used for the bass-note draft variant.
    static let bassNoteDraftComment = "Generated bass-note analysis draft - review required"

    func build(_ input: ChordProDraftInput) -> String {
        build(
            input,
            comment: "Generated analysis draft - review required",
            chordLabel: \.chord
        )
    }

    /// Renders a ChordPro draft, mapping each chord event to a label via
    /// `chordLabel` (return `nil` to omit an event). The bass-note draft passes
    /// `{ BassNote(chordSymbol: $0.chord)?.label }` and `bassNoteDraftComment`.
    func build(
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
        // Vocal section labels (Verse N / Chorus), keyed by each section's first-line start time.
        // Only label when there's real structure (≥2 sections) — a single-section clip needs none.
        let vocalSections = SongStructureAnalyzer().vocalSections(for: lyrics)
        let sectionLabelByStart =
            vocalSections.count >= 2
            ? Dictionary(
                vocalSections.map { ($0.start, $0.label) }, uniquingKeysWith: { first, _ in first })
            : [:]
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
            let gapStart = index > 0 ? lyrics[index - 1].end : 0
            let gapBars = bars(from: gapStart, to: segment.start, input: input)
            // Chords that play before this line (the intro before the first line,
            // or an instrumental break between lines) are not attached to any
            // lyric. Render them as a chord-only line so the chart starts on the
            // first chord and shows what to play during instrumental sections.
            let gapChords = chords.filter { $0.time >= gapStart && $0.time < segment.start }
            if gapBars >= 4 {
                if index > 0 { lines.append("") }
                let role = index == 0 ? "Intro" : "Instrumental"
                lines.append(
                    "{comment: \(directiveValue("\(role) · \(barCount(gapBars)) bars"))}")
                if !gapChords.isEmpty {
                    lines.append(chordOnlyLine(gapChords, start: gapStart, end: segment.start))
                }
            } else if !gapChords.isEmpty {
                lines.append(chordOnlyLine(gapChords, start: gapStart, end: segment.start))
            } else if index > 0, segment.start - lyrics[index - 1].end > 1.5 {
                lines.append("")
            }
            if let sectionLabel = sectionLabelByStart[segment.start] {
                lines.append("{comment: \(directiveValue(sectionLabel))}")
            }
            let segmentChords = chords.filter {
                $0.time >= segment.start && $0.time < segment.end
            }
            lines.append(render(segment: segment, chords: segmentChords))
        }

        // Trailing chords after the last lyric line (an outro) belong to no segment;
        // render them as a chord-only line so no detected chords are dropped.
        if let lastLyricEnd = lyrics.map(\.end).max() {
            let outroChords = chords.filter { $0.time >= lastLyricEnd }
            if !outroChords.isEmpty {
                lines.append("")
                lines.append("{comment: Outro}")
                let outroEnd = (outroChords.map(\.time).max() ?? lastLyricEnd) + 1
                lines.append(chordOnlyLine(outroChords, start: lastLyricEnd, end: outroEnd))
            }
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
            let offset: Int
            if let word = wordSounding(at: event.time, in: segment) {
                // Place the chord over the word actually being sung at its onset.
                offset = min(max(word.characterRange.lowerBound, 0), characters.count)
            } else {
                // No per-word timings: estimate the position proportionally by time.
                let relative = min(max((event.time - segment.start) / duration, 0), 1)
                let desired = Int((relative * Double(characters.count)).rounded())
                offset =
                    wordStarts.min {
                        let leftDistance = abs($0 - desired)
                        let rightDistance = abs($1 - desired)
                        return leftDistance == rightDistance
                            ? $0 < $1 : leftDistance < rightDistance
                    } ?? 0
            }
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

    /// The word being sung at `time` within the segment, from per-word timings — or `nil`
    /// when the segment carries no word-level timings (older analyses).
    private func wordSounding(at time: TimeInterval, in segment: TimedLyricSegment)
        -> TimedLyricWord?
    {
        guard !segment.words.isEmpty else { return nil }
        return segment.words.last(where: { $0.start <= time && time < $0.end })
            ?? segment.words.last(where: { $0.start <= time })
            ?? segment.words.first
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

    /// Length of the gap `[start, end)` in 4/4 bars: counts detected beats in the
    /// gap when available (most accurate), otherwise derives from `tempo`, else 0.
    private func bars(from start: TimeInterval, to end: TimeInterval, input: ChordProDraftInput)
        -> Double
    {
        guard end > start else { return 0 }
        let beats = input.beatTimes.filter { $0 > start && $0 < end }.count
        if beats > 0 { return Double(beats) / 4.0 }
        if let tempo = input.tempo, tempo > 0 {
            return (end - start) / (4.0 * 60.0 / tempo)
        }
        return 0
    }

    private func barCount(_ bars: Double) -> Int {
        max(4, Int(bars.rounded()))
    }

    /// A chord-only line (no lyric) for intro and instrumental-break chords.
    /// Spacing follows event timing so longer rests remain visible in the chart.
    ///
    /// The preview renders each chord at `column × characterWidth`, where `column`
    /// is the count of literal spaces preceding it. A chord label occupies
    /// `label.count` columns, so the gap to the next chord must clear the previous
    /// label plus at least one blank column — otherwise multi-character symbols
    /// (e.g. "C#", "D#") overlap the next chord and render as "C#A".
    private func chordOnlyLine(
        _ chords: [RenderableChordEvent],
        start: TimeInterval,
        end: TimeInterval
    ) -> String {
        guard !chords.isEmpty else { return "" }
        let sorted = chords.sorted {
            if $0.time == $1.time { return $0.label < $1.label }
            return $0.time < $1.time
        }
        guard sorted.count > 1 else { return "[\(sorted[0].label)]" }

        let duration = max(end - start, sorted.last!.time - start, 0.001)
        let columnsPerSecond = max(
            1.0,
            min(2.0, Double(max(1, Int(duration.rounded()))) / duration)
        )
        let minimumGap = 1
        var output = "[\(sorted[0].label)]"
        var previousTime = max(start, sorted[0].time)
        var previousLabel = sorted[0].label
        for chord in sorted.dropFirst() {
            let delta = max(0, chord.time - previousTime)
            let timedSpaces = Int((delta * columnsPerSecond).rounded())
            // Reserve the previous label's width so chords never visually collide,
            // while still honoring a wider rhythmic gap when the timing calls for it.
            let spaces = max(previousLabel.count + minimumGap, timedSpaces)
            output += String(repeating: " ", count: spaces)
            output += "[\(chord.label)]"
            previousTime = chord.time
            previousLabel = chord.label
        }

        return output
    }
}

private struct RenderableChordEvent: Equatable {
    let time: TimeInterval
    let label: String
    let confidence: Float?
}

/// Infers a song's vocal section structure (verses and choruses) from its lyric lines, using the
/// standard-pop heuristic that choruses recur near-verbatim. A line is part of a CHORUS when its
/// words closely match another line elsewhere in the song; runs of same-type lines (split also at
/// large instrumental gaps) become sections, with verses numbered in order. Intro / instrumental /
/// outro labels are left to the ChordPro builder's gap handling; this names the sung sections.
struct SongStructureAnalyzer: Sendable {
    /// Word-set Jaccard at or above which two lines are "the same" line (i.e. a repeated chorus).
    var chorusSimilarity: Double = 0.7
    /// A gap (seconds) between consecutive lyric lines at/above which a new section starts.
    var sectionGap: TimeInterval = 4

    enum SectionKind: Equatable, Sendable {
        case verse
        case chorus
    }

    struct VocalSection: Equatable, Sendable {
        var kind: SectionKind
        var start: TimeInterval
        var label: String
    }

    func vocalSections(for lyrics: [TimedLyricSegment]) -> [VocalSection] {
        let lines = lyrics.filter { !wordSet($0.text).isEmpty }.sorted { $0.start < $1.start }
        guard !lines.isEmpty else { return [] }

        let words = lines.map { wordSet($0.text) }
        var isChorus = [Bool](repeating: false, count: lines.count)
        for i in lines.indices {
            for j in lines.indices where i != j {
                if jaccard(words[i], words[j]) >= chorusSimilarity {
                    isChorus[i] = true
                    break
                }
            }
        }

        var sections: [VocalSection] = []
        var blockStart = 0
        func flush(_ start: Int) {
            sections.append(
                VocalSection(
                    kind: isChorus[start] ? .chorus : .verse,
                    start: lines[start].start,
                    label: isChorus[start] ? "Chorus" : "Verse"))
        }
        for i in 1..<lines.count {
            let gap = lines[i].start - lines[i - 1].end
            if gap >= sectionGap || isChorus[i] != isChorus[blockStart] {
                flush(blockStart)
                blockStart = i
            }
        }
        flush(blockStart)

        var verseNumber = 0
        for index in sections.indices where sections[index].kind == .verse {
            verseNumber += 1
            sections[index].label = "Verse \(verseNumber)"
        }
        return sections
    }

    private func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
