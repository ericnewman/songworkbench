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
        /// The beat index the row starts on, and its length in beats: `periodBeats`, except the
        /// last row before a section start, which ends where the section's first bar begins.
        let startBeat: Int
        let beats: Int
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
    ///
    /// `sectionStarts` are the first-word times of the song's sections. Each section starts a
    /// fresh row on the downbeat of the bar holding its first word, and the bars before it stay
    /// with the previous section as a shorter row (Eric, 2026-10-06: "start verses and choruses
    /// on the measure that has the first word, and leave any empty measure as part of the
    /// previous section"). On one song-wide grid, 20 of 91 sections on his album opened with
    /// empty bars.
    static func make(
        beatTimes: [TimeInterval],
        bpm: Double?,
        barGrid: SongBarGrid?,
        phraseBeats: Int,
        duration: TimeInterval,
        sectionStarts: [TimeInterval] = []
    ) -> ChartRowGrid? {
        guard let bpm, bpm.isFinite, bpm > 0, duration > 0 else { return nil }
        let bars = barGrid ?? .unknown
        let measure = MeasureGrid(
            beatTimes: beatTimes, bpm: bpm, beatsPerBar: bars.beatsPerBar, barPhase: bars.barPhase)
        guard measure.isUsable else { return nil }
        let period = periodBeats(phraseBeats: phraseBeats, beatsPerBar: measure.beatsPerBar)
        let anchor = measure.barPhase
        let bar = max(measure.beatsPerBar, 1)

        func floored(_ beatIndex: Double, to length: Int) -> Int {
            Int(((beatIndex - Double(anchor)) / Double(length)).rounded(.down))
        }
        // A first word sung within the pickup gutter before a downbeat is an anacrusis into that
        // bar, so the section starts on it. Flooring it instead started Flip Flops' second verse
        // a bar early ("Charcoal" 0.6 beat ahead of the downbeat): a half row, then every verse
        // row a bar out of phase with its lines. The pickup word itself still stays at the end of
        // the row where it sounds, like any other pickup.
        let pickup = Double(ChartPickupGutter.maximumBeats)
        let restarts = Set(
            sectionStarts.map {
                anchor + floored(measure.beatIndex(atTime: $0) + pickup, to: bar) * bar
            }
        ).sorted()

        var index = floored(measure.beatIndex(atTime: 0), to: period)
        var cursor = anchor + index * period
        let finalBeat = measure.beatIndex(atTime: duration)
        var restart = restarts.startIndex
        var windows: [Window] = []
        while Double(cursor) < finalBeat {
            while restart < restarts.endIndex, restarts[restart] <= cursor { restart += 1 }
            var next = cursor + period
            if restart < restarts.endIndex, restarts[restart] < next { next = restarts[restart] }
            let start = max(measure.time(atBeatIndex: Double(cursor)), 0)
            let end = min(measure.time(atBeatIndex: Double(next)), duration)
            if end > start {
                windows.append(
                    Window(
                        index: index, start: start, end: end, startBeat: cursor,
                        beats: next - cursor))
            }
            index += 1
            cursor = next
        }
        return ChartRowGrid(
            periodBeats: period, anchorBeatIndex: anchor, measure: measure, windows: windows)
    }

    /// The row a pickup sung at `time` leads into: the row whose downbeat follows `time` within
    /// the pickup gutter, or nil. A line's opening pickup belongs on that row, drawn in its gutter,
    /// not crammed onto the end of the row before (Eric, 2026-10-07, on Flip Flops: "first word of
    /// verses is still crammed in to the end of the lines").
    func pickupWindow(forTime time: TimeInterval) -> Int? {
        let beat = measure.beatIndex(atTime: time)
        return windows.first {
            Double($0.startBeat) > beat
                && Double($0.startBeat) - beat <= Double(ChartPickupGutter.maximumBeats)
        }?.index
    }

    /// The row index a song time falls in. A time exactly on a boundary belongs to the later row,
    /// matching the half-open windows. Times outside the song continue the period either side.
    func windowIndex(forTime time: TimeInterval) -> Int {
        // Snap float noise at an exact boundary (a word onset stamped on the downbeat) forward.
        let beat = measure.beatIndex(atTime: time) + 1e-9
        guard let first = windows.first, let last = windows.last else { return 0 }
        if beat < Double(first.startBeat) {
            let before = (Double(first.startBeat) - beat) / Double(periodBeats)
            return first.index - Int(before.rounded(.up))
        }
        let lastEnd = Double(last.startBeat + last.beats)
        if beat >= lastEnd {
            return last.index + 1 + Int(((beat - lastEnd) / Double(periodBeats)).rounded(.down))
        }
        var low = 0
        var high = windows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if Double(windows[middle].startBeat) <= beat { low = middle } else { high = middle - 1 }
        }
        return windows[low].index
    }

    func window(index: Int) -> Window? {
        windows.first { $0.index == index }
    }
}

/// One chart row's sung text on fixed-period rows: the words of every source lyric line whose
/// onsets fall in the same `ChartRowGrid` window, as a lyric segment the preview can index by
/// ordinal exactly like a source line.
struct ChartLyricLine: Equatable, Codable, Sendable {
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
    /// Chart lines in row order. Every word belongs to the window holding its onset, except a
    /// line's opening pickup: words that START a line within the pickup gutter before a downbeat
    /// move onto that downbeat's row and draw in its gutter (`ChartRowGrid.pickupWindow`; Eric,
    /// 2026-10-07, replacing the 2026-09-14 rule that every pickup stays where it sounds). A
    /// pickup inside a line still stays in the row where it sounds. A hand-corrected line (non-empty `overrideText`) and a line without
    /// word timings are never split.
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
                let window = grid.windowIndex(
                    forTime: line.words.lazy.compactMap(\.start).first ?? line.start)
                pieces.append(
                    Piece(
                        window: window, source: line, words: line.words, isWhole: true,
                        continues: false))
                continue
            }
            // A word alignment could not place has no time: it stays in the window of the word
            // before it (the line's first window when it leads).
            var current = grid.windowIndex(forTime: line.start)
            var windows = line.words.map { word -> Int in
                if let start = word.start { current = grid.windowIndex(forTime: start) }
                return current
            }
            // A line opening on a pickup: its words before the next downbeat move onto that row.
            if let firstStart = line.words.first?.start,
                let pickupRow = grid.pickupWindow(forTime: firstStart)
            {
                for i in windows.indices where windows[i] < pickupRow { windows[i] = pickupRow }
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
                start: words.firstStart ?? first.start,
                end: words.lastEnd ?? first.end,
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
