import Foundation

struct ChordProDraftInput: Equatable, Sendable {
    let title: String
    let tempo: Double?
    let lyrics: [TimedLyricSegment]
    let chords: [EditableChordEvent]
    var confidenceThreshold: Float = 0.5
    /// Detected beat times, used to measure instrumental gaps in bars (4/4).
    var beatTimes: [TimeInterval] = []
    /// Full audio duration so intro/outro chord-only lines span the entire song timeline.
    var sourceDuration: TimeInterval? = nil
    /// Sung-but-untranscribed spans (audit RC-4); rows overlapping these are flagged on the
    /// timeline so consumers don't present them as purely instrumental.
    var untranscribedVocalRegions: [ClosedRange<TimeInterval>] = []
    /// Detected key, emitted as a `{key: …}` directive (reconstruction plan B1).
    var estimatedKey: MusicalKey? = nil
}

/// The generated draft plus its typed timeline — same build pass, so `timeline.rows[i].number`
/// matches the preview's numbered musical lines of `source` exactly.
struct ChordProDraftResult: Equatable, Sendable {
    let source: String
    let timeline: SongTimeline
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
        buildResult(input, comment: comment, chordLabel: chordLabel).source
    }

    /// The standard draft plus its `SongTimeline` (see `ChordProDraftResult`).
    func buildResult(_ input: ChordProDraftInput) -> ChordProDraftResult {
        buildResult(
            input,
            comment: "Generated analysis draft - review required",
            chordLabel: \.chord
        )
    }

    func buildResult(
        _ input: ChordProDraftInput,
        comment: String,
        chordLabel: @Sendable (EditableChordEvent) -> String?
    ) -> ChordProDraftResult {
        // Timeline rows are collected IN the same pass that emits text lines, so row numbers
        // can never drift from the preview's numbered musical lines (audit RC-2).
        var rows: [SongTimeline.Row] = []
        func appendRow(
            kind: SongTimeline.Row.Kind,
            start: TimeInterval,
            end: TimeInterval,
            chordTimes: [TimeInterval]
        ) {
            let window = start...max(end, start)
            let sung = input.untranscribedVocalRegions.contains {
                $0.lowerBound < window.upperBound && window.lowerBound < $0.upperBound
            }
            rows.append(
                SongTimeline.Row(
                    number: rows.count + 1,
                    kind: kind,
                    start: start,
                    end: max(end, start + 0.01),
                    chordTimes: chordTimes,
                    containsUntranscribedVocals: sung
                ))
        }

        var lines = [
            "{title: \(directiveValue(input.title))}"
        ]
        if let tempo = input.tempo {
            lines.append("{tempo: \(formattedTempo(tempo))}")
        }
        // Reconstruction plan B1: name the key and meter so the chart is self-contained.
        // The whole chart's bar math is 4/4 (see `bars(from:to:)`), so {time} states it.
        if let key = input.estimatedKey {
            lines.append("{key: \(directiveValue(key.displayName))}")
        }
        if input.tempo != nil || !input.beatTimes.isEmpty {
            lines.append("{time: 4/4}")
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
        // Exclude instrumental-tail hallucinations from structure inference.
        let tailCutoff = TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail(
            lyrics,
            sourceDuration: input.sourceDuration)
        let bodyLyrics = lyrics.filter { line in
            guard let cutoff = tailCutoff else { return true }
            return TrailingLyricTailPruner.substantiveLineStart(line) < cutoff - 0.02
        }
        let vocalSections = SongStructureAnalyzer().vocalSections(for: bodyLyrics)
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

        // Typical bars per sung line — used to break a long instrumental section into rows of a
        // familiar length instead of one very wide line that runs off the right edge.
        let typicalBars = typicalLyricBars(lyrics, input: input)

        for (index, segment) in lyrics.enumerated() {
            let gapStart = index > 0 ? lyrics[index - 1].end : 0
            let gapBars = bars(from: gapStart, to: segment.start, input: input)
            // Chords that play before this line (the intro before the first line,
            // or an instrumental break between lines) are not attached to any
            // lyric. Render them as a chord-only line so the chart starts on the
            // first chord and shows what to play during instrumental sections.
            let gapChords = chords.filter { $0.time >= gapStart && $0.time < segment.start }
            // A gap only becomes its own instrumental line when it spans a real section
            // (≥ 4 bars, the same threshold that names Intro/Instrumental breaks). Shorter
            // gaps are brief musical intervals between sung lines, NOT separate lines: their
            // passing chords are folded into an adjacent sung line (below) instead of being
            // rendered on a line of their own.
            var leadingChords: [RenderableChordEvent] = []
            if gapBars >= 4 {
                if index > 0 { lines.append("") }
                let role = index == 0 ? "Intro" : "Instrumental"
                lines.append(
                    "{comment: \(directiveValue("\(role) · \(barCount(gapBars)) bars"))}")
                if !gapChords.isEmpty {
                    for row in instrumentalRows(
                        gapChords, start: gapStart, end: segment.start,
                        gapBars: gapBars, typicalBars: typicalBars)
                    {
                        lines.append(row.text)
                        if !row.text.isEmpty {
                            appendRow(
                                kind: .instrumental(role: index == 0 ? .intro : .interlude),
                                start: row.start, end: row.end,
                                chordTimes: row.chordTimes)
                        }
                    }
                }
            } else if index == 0, !gapChords.isEmpty {
                // A short intro has no previous line to carry its chords, so fold them into
                // the first sung line rather than emitting a standalone chord-only line.
                leadingChords = gapChords
            } else if index > 0, segment.start - lyrics[index - 1].end > 1.5 {
                lines.append("")
            }
            var isSectionStart = index == 0 || gapBars >= 4
            if let sectionLabel = sectionLabelByStart[segment.start],
                !(tailCutoff.map {
                    TrailingLyricTailPruner.substantiveLineStart(segment) >= $0 - 0.02
                } ?? false)
            {
                lines.append("{comment: \(directiveValue(sectionLabel))}")
                isSectionStart = true
            }
            let ownChords = chords.filter {
                $0.time >= segment.start && $0.time < segment.end
            }
            // Attach a brief instrumental breath AFTER this line (a short < 4-bar gap before
            // the next sung line) to the END of this line, so the short interval reads as the
            // tail of this line rather than a separate chord-only line. Longer gaps are handled
            // as an Instrumental section on the next iteration.
            var trailingChords: [RenderableChordEvent] = []
            if index + 1 < lyrics.count {
                let nextStart = lyrics[index + 1].start
                if bars(from: segment.end, to: nextStart, input: input) < 4 {
                    trailingChords = chords.filter {
                        $0.time >= segment.end && $0.time < nextStart
                    }
                }
            }
            var segmentChords = leadingChords + ownChords + trailingChords
            // Restate the active (sustained) chord at the start of each section: a chord that
            // last changed during an earlier line or instrumental block would otherwise never
            // appear in this section at all (the chart only marks changes), leaving e.g. a whole
            // verse with no chord symbol. Standard chart practice is to name the current chord
            // at every section start.
            if isSectionStart,
                segmentChords.first.map({ $0.time > segment.start + 0.5 }) ?? true,
                let active = chords.last(where: { $0.time < segment.start })
            {
                segmentChords.insert(
                    RenderableChordEvent(
                        time: segment.start, label: active.label, confidence: active.confidence),
                    at: 0)
            }
            lines.append(render(segment: segment, chords: segmentChords))
            appendRow(
                kind: .lyric(ordinal: index),
                start: segment.start, end: segment.end,
                chordTimes: segmentChords.map(\.time))
        }

        // Trailing chords after the last lyric line (an outro) belong to no segment;
        // render them as a chord-only line so no detected chords are dropped.
        let lastBodyEnd = bodyLyrics.map(\.end).max() ?? lyrics.map(\.end).max()
        if let lastLyricEnd = lastBodyEnd {
            let outroChords = chords.filter { $0.time >= lastLyricEnd }
            if !outroChords.isEmpty {
                lines.append("")
                lines.append("{comment: Outro}")
                let fallbackEnd = (outroChords.map(\.time).max() ?? lastLyricEnd) + 1
                let songEnd = resolvedSongDuration(input: input, fallback: fallbackEnd)
                for row in instrumentalRows(
                    outroChords, start: lastLyricEnd, end: songEnd,
                    gapBars: bars(from: lastLyricEnd, to: songEnd, input: input),
                    typicalBars: typicalBars)
                {
                    lines.append(row.text)
                    if !row.text.isEmpty {
                        appendRow(
                            kind: .instrumental(role: .outro),
                            start: row.start, end: row.end,
                            chordTimes: row.chordTimes)
                    }
                }
            }
        }
        return ChordProDraftResult(
            source: lines.joined(separator: "\n") + "\n",
            timeline: SongTimeline(rows: rows)
        )
    }

    /// The full song duration for timeline bounds: prefer the transcribed audio length, else beats,
    /// else the caller's fallback (typically last chord + 1).
    private func resolvedSongDuration(input: ChordProDraftInput, fallback: TimeInterval)
        -> TimeInterval
    {
        if let source = input.sourceDuration, source > 0 { return source }
        if let lastBeat = input.beatTimes.max(), lastBeat > fallback { return lastBeat }
        return fallback
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
        // A chord that sounds AFTER the last sung word (a trailing chord folded into this
        // line's tail) belongs past the end of the text, not stacked over the final word —
        // in the audio it lands a beat or two to the right of the word.
        let lastWordEnd = segment.words.last?.end
        for event in chords {
            let offset: Int
            if let lastWordEnd, event.time >= lastWordEnd - 0.02 {
                offset = characters.count
            } else if let word = wordSounding(at: event.time, in: segment) {
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

    private func bars(from start: TimeInterval, to end: TimeInterval, input: ChordProDraftInput)
        -> Double
    {
        LyricSectionDeriver.bars(
            from: start, to: end, beatTimes: input.beatTimes, tempo: input.tempo)
    }

    private func barCount(_ bars: Double) -> Int {
        LyricSectionDeriver.barCountLabel(bars)
    }

    /// The typical length of a sung line, in 4/4 bars — the median over the lyric lines, clamped to
    /// a sensible 2…8. Used to break long instrumental sections into rows of a familiar length.
    private func typicalLyricBars(_ lyrics: [TimedLyricSegment], input: ChordProDraftInput)
        -> Double
    {
        let perLine =
            lyrics
            .map { bars(from: $0.start, to: $0.end, input: input) }
            .filter { $0 > 0 }
            .sorted()
        guard !perLine.isEmpty else { return 4 }
        let median = perLine[perLine.count / 2]
        // Match the sung lines: instrumental rows split to roughly the SAME number of bars as a
        // typical lyric line, so time-scaled intro/outro rows render about as wide as the verse
        // rows around them (floor 2 bars keeps rows from getting silly-narrow). A 4-bar floor
        // previously made intro rows ~2× wider than short-phrased songs' lyric rows.
        return min(max(median, 2), 8)
    }

    /// One rendered chord-only row of an instrumental span, WITH its authoritative time window
    /// (kept for the `SongTimeline` so the ball/preview never have to re-guess it — audit RC-2).
    struct InstrumentalRowLine: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let chordTimes: [TimeInterval]
    }

    /// Renders an instrumental span as one or more chord-only lines: a span longer than
    /// `typicalBars` is split into that many rows so a long intro/outro/break wraps down the page
    /// instead of running off the right edge. Each row carries the chords in its time slice (an
    /// otherwise empty slice sustains the previous chord so no row is blank). The preview divides the
    /// same span into equal windows per row, so widths/waveforms line up with this split.
    private func instrumentalRows(
        _ chords: [RenderableChordEvent],
        start: TimeInterval,
        end: TimeInterval,
        gapBars: Double,
        typicalBars: Double
    ) -> [InstrumentalRowLine] {
        // Rows of ~typicalBars, capped so a very long/sparse span (e.g. a padded outro) can't
        // explode into dozens of rows. The cap is generous because rows are now lyric-line
        // sized: a long outro should wrap into more short rows, not widen each row.
        let count = min(max(1, Int((gapBars / max(typicalBars, 1)).rounded())), 16)
        guard count > 1, end > start else {
            return [
                InstrumentalRowLine(
                    text: chordOnlyLine(chords, start: start, end: end),
                    start: start, end: end,
                    chordTimes: chords.map(\.time).sorted())
            ]
        }
        let slice = (end - start) / Double(count)
        var rows: [InstrumentalRowLine] = []
        var carried: RenderableChordEvent?
        for index in 0..<count {
            let sliceStart = start + Double(index) * slice
            let sliceEnd = index == count - 1 ? end : start + Double(index + 1) * slice
            var sliceChords = chords.filter { $0.time >= sliceStart && $0.time < sliceEnd }
            if sliceChords.isEmpty, let carry = carried {
                sliceChords = [
                    RenderableChordEvent(
                        time: sliceStart, label: carry.label, confidence: carry.confidence)
                ]
            }
            carried = sliceChords.last ?? carried
            rows.append(
                InstrumentalRowLine(
                    text: chordOnlyLine(sliceChords, start: sliceStart, end: sliceEnd),
                    start: sliceStart, end: sliceEnd,
                    chordTimes: sliceChords.map(\.time).sorted()))
        }
        return rows
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

/// Timeline section markers for the Lyrics view and ChordPro draft (intro, instrumental breaks,
/// outro, and inferred verse/chorus labels). Derived from lyric gaps, beats, and song duration.
struct LyricTimelineSection: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case intro
        case instrumental
        case outro
        case vocal(String)
    }

    let kind: Kind
    let start: TimeInterval
    let label: String

    var id: String { "\(kind)-\(start)-\(label)" }

    var isInstrumentalMarker: Bool {
        switch kind {
        case .intro, .instrumental, .outro: true
        case .vocal: false
        }
    }
}

struct LyricSectionDeriver: Sendable {
    /// Minimum instrumental gap length (in 4/4 bars) before emitting Intro/Instrumental/Outro.
    var instrumentalGapBars: Double = 4
    var lineStartEpsilon: TimeInterval = 0.02
    var minTrailingInstrumental: TimeInterval = 3.0

    func sections(
        lyrics: [TimedLyricSegment],
        beatTimes: [TimeInterval] = [],
        tempo: Double? = nil,
        sourceDuration: TimeInterval? = nil,
        vocalTailCutoff: TimeInterval? = nil
    ) -> [LyricTimelineSection] {
        let lines =
            lyrics
            .filter { $0.text.contains(where: { !$0.isWhitespace }) }
            .sorted {
                if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
        guard !lines.isEmpty else { return [] }

        let tailCutoff =
            vocalTailCutoff
            ?? TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail(
                lines,
                sourceDuration: sourceDuration,
                lineStartEpsilon: lineStartEpsilon,
                minTrailingInstrumental: minTrailingInstrumental)
        let bodyLines = lines.filter { line in
            guard let cutoff = tailCutoff else { return true }
            return TrailingLyricTailPruner.substantiveLineStart(line) < cutoff - lineStartEpsilon
        }

        var markers: [LyricTimelineSection] = []
        let vocalSections = SongStructureAnalyzer().vocalSections(for: bodyLines)
        let sectionLabelByStart =
            vocalSections.count >= 2
            ? Dictionary(
                vocalSections.map { ($0.start, $0.label) }, uniquingKeysWith: { first, _ in first })
            : [:]

        for (index, segment) in lines.enumerated() {
            let inTail =
                tailCutoff.map {
                    TrailingLyricTailPruner.substantiveLineStart(segment) >= $0 - lineStartEpsilon
                } ?? false
            let gapStart = index > 0 ? lines[index - 1].end : 0
            let gapBars = Self.bars(
                from: gapStart, to: segment.start, beatTimes: beatTimes, tempo: tempo)
            if gapBars >= instrumentalGapBars {
                let role = index == 0 ? "Intro" : "Instrumental"
                let barLabel = Self.barCountLabel(gapBars)
                markers.append(
                    LyricTimelineSection(
                        kind: index == 0 ? .intro : .instrumental,
                        start: gapStart,
                        label: "\(role) · \(barLabel) bars"))
            }
            if !inTail, let sectionLabel = sectionLabelByStart[segment.start] {
                markers.append(
                    LyricTimelineSection(
                        kind: .vocal(sectionLabel), start: segment.start, label: sectionLabel))
            }
        }

        let lastBodyEnd = bodyLines.map(\.end).max() ?? lines.map(\.end).max()
        if let lastEnd = lastBodyEnd {
            let songEnd = resolvedSongEnd(
                lastLyricEnd: lastEnd, beatTimes: beatTimes, sourceDuration: sourceDuration)
            let outroBars = Self.bars(
                from: lastEnd, to: songEnd, beatTimes: beatTimes, tempo: tempo)
            if outroBars >= instrumentalGapBars {
                markers.append(
                    LyricTimelineSection(kind: .outro, start: lastEnd, label: "Outro"))
            }
        }
        return markers.sorted {
            if $0.start == $1.start { return $0.label < $1.label }
            return $0.start < $1.start
        }
    }

    /// Length of the gap `[start, end)` in 4/4 bars.
    static func bars(
        from start: TimeInterval,
        to end: TimeInterval,
        beatTimes: [TimeInterval],
        tempo: Double?
    ) -> Double {
        guard end > start else { return 0 }
        let beats = beatTimes.filter { $0 > start && $0 < end }.count
        if beats > 0 { return Double(beats) / 4.0 }
        if let tempo, tempo > 0 {
            return (end - start) / (4.0 * 60.0 / tempo)
        }
        return 0
    }

    static func barCountLabel(_ bars: Double) -> Int {
        max(4, Int(bars.rounded()))
    }

    private func resolvedSongEnd(
        lastLyricEnd: TimeInterval,
        beatTimes: [TimeInterval],
        sourceDuration: TimeInterval?
    ) -> TimeInterval {
        if let sourceDuration, sourceDuration > lastLyricEnd { return sourceDuration }
        if let lastBeat = beatTimes.max(), lastBeat > lastLyricEnd { return lastBeat }
        return lastLyricEnd + 8
    }
}
