import Foundation

/// The fixed-period row windows a chart is cut on (`tasks/spec-fixed-period-rows.md`): every row
/// spans exactly `periodBeats` measured beats, starting on a bar downbeat, so every row renders at
/// the same width on the shared beat ruler.
///
/// Windows are cut in BEAT-INDEX space through `MeasureGrid`, never on a rigid 60/bpm clock: a live
/// recording's measured beats drift, and a time grid slides off the downbeats within minutes while
/// the ruler keeps drawing measured beats. Derived, never persisted — a cut that is stored and fed
/// back into its own input is the loop that walked one song's tempo (fa9986c).
struct ChartRowGrid: Equatable, Sendable {
    /// One row's span of song time. `index` counts periods from the bar grid's first downbeat, so
    /// rows before it (pickups ahead of the first detected beat) are negative.
    struct Window: Equatable, Sendable {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Beats per row: the phrase length rounded UP to whole bars.
    let periodBeats: Int
    /// Beat index where window 0 starts — the bar grid's first downbeat.
    let anchorBeatIndex: Int
    let measure: MeasureGrid
    /// Every row from the song's start to its end, in order; they tile `0...duration` exactly
    /// (the first and last are clipped to it).
    let windows: [Window]

    /// `phraseBeats` rounded up to a whole number of bars, never less than one bar.
    static func periodBeats(phraseBeats: Int, beatsPerBar: Int) -> Int {
        let bar = max(beatsPerBar, 1)
        let bars = max((max(phraseBeats, 1) + bar - 1) / bar, 1)
        return bars * bar
    }

    /// The grid for a timed song, or nil when there is nothing to cut on (no detected beats, no
    /// tempo, no duration) — such songs keep the variable-length rows.
    static func make(
        beatTimes: [TimeInterval],
        bpm: Double?,
        barGrid: SongBarGrid?,
        phraseBeats: Int,
        duration: TimeInterval
    ) -> ChartRowGrid? {
        guard let bpm, bpm.isFinite, bpm > 0, duration > 0 else { return nil }
        let bars = barGrid ?? .unknown
        let measure = MeasureGrid(
            beatTimes: beatTimes, bpm: bpm, beatsPerBar: bars.beatsPerBar, barPhase: bars.barPhase)
        guard measure.isUsable else { return nil }
        let period = periodBeats(phraseBeats: phraseBeats, beatsPerBar: measure.beatsPerBar)
        let anchor = measure.barPhase

        func rowIndex(atBeatIndex beatIndex: Double) -> Int {
            Int(((beatIndex - Double(anchor)) / Double(period)).rounded(.down))
        }
        func boundary(_ row: Int) -> TimeInterval {
            measure.time(atBeatIndex: Double(anchor + row * period))
        }

        let first = rowIndex(atBeatIndex: measure.beatIndex(atTime: 0))
        let last = rowIndex(atBeatIndex: measure.beatIndex(atTime: duration))
        let windows: [Window] = (first...last).compactMap { row in
            let start = max(boundary(row), 0)
            let end = min(boundary(row + 1), duration)
            return end > start ? Window(index: row, start: start, end: end) : nil
        }
        return ChartRowGrid(
            periodBeats: period, anchorBeatIndex: anchor, measure: measure, windows: windows)
    }

    /// The row index a song time falls in. A time exactly on a boundary belongs to the later row,
    /// matching the half-open windows.
    func windowIndex(forTime time: TimeInterval) -> Int {
        let beats = measure.beatIndex(atTime: time) - Double(anchorBeatIndex)
        // Snap float noise at an exact boundary (a word onset stamped on the downbeat) forward.
        let rows = beats / Double(periodBeats)
        let nearest = rows.rounded()
        return abs(rows - nearest) < 1e-9 ? Int(nearest) : Int(rows.rounded(.down))
    }
}

/// One chart row's sung text on fixed-period rows: the words of every source lyric line whose
/// onsets fall in the same `ChartRowGrid` window, as a lyric segment the preview can index by
/// ordinal exactly like a source line.
struct ChartLyricLine: Equatable, Sendable {
    let windowIndex: Int
    /// The row's words and text. `id` is the first source line's, so accept/override actions keep
    /// addressing a real stored line; `overrideText` survives only on a row holding exactly one
    /// whole source line; `accepted` is true only when every source line is.
    let segment: TimedLyricSegment
    /// Every source line with words on this row, in chart order.
    let sourceIDs: [TimedLyricSegment.ID]
    /// True when the row's last source line carries on onto a later row (drawn as "→").
    let continuesOnNextRow: Bool
    /// True when the row is exactly one whole stored line — the only rows whose text can be
    /// corrected in place, since a correction replaces the whole stored line.
    let isWholeSourceLine: Bool
}

/// Cuts lyric lines onto fixed-period rows. Pure: stored lyrics are never rewritten — the cut is
/// derived from them every time, so a row change can never feed back into what it was cut from.
enum ChartLyricLineCutter {
    /// Chart lines in row order. A word belongs to the window holding its onset, except that a
    /// line's opening pickup — words starting within `ChartPickupGutter.maximumBeats` before the
    /// next window, when the rest of the line sings in that window — moves forward into it, where
    /// the row's gutter draws it. A hand-corrected line (non-empty `overrideText`) and a line
    /// without word timings are never split.
    static func lines(from lyrics: [TimedLyricSegment], grid: ChartRowGrid) -> [ChartLyricLine] {
        let sorted = lyrics.sorted {
            if $0.start == $1.start, $0.end == $1.end { return $0.text < $1.text }
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        struct Piece {
            let window: Int
            let source: TimedLyricSegment
            let words: [TimedLyricWord]
            let isWhole: Bool
            let continues: Bool
        }
        var pieces: [Piece] = []
        for line in sorted {
            let hasOverride =
                !(line.overrideText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard !line.words.isEmpty, !hasOverride else {
                let window = grid.windowIndex(forTime: line.words.first?.start ?? line.start)
                pieces.append(
                    Piece(
                        window: window, source: line, words: line.words, isWhole: true,
                        continues: false))
                continue
            }
            var windows = line.words.map { grid.windowIndex(forTime: $0.start) }
            if let first = windows.first, let later = windows.firstIndex(where: { $0 > first }),
                windows[..<later].allSatisfy({ $0 == first })
            {
                let boundaryBeat = Double(grid.anchorBeatIndex + windows[later] * grid.periodBeats)
                let pickupFloor = boundaryBeat - Double(ChartPickupGutter.maximumBeats)
                if line.words[..<later].allSatisfy({
                    grid.measure.beatIndex(atTime: $0.start) >= pickupFloor
                }) {
                    for index in 0..<later { windows[index] = windows[later] }
                }
            }
            let lastWindow = windows.last ?? 0
            var start = 0
            while start < line.words.count {
                var end = start
                while end + 1 < line.words.count, windows[end + 1] == windows[start] { end += 1 }
                let isWhole = start == 0 && end == line.words.count - 1
                pieces.append(
                    Piece(
                        window: windows[start], source: line, words: Array(line.words[start...end]),
                        isWhole: isWhole, continues: windows[start] < lastWindow))
                start = end + 1
            }
        }

        let byWindow = Dictionary(grouping: pieces, by: \.window)
        return byWindow.keys.sorted().map { window in
            let rowPieces = byWindow[window]!
            if rowPieces.count == 1, let only = rowPieces.first, only.isWhole {
                return ChartLyricLine(
                    windowIndex: window, segment: only.source, sourceIDs: [only.source.id],
                    continuesOnNextRow: false, isWholeSourceLine: true)
            }
            var text = ""
            var words: [TimedLyricWord] = []
            for piece in rowPieces {
                // A line without word timings (never split) contributes its whole text as one token.
                let displayText =
                    piece.source.overrideText?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? piece.source.text
                let pieceWords =
                    piece.words.isEmpty
                    ? [
                        TimedLyricWord(
                            text: displayText, start: piece.source.start, end: piece.source.end,
                            characterRange: 0..<0)
                    ]
                    : piece.words
                for word in pieceWords {
                    if !text.isEmpty { text += " " }
                    let lower = text.count
                    text += word.text
                    var rebased = word
                    rebased.characterRange = lower..<text.count
                    words.append(rebased)
                }
            }
            let first = rowPieces[0].source
            let segment = TimedLyricSegment(
                id: first.id,
                start: words.first?.start ?? first.start,
                end: words.last?.end ?? first.end,
                text: text,
                words: words.filter { !$0.characterRange.isEmpty },
                confidence: rowPieces.compactMap(\.source.confidence).min(),
                accepted: rowPieces.allSatisfy(\.source.accepted),
                overrideText: nil)
            var seen = Set<TimedLyricSegment.ID>()
            return ChartLyricLine(
                windowIndex: window, segment: segment,
                sourceIDs: rowPieces.map(\.source.id).filter { seen.insert($0).inserted },
                continuesOnNextRow: rowPieces.last?.continues ?? false,
                isWholeSourceLine: false)
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
