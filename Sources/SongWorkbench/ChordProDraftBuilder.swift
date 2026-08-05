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

enum UntranscribedVocalRegionResolver {
    static func overlaps(
        _ regions: [ClosedRange<TimeInterval>],
        start: TimeInterval,
        end: TimeInterval
    ) -> Bool {
        regions.contains { $0.lowerBound < end && start < $0.upperBound }
    }

    static func clippedMerged(
        _ regions: [ClosedRange<TimeInterval>],
        start: TimeInterval,
        end: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        let clipped = regions.compactMap { region -> ClosedRange<TimeInterval>? in
            let lower = max(start, region.lowerBound)
            let upper = min(end, region.upperBound)
            return lower < upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [ClosedRange<TimeInterval>] = []
        for region in clipped {
            if let last = merged.last, region.lowerBound <= last.upperBound + 0.02 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, region.upperBound)
            } else {
                merged.append(region)
            }
        }
        return merged
    }
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

    /// Monotonic version of this builder's OUTPUT SEMANTICS. Bump whenever a change alters what
    /// a correct chart looks like (row splitting, bar alignment, directive layout), so persisted
    /// charts built by an older algorithm are detected as stale and regenerated on load — even
    /// reviewed ones, since the artifact the review approved no longer exists (Eric: "version
    /// the analysis so the app can detect and discard an old analysis from a previous version
    /// of the algorithm").
    ///
    /// History: 1 = equal-time instrumental slicing (implicit — charts stamped before
    /// versioning carry no tag at all); 2 = uniform whole-bar instrumental rows.
    static let algorithmVersion = 2
    static var algorithmTag: String { "alg\(algorithmVersion)" }

    /// True when a persisted chart's provenance says it was built by a DIFFERENT algorithm
    /// version than this build of the app (or predates versioning entirely).
    static func isOutputStale(configurationIdentifier: String?) -> Bool {
        guard let configurationIdentifier else { return true }
        return !configurationIdentifier.hasPrefix("\(algorithmTag)-")
    }

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
        let sectionByStart: [TimeInterval: SongStructureAnalyzer.VocalSection] =
            vocalSections.count >= 2
            ? Dictionary(
                vocalSections.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        // Open ChordPro section directive (B4), closed either when the next section starts or at
        // the end of the lyric pass. Kept separate from the gap-based Intro/Instrumental comments
        // below: those use a different threshold (bars, not `SongStructureAnalyzer`'s seconds-based
        // `sectionGap`) and can legitimately fall INSIDE one continuous verse/chorus, so only a
        // genuine new `sectionByStart` entry may close/open a section — never the generic gap
        // comment, or a same-section instrumental breath would wrongly fragment the section.
        var openSection: SongStructureAnalyzer.SectionKind?
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
                let slice = Array(chords[start..<min(start + 8, chords.count)])
                lines.append(chordTimeDirective(for: slice))
                let row = slice.map(\.label).joined(separator: " | ")
                lines.append("| \(row) |")
            }
            lines.append("{end_of_grid}")
        }

        // Typical bars per sung line — used to break a long instrumental section into rows of a
        // familiar length instead of one very wide line that runs off the right edge.
        let typicalBars = typicalLyricBars(lyrics, input: input)
        // B2: bar-aligned chord-only rows reuse the SAME MeasureGrid/DownbeatEstimator machinery
        // the fixed-measure-grid preview work already built, so a chord-only row's bars line up
        // with the same downbeats the rest of the chart resolves to — not a separate spacing model.
        let measureGrid = self.measureGrid(for: input, chords: chords, lyrics: lyrics)

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
                let containsMissedVocals = UntranscribedVocalRegionResolver.overlaps(
                    input.untranscribedVocalRegions, start: gapStart, end: segment.start)
                let role =
                    containsMissedVocals
                    ? "Vocals not transcribed"
                    : (index == 0 ? "Intro" : "Instrumental")
                lines.append(
                    "{comment: \(directiveValue("\(role) · \(barCount(gapBars)) bars"))}")
                if !gapChords.isEmpty {
                    for row in instrumentalRows(
                        gapChords, start: gapStart, end: segment.start,
                        gapBars: gapBars, typicalBars: typicalBars, grid: measureGrid)
                    {
                        if !row.chords.isEmpty { lines.append(chordTimeDirective(for: row.chords)) }
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
            } else if index > 0 {
                // Anticipated changes: a gap chord CLOSER to this line's start than to the
                // previous line's end is the next phrase's chord arriving a hair early
                // (field case: Bb at 26.78s, 0.30s before "Laughter…" but 0.48s after the
                // previous line) — attach it to the START of this line, where a musician
                // expects it, instead of the previous line's tail.
                leadingChords = gapChords.filter { chord in
                    segment.start - chord.time < chord.time - gapStart
                }
                if segment.start - lyrics[index - 1].end > 1.5 {
                    lines.append("")
                }
            }
            var isSectionStart = index == 0 || gapBars >= 4
            if let section = sectionByStart[segment.start],
                !(tailCutoff.map {
                    TrailingLyricTailPruner.substantiveLineStart(segment) >= $0 - 0.02
                } ?? false)
            {
                if let openSection {
                    lines.append(sectionDirective(closing: openSection))
                }
                lines.append(sectionDirective(opening: section))
                openSection = section.kind
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
                    // Chords closer to the NEXT line's start are its anticipated changes —
                    // they render as that line's leading chords, not this line's tail.
                    trailingChords = chords.filter {
                        $0.time >= segment.end && $0.time < nextStart
                            && nextStart - $0.time >= $0.time - segment.end
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
            if !segmentChords.isEmpty { lines.append(chordTimeDirective(for: segmentChords)) }
            lines.append(render(segment: segment, chords: segmentChords))
            appendRow(
                kind: .lyric(ordinal: index),
                start: segment.start, end: segment.end,
                chordTimes: segmentChords.map(\.time))
        }
        // Close whatever section is still open once the lyric pass ends (before any outro).
        if let openSection {
            lines.append(sectionDirective(closing: openSection))
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
                    typicalBars: typicalBars, grid: measureGrid)
                {
                    if !row.chords.isEmpty { lines.append(chordTimeDirective(for: row.chords)) }
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

    /// B5: the `x_chord_times` round-trip carrier directive — one line, immediately preceding
    /// the rendered row/line it annotates, listing every chord event actually sounding there as
    /// an exact `time:label` pair (semicolon-separated; chord labels never contain `:` or `;`).
    /// This is the ONLY place an exact chord timestamp is written into the ChordPro TEXT itself —
    /// everywhere else (inline `[Chord]` markup, bar-aligned chord-only rows) a chord's position
    /// only ever encodes its time approximately (proportional character offset, or a bar/beat
    /// cell on the grid), and the app's real per-event timestamps live only in the separate
    /// in-memory `SongTimeline`/analysis cache. Embedding them here means a `.cho` file's exact
    /// chord timing survives being hand-edited, shared, or re-imported after that cache is gone
    /// or invalidated — see `ChordProChordTimeCarrier.parse(_:)` for the reader side.
    ///
    /// `x_` is the ChordPro convention for app-specific extensions other ChordPro tools should
    /// silently ignore: `ChordProParser` already stores any `{...}` line verbatim regardless of
    /// its key, and `ChordProPreviewDocument`'s directive dispatcher already falls back to an
    /// opaque, harmless `.directive` case for anything it doesn't specifically recognize — so
    /// this directive is safe to emit without touching either parser.
    private func chordTimeDirective(for events: [RenderableChordEvent]) -> String {
        let pairs =
            events
            .sorted { $0.time < $1.time }
            .map { "\(String(format: "%.3f", $0.time)):\($0.label)" }
            .joined(separator: ";")
        return "{x_chord_times: \(pairs)}"
    }

    private func directiveValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
    }

    /// Opening ChordPro section directive (B4). Verses carry their number as the directive's
    /// label argument (`{start_of_verse: Verse 2}`); choruses stay unlabeled/generic
    /// (`{start_of_chorus}`) — same "every chorus recurrence is just Chorus, no number"
    /// behavior `SongStructureAnalyzer` already had before this directive existed.
    private func sectionDirective(opening section: SongStructureAnalyzer.VocalSection) -> String {
        switch section.kind {
        case .verse: return "{start_of_verse: \(directiveValue(section.label))}"
        case .chorus: return "{start_of_chorus}"
        }
    }

    private func sectionDirective(closing kind: SongStructureAnalyzer.SectionKind) -> String {
        switch kind {
        case .verse: return "{end_of_verse}"
        case .chorus: return "{end_of_chorus}"
        }
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
        /// The real chord events actually rendered in this row (in time order), including any
        /// synthetic sustain restatement used to keep an empty slice non-blank — used to emit
        /// this row's `x_chord_times` round-trip directive (B5). Deliberately NOT the same thing
        /// as every `[chord]` token `chordOnlyLine`'s text contains: a bar that merely holds a
        /// chord across several bars re-prints that one symbol with no new timestamped event, so
        /// this list (unlike the rendered text) has exactly one entry per genuine chord-sounding
        /// fact, which is what a lossless round-trip needs.
        fileprivate let chords: [RenderableChordEvent]
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
        typicalBars: Double,
        grid: MeasureGrid?
    ) -> [InstrumentalRowLine] {
        // Rows of ~typicalBars, capped so a very long/sparse span (e.g. a padded outro) can't
        // explode into dozens of rows. The cap is generous because rows are now lyric-line
        // sized: a long outro should wrap into more short rows, not widen each row.
        let count = min(max(1, Int((gapBars / max(typicalBars, 1)).rounded())), 16)
        guard count > 1, end > start else {
            let sorted = chords.sorted { $0.time < $1.time }
            return [
                InstrumentalRowLine(
                    text: chordOnlyLine(chords, start: start, end: end, grid: grid),
                    start: start, end: end,
                    chordTimes: sorted.map(\.time),
                    chords: sorted)
            ]
        }
        // Row boundaries land on BAR DOWNBEATS, never at equal time slices. Equal slicing put
        // every boundary mid-bar (9 bars / 4 rows = 2.25 bars each), so each row began on a
        // different beat of its bar and the per-row downbeat anchoring rendered the section as
        // staircase indents — Eric's "uneven indents, cumulative errors". With whole-bar rows
        // every row starts ON a downbeat and left edges line up at the shared gutter column.
        // The first row keeps the section's real start (it may genuinely begin mid-bar); only
        // the SPLIT POINTS are quantized.
        var boundaries = barAlignedBoundaries(start: start, end: end, count: count, grid: grid)
        // The FIRST slice must contain the span's first chord: a chord-less leading row has
        // nothing to render and would be dropped downstream, breaking window contiguity
        // (rows must tile the gap for the ball/playhead walk). Merge leading boundaries into
        // the first row until it reaches the first chord; later rows stay downbeat-aligned.
        if let firstChordTime = chords.map(\.time).min() {
            while boundaries.count > 2, boundaries[1] <= firstChordTime {
                boundaries.remove(at: 1)
            }
        }
        var rows: [InstrumentalRowLine] = []
        var carried: RenderableChordEvent?
        for index in 0..<(boundaries.count - 1) {
            let sliceStart = boundaries[index]
            let sliceEnd = boundaries[index + 1]
            var sliceChords = chords.filter { $0.time >= sliceStart && $0.time < sliceEnd }
            if sliceChords.isEmpty, let carry = carried {
                sliceChords = [
                    RenderableChordEvent(
                        time: sliceStart, label: carry.label, confidence: carry.confidence)
                ]
            }
            carried = sliceChords.last ?? carried
            let sortedSliceChords = sliceChords.sorted { $0.time < $1.time }
            rows.append(
                InstrumentalRowLine(
                    text: chordOnlyLine(sliceChords, start: sliceStart, end: sliceEnd, grid: grid),
                    start: sliceStart, end: sliceEnd,
                    chordTimes: sortedSliceChords.map(\.time),
                    chords: sortedSliceChords))
        }
        return rows
    }

    /// Split points for an instrumental span: every interior boundary is a bar downbeat, and
    /// consecutive boundaries are EXACTLY the same whole number of bars apart — so musically
    /// equal rows are pixel-equal rows on the beat axis. (The first cut of this snapped
    /// equal-TIME targets to the nearest downbeat, which made a 9-bar span split 2/3/2/2 —
    /// bar-aligned but unequal, and Eric read it immediately: "Musically, I think all these
    /// lines are the same length - but vastly different on screen".) The first row absorbs a
    /// mid-bar section start; the last row takes the remainder bars. Falls back to plain equal
    /// slices without a grid. Internal (not private) for direct unit testing.
    func barAlignedBoundaries(
        start: TimeInterval, end: TimeInterval, count: Int, grid: MeasureGrid?
    ) -> [TimeInterval] {
        guard let grid else {
            let slice = (end - start) / Double(count)
            return (0..<count).map { start + Double($0) * slice } + [end]
        }
        let beatsPerBar = Double(grid.beatsPerBar)
        let totalBars =
            (grid.beatIndex(atTime: end) - grid.beatIndex(atTime: start)) / beatsPerBar
        let barsPerRow = max(1, Int((totalBars / Double(count)).rounded()))
        // Downbeat index of the bar CONTAINING the span start (floor, not nearest — the first
        // boundary must never land before the span).
        let startIndex = grid.beatIndex(atTime: start)
        let anchor =
            Int(((startIndex - Double(grid.barPhase)) / beatsPerBar).rounded(.down))
            * grid.beatsPerBar + grid.barPhase
        var result: [TimeInterval] = [start]
        var step = 1
        while result.count < 64 {
            let index = anchor + step * barsPerRow * grid.beatsPerBar
            let time = grid.time(atBeatIndex: Double(index))
            if time >= end - 0.001 { break }
            if time > start + 0.001 { result.append(time) }
            step += 1
        }
        result.append(end)
        return result
    }

    /// The whole-song measure grid used to bar-align chord-only rows (B2), built from the SAME
    /// beat/tempo data the fixed-measure-grid preview work already derives its grid from — no new
    /// spacing model. `beatsPerBar` is now estimated from the SAME lyric-line-onset signal the
    /// live preview uses (`DownbeatEstimator.estimateBeatsPerBar`, via `WorkspaceEditorsView`'s
    /// `beatsPerBar`), rather than hard-coded to 4 as it previously was: `lyrics` (already a
    /// parameter of this builder, e.g. `typicalLyricBars(lyrics, input:)` above) carries the same
    /// sung-line onsets the preview derives its own estimate from, so a non-4/4 song (a 5-beat
    /// verse phrasing, say) no longer renders/persists chord-only rows and barlines on a
    /// DIFFERENT bar grid than what the preview shows for the same song. Conservative by
    /// construction (`estimateBeatsPerBar` only deviates from 4 with a clear margin), so a normal
    /// 4/4 song is unaffected. Chord-change timing is still too irregular a proxy for phrase-period
    /// detection, so `barPhase` continues to use the chord onsets: chord changes cluster near
    /// downbeats in most pop/rock harmony, giving `DownbeatEstimator.barPhase` a legitimate (if
    /// weaker than vocal-onset) signal for which beat is beat 1. Falls back to synthesized uniform
    /// beats from `tempo` when no beat grid was detected, matching the
    /// `BouncingBall.beats(in:_:beatTimes:bpm:)` precedent elsewhere in this codebase. `nil` when
    /// neither beats nor a tempo are available (untimed songs keep the old proportional spacing).
    private func measureGrid(
        for input: ChordProDraftInput, chords: [RenderableChordEvent], lyrics: [TimedLyricSegment]
    ) -> MeasureGrid? {
        guard let bpm = input.tempo, bpm > 0 else { return nil }
        let onsets = chords.map(\.time)
        let beatTimes: [TimeInterval]
        if !input.beatTimes.isEmpty {
            beatTimes = input.beatTimes
        } else {
            // Synthesize a uniform grid spanning the song so bar math still works without
            // detected beats — same fallback `BouncingBall` uses for the ball's beat pulses.
            let end = resolvedSongDuration(input: input, fallback: (onsets.max() ?? 0) + 1)
            let beatLength = 60.0 / bpm
            guard beatLength > 0, end > 0 else { return nil }
            beatTimes = stride(from: 0.0, through: end, by: beatLength).map { $0 }
        }
        guard !beatTimes.isEmpty else { return nil }
        let lyricLineOnsets = lyrics.map { $0.words.first?.start ?? $0.start }
        let beatsPerBar = DownbeatEstimator.estimateBeatsPerBar(
            beatTimes: beatTimes, onsets: lyricLineOnsets)
        let barPhase = DownbeatEstimator.barPhase(
            beatTimes: beatTimes, onsets: onsets, beatsPerBar: beatsPerBar)
        let grid = MeasureGrid(
            beatTimes: beatTimes, bpm: bpm, beatsPerBar: beatsPerBar, barPhase: barPhase)
        return grid.isUsable ? grid : nil
    }

    /// A chord-only line (no lyric) for intro and instrumental-break chords, rendered as
    /// pipe-delimited bars on the song's shared `MeasureGrid` — e.g. `| C# | F# . | Ab | C# |`.
    /// Each `|...|` cell is one bar. A bar that holds a single chord for its whole duration (either
    /// newly stated there or simply sustained from an earlier bar) renders as just that one symbol
    /// — no dots, matching how a chart writes an unchanging chord straight through several bars
    /// (`| C# | C# |`, not `| C# | . |`). `.` only appears WITHIN a bar that has more than one
    /// chord change in it, marking the beat where a chord keeps holding after its own symbol already
    /// appeared earlier in that same bar. Chords are snapped to their nearest beat slot, so a chord
    /// that doesn't land exactly on the grid (e.g. a slightly early/late detected onset) still
    /// renders cleanly on the bar it musically belongs to instead of desyncing the columns.
    ///
    /// Falls back to the old proportional-space `[Chord]` layout when there's no usable grid (no
    /// tempo and no detected beats) — an untimed song has no bars to align to.
    private func chordOnlyLine(
        _ chords: [RenderableChordEvent],
        start: TimeInterval,
        end: TimeInterval,
        grid: MeasureGrid?
    ) -> String {
        guard !chords.isEmpty else { return "" }
        guard let grid, grid.isUsable else {
            return legacyChordOnlyLine(chords, start: start, end: end)
        }
        let sorted = chords.sorted {
            if $0.time == $1.time { return $0.label < $1.label }
            return $0.time < $1.time
        }

        let beatsPerBar = grid.beatsPerBar
        // The FIRST downbeat at or before `start` (floor to the enclosing bar — NOT the nearest
        // downbeat, which can round forward past a pickup) through the first downbeat at or after
        // the later of `end` / the last chord (so a trailing chord on the row's end boundary still
        // gets its own bar instead of being dropped).
        let lastChordTime = sorted.last!.time
        let startDownbeat = floorDownbeatIndex(grid: grid, atTime: start)
        let endBeatIndex = grid.beatIndex(atTime: max(end, lastChordTime))
        var endDownbeat = floorDownbeatIndex(grid: grid, beatIndex: endBeatIndex)
        if Double(endDownbeat) < endBeatIndex { endDownbeat += beatsPerBar }
        if endDownbeat <= startDownbeat { endDownbeat = startDownbeat + beatsPerBar }

        // Assign each chord to its nearest beat index (an off-grid onset still snaps onto the
        // bar/beat it musically belongs to rather than desyncing the columns). A fast passing run
        // (several chords within one beat slot, e.g. a chromatic walk-up) keeps EVERY label rather
        // than letting the last one silently overwrite the rest — they render together as adjacent
        // symbols in that one slot (chart order preserved), so no detected chord is ever dropped.
        var chordByBeat: [Int: [String]] = [:]
        for chord in sorted {
            let beat = Int(grid.beatIndex(atTime: chord.time).rounded())
            chordByBeat[beat, default: []].append(chord.label)
        }

        var bars: [String] = []
        // The chord sounding as of the start of the CURRENT bar being rendered — carried across
        // bars so a sustain shows the right symbol even in a bar with no chord change of its own.
        var activeLabel: String?
        var barBeat = startDownbeat
        while barBeat < endDownbeat {
            let beatsInBar = (0..<beatsPerBar).map { barBeat + $0 }
            // A bar holds ONE symbol, no dots, when the only chord sounding in it is already active
            // on (or before) the bar's downbeat and nothing else changes mid-bar — the common case
            // of a chord simply continuing through a bar. Dots only appear when a chord change
            // lands AFTER the downbeat (an off-beat-1 change), marking the beats it then holds
            // through for the rest of that bar.
            let changesAfterDownbeat = beatsInBar.dropFirst().filter { chordByBeat[$0] != nil }
            if changesAfterDownbeat.isEmpty {
                if let onDownbeat = chordByBeat[barBeat] {
                    activeLabel = onDownbeat.last
                    bars.append(onDownbeat.map { "[\($0)]" }.joined())
                } else if let activeLabel {
                    bars.append("[\(activeLabel)]")
                } else {
                    // No chord has sounded yet as of this bar (can happen at the START of a row
                    // split from a longer instrumental span — B2's row splitting is time-, not
                    // bar-, aligned, so a row's first bar can precede its first chord slightly).
                    // Still emit a placeholder bar rather than silently dropping it: the row's bar
                    // COUNT must stay truthful even when nothing is known to be sounding yet.
                    bars.append(".")
                }
            } else {
                // One or more changes after this bar's downbeat: show every change at its beat, and
                // "." for every other beat (before the first change, carrying whatever was already
                // active into the bar; after a change, marking the hold).
                if let onDownbeat = chordByBeat[barBeat]?.last { activeLabel = onDownbeat }
                var cells: [String] = []
                for beat in beatsInBar {
                    if let labels = chordByBeat[beat] {
                        cells.append(labels.map { "[\($0)]" }.joined())
                        activeLabel = labels.last
                    } else {
                        cells.append(".")
                    }
                }
                bars.append(cells.joined(separator: " "))
            }
            barBeat += beatsPerBar
        }
        guard !bars.isEmpty else { return "" }
        return "| " + bars.joined(separator: " | ") + " |"
    }

    /// The downbeat beat-index at or before a song time — a FLOOR to the bar containing `time`
    /// (unlike `MeasureGrid.nearestDownbeatIndex`, which rounds to the closest downbeat and can
    /// land AFTER `time` for a late-bar pickup). Bar-enumeration needs floor semantics so the row's
    /// first bar always contains its start time.
    private func floorDownbeatIndex(grid: MeasureGrid, atTime time: TimeInterval) -> Int {
        floorDownbeatIndex(grid: grid, beatIndex: grid.beatIndex(atTime: time))
    }

    private func floorDownbeatIndex(grid: MeasureGrid, beatIndex: Double) -> Int {
        let bars = (beatIndex - Double(grid.barPhase)) / Double(grid.beatsPerBar)
        return Int(bars.rounded(.down)) * grid.beatsPerBar + grid.barPhase
    }

    /// The pre-B2 proportional-time chord-only line, kept as the fallback for songs with no usable
    /// beat/tempo grid to bar-align to.
    ///
    /// The preview renders each chord at `column × characterWidth`, where `column`
    /// is the count of literal spaces preceding it. A chord label occupies
    /// `label.count` columns, so the gap to the next chord must clear the previous
    /// label plus at least one blank column — otherwise multi-character symbols
    /// (e.g. "C#", "D#") overlap the next chord and render as "C#A".
    private func legacyChordOnlyLine(
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

/// Reads back the `x_chord_times` directives `ChordProDraftBuilder.chordTimeDirective(for:)`
/// emits (B5), recovering each chord event's exact original `(time, label)` pair straight from
/// the `.cho` TEXT — no dependency on the app's separate analysis cache/`SongTimeline`. This is
/// the "carrier" round-tripping: a hand-edited or foreign-re-imported chart still carries
/// lossless chord timing even when that cache is missing or invalidated.
///
/// Deliberately just a parser, not wired into any import path: turning recovered entries back
/// into a live `SongTimeline`/chord-editing timeline is a separate, larger decision (would need
/// to reconcile with confidence thresholds, existing cached analysis, etc.) left for a future
/// backlog item if it's ever needed — this only proves the carrier itself is lossless.
enum ChordProChordTimeCarrier {
    struct Entry: Equatable {
        let time: TimeInterval
        let label: String
    }

    private static let prefix = "{x_chord_times:"

    /// Every `x_chord_times` entry found in `source`, in file order — which is chronological
    /// order, since the builder always emits rows top-to-bottom in time order.
    static func parse(_ source: String) -> [Entry] {
        var entries: [Entry] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("}") else { continue }
            let payload = trimmed.dropFirst(prefix.count).dropLast(1)
                .trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            for pair in payload.split(separator: ";") {
                let parts = pair.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let time = TimeInterval(parts[0]) else { continue }
                entries.append(Entry(time: time, label: String(parts[1])))
            }
        }
        return entries
    }
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
    /// A line at or below this SPOKEN word count (whitespace-separated tokens, e.g. "in a Key
    /// West bar" = 5) is a CANDIDATE tag/continuation line — short enough that its own
    /// standalone chorus/verse classification might just be an artifact of having too little
    /// vocabulary to compare, rather than genuinely different material. Being short alone is not
    /// enough to suppress a split (see `isProbableContinuation`, which additionally requires the
    /// combined text read as MORE self-sufficient than the line alone).
    var shortLineWordCountThreshold: Int = 5

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

        // Each block tracks its line RANGE (not just its start line) so the merge pass below can
        // measure line count — `boundaryWasGapOnly[k]` records whether the split BEFORE block
        // `k+1` was a bare `gap >= sectionGap` split with no classification-kind change either
        // side (as opposed to a genuine verse/chorus classification-mismatch split, which is
        // never eligible to be undone below).
        var blockBoundaries = [0]
        var boundaryWasGapOnly: [Bool] = []
        var blockStart = 0
        for i in 1..<lines.count {
            let gap = lines[i].start - lines[i - 1].end
            // A short trailing line just after a real (but sub-`sectionGap`) pause CAN read as a
            // continuation/tag of the previous line (a common call-and-response songwriting
            // pattern — e.g. "Yeah, I need a break … in a Key West bar") rather than genuinely
            // new material — but being short is not enough evidence on its own (plenty of
            // genuinely new, self-sufficient lines are also short, e.g. a 4-word bar-period
            // re-cut fragment of a new chorus). Only suppress the classification-mismatch split
            // when combining this line onto the PREVIOUS line's text reads as more sensible than
            // the line alone: the combined phrase must itself match some other line at least as
            // well as any standalone match this short line has (see `isProbableContinuation`).
            let isShortCandidate =
                gap < sectionGap && spokenWordCount(lines[i].text) <= shortLineWordCountThreshold
            let isProbableContinuation =
                isShortCandidate
                && isProbableContinuation(
                    line: lines[i], previousLine: lines[i - 1], allWords: words, allLines: lines)
            let classificationMismatch =
                !isProbableContinuation && isChorus[i] != isChorus[blockStart]
            if gap >= sectionGap || classificationMismatch {
                blockBoundaries.append(i)
                boundaryWasGapOnly.append(gap >= sectionGap && !classificationMismatch)
                blockStart = i
            } else if isProbableContinuation {
                // Continues the current block: adopt the block's classification so later lines
                // comparing against `isChorus[blockStart]` (and the final section's `kind`) see
                // one consistent block, rather than a short tag silently flipping mid-block.
                isChorus[i] = isChorus[blockStart]
            }
        }
        blockBoundaries.append(lines.count)

        let mergedRanges = mergedGapFragmentedVerseBlocks(
            blockBoundaries: blockBoundaries, boundaryWasGapOnly: boundaryWasGapOnly,
            isChorus: isChorus)

        var sections: [VocalSection] = mergedRanges.map { range in
            VocalSection(
                kind: isChorus[range.lowerBound] ? .chorus : .verse,
                start: lines[range.lowerBound].start,
                label: isChorus[range.lowerBound] ? "Chorus" : "Verse")
        }

        var verseNumber = 0
        for index in sections.indices where sections[index].kind == .verse {
            verseNumber += 1
            sections[index].label = "Verse \(verseNumber)"
        }
        return sections
    }

    /// Merges adjacent, same-kind, non-chorus blocks that were split ONLY by a bare
    /// `gap >= sectionGap` pause (never a genuine classification-mismatch split — that's real,
    /// independent evidence of a new section and is never undone here) when at least one side is
    /// anomalously short compared to the song's other verse-kind blocks — e.g. a Bridge whose
    /// mid-phrase breath happens to land a hair over `sectionGap`, fragmenting it into two
    /// short "Verse N" blocks instead of staying one section (Eric, field case, Settle Down
    /// 2026-07-07: two ~10s/2-3-line fragments between a real Chorus and the Instrumental, where
    /// every genuine verse in the song runs 20-50s / 6-9 lines). `reclassifyBridgeAndSolo`
    /// (`SongStructureOverviewBuilder`) then has a fair chance to relabel the merged block as a
    /// Bridge by chord-pattern mismatch — it never got that chance while split, since a lone
    /// 2-3 line fragment's own chord signature is too sparse to compare meaningfully.
    ///
    /// "Anomalously short" is measured against the OTHER verse-kind blocks already present in the
    /// song (line count STRICTLY less than half the longest verse-kind block) — never an
    /// absolute magic number, so this stays a no-op for songs with no long-verse baseline to
    /// compare against (mirrors `reclassifyBridgeAndSolo`'s own "needs >= 2 occurrences to have
    /// a template" conservatism). Also requires the longest verse-kind block to have at least
    /// `minimumBaselineLineCount` lines before the "half" comparison engages at all — a song
    /// whose verses are ALL naturally short (e.g. two single-line verses) has no reliable
    /// baseline to call either one an anomaly against, and merging them would be exactly the
    /// wrong call (regression guard: `testTwoOrdinaryEqualLengthVersesSeparatedByAGapStaySplit`-
    /// style two-line/one-line verse pairs must stay split).
    private func mergedGapFragmentedVerseBlocks(
        blockBoundaries: [Int], boundaryWasGapOnly: [Bool], isChorus: [Bool],
        minimumBaselineLineCount: Int = 4
    ) -> [Range<Int>] {
        let blockCount = blockBoundaries.count - 1
        guard blockCount > 1 else {
            return blockCount == 1 ? [blockBoundaries[0]..<blockBoundaries[1]] : []
        }
        let verseLineCounts = (0..<blockCount).compactMap { block -> Int? in
            let range = blockBoundaries[block]..<blockBoundaries[block + 1]
            return isChorus[range.lowerBound] ? nil : range.count
        }
        guard let longestVerse = verseLineCounts.max(), verseLineCounts.count >= 2,
            longestVerse >= minimumBaselineLineCount
        else {
            return (0..<blockCount).map { blockBoundaries[$0]..<blockBoundaries[$0 + 1] }
        }
        let shortThreshold = Double(longestVerse) / 2.0

        var merged: [Range<Int>] = [blockBoundaries[0]..<blockBoundaries[1]]
        for block in 1..<blockCount {
            let range = blockBoundaries[block]..<blockBoundaries[block + 1]
            let previousKind = isChorus[merged[merged.count - 1].lowerBound]
            let thisKind = isChorus[range.lowerBound]
            let eligibleBoundary = boundaryWasGapOnly[block - 1] && !previousKind && !thisKind
            let eitherSideAnomalouslyShort =
                Double(merged[merged.count - 1].count) < shortThreshold
                || Double(range.count) < shortThreshold
            if eligibleBoundary, eitherSideAnomalouslyShort {
                let previous = merged.removeLast()
                merged.append(previous.lowerBound..<range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The number of spoken words in a line — whitespace-separated tokens, NOT `wordSet`'s
    /// Jaccard tokens (which also splits on internal punctuation like apostrophes, so a
    /// contraction such as "There's" would otherwise count as two tokens instead of one word).
    private func spokenWordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.count
    }

    /// Whether `line` (a short trailing candidate) more plausibly completes `previousLine` than
    /// it stands as its own new phrase: true when appending `line`'s words onto `previousLine`'s
    /// reads as at least as strong a match to some OTHER line elsewhere (typically an earlier,
    /// unsplit occurrence of the same chorus) as any standalone match `line` has on its own. This
    /// is what actually distinguishes a genuine call-and-response tag — e.g. "Yeah I need a
    /// break" + "in a Key West bar" together matching the full chorus line elsewhere far better
    /// than "in a Key West bar" matches anything alone — from an ordinary short bar-period-cut
    /// fragment of a brand-new line (e.g. "There's a place with"), whose combination with an
    /// unrelated preceding line does NOT improve its match to anything.
    private func isProbableContinuation(
        line: TimedLyricSegment, previousLine: TimedLyricSegment, allWords: [Set<String>],
        allLines: [TimedLyricSegment]
    ) -> Bool {
        let lineWords = wordSet(line.text)
        let combinedWords = wordSet(previousLine.text).union(lineWords)
        var bestStandalone = 0.0
        var bestCombined = 0.0
        for (index, other) in allLines.enumerated() {
            guard other.start != previousLine.start || other.end != previousLine.end else {
                continue
            }
            guard other.start != line.start || other.end != line.end else { continue }
            let otherWords = allWords[index]
            bestStandalone = max(bestStandalone, jaccard(lineWords, otherWords))
            bestCombined = max(bestCombined, jaccard(combinedWords, otherWords))
        }
        return bestCombined >= chorusSimilarity && bestCombined > bestStandalone
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
        case untranscribedVocal
        case vocal(String)
    }

    let kind: Kind
    let start: TimeInterval
    let label: String

    var id: String { "\(kind)-\(start)-\(label)" }

    var isInstrumentalMarker: Bool {
        switch kind {
        case .intro, .instrumental, .outro: true
        case .untranscribedVocal, .vocal: false
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
        vocalTailCutoff: TimeInterval? = nil,
        untranscribedVocalRegions: [ClosedRange<TimeInterval>] = []
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
        @discardableResult
        func appendGapMarkers(
            from start: TimeInterval,
            to end: TimeInterval,
            instrumentalKind: LyricTimelineSection.Kind,
            instrumentalLabel: (Double) -> String
        ) -> Bool {
            let vocalRegions = UntranscribedVocalRegionResolver.clippedMerged(
                untranscribedVocalRegions, start: start, end: end)
            if vocalRegions.isEmpty {
                let gapBars = Self.bars(
                    from: start, to: end, beatTimes: beatTimes, tempo: tempo)
                if gapBars >= instrumentalGapBars {
                    markers.append(
                        LyricTimelineSection(
                            kind: instrumentalKind,
                            start: start,
                            label: instrumentalLabel(gapBars)))
                }
                return false
            }

            var cursor = start
            for region in vocalRegions {
                let precedingBars = Self.bars(
                    from: cursor, to: region.lowerBound, beatTimes: beatTimes, tempo: tempo)
                if precedingBars >= instrumentalGapBars {
                    markers.append(
                        LyricTimelineSection(
                            kind: instrumentalKind,
                            start: cursor,
                            label: instrumentalLabel(precedingBars)))
                }
                markers.append(
                    LyricTimelineSection(
                        kind: .untranscribedVocal,
                        start: region.lowerBound,
                        label: "Vocals not transcribed"))
                cursor = max(cursor, region.upperBound)
            }

            let trailingBars = Self.bars(
                from: cursor, to: end, beatTimes: beatTimes, tempo: tempo)
            if trailingBars >= instrumentalGapBars {
                markers.append(
                    LyricTimelineSection(
                        kind: instrumentalKind,
                        start: cursor,
                        label: instrumentalLabel(trailingBars)))
            }
            return true
        }
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
            let role = index == 0 ? "Intro" : "Instrumental"
            let containsUntranscribedVocals = appendGapMarkers(
                from: gapStart,
                to: segment.start,
                instrumentalKind: index == 0 ? .intro : .instrumental,
                instrumentalLabel: { "\(role) · \(Self.barCountLabel($0)) bars" })
            if !inTail, let sectionLabel = sectionLabelByStart[segment.start] {
                markers.append(
                    LyricTimelineSection(
                        kind: .vocal(sectionLabel), start: segment.start, label: sectionLabel))
            } else if !inTail, containsUntranscribedVocals {
                // Close the explicit missed-vocal span even when the next line remains inside the
                // same verse/chorus and therefore has no normal section boundary.
                markers.append(
                    LyricTimelineSection(
                        kind: .vocal("Vocals"), start: segment.start, label: "Vocals"))
            }
        }

        let lastBodyEnd = bodyLines.map(\.end).max() ?? lines.map(\.end).max()
        if let lastEnd = lastBodyEnd {
            let songEnd = resolvedSongEnd(
                lastLyricEnd: lastEnd, beatTimes: beatTimes, sourceDuration: sourceDuration)
            appendGapMarkers(
                from: lastEnd,
                to: songEnd,
                instrumentalKind: .outro,
                instrumentalLabel: { _ in "Outro" })
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
