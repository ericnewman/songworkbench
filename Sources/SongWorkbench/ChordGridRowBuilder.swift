import Foundation
import SwiftUI

/// Groups chord events into the same rows the song sheet uses — one row per lyric line, plus
/// rows for the instrumental spans between them — so the Chords editor reads like the chart
/// instead of like a flat timestamp list.
///
/// Built from `chordEvents` and `lyricSegments` rather than from the parsed ChordPro text:
/// `ChordProPreviewChord` carries only a name and a character column, with no time, confidence, or
/// identity, so a grid driven off the preview document could not colour a cell by confidence or
/// map a tap back to the event behind it. Grouping by the lyric lines' time spans gives the same
/// row order and the same sung-line correspondence, with every cell still a real event.
enum ChordGridRowBuilder {
    struct Row: Equatable, Sendable, Identifiable {
        /// Stable across rebuilds: lyric rows key off the segment, instrumental rows off their
        /// start time.
        let id: String
        /// The lyric line this row's chords sound under, or `nil` for an instrumental span.
        let lyric: String?
        /// The segment behind `lyric`, kept so the row can bold the word being sung. `nil` on
        /// instrumental rows.
        let segment: TimedLyricSegment?
        /// Display label for an instrumental row — "Intro", "Instrumental", or "Outro".
        let instrumentalLabel: String?
        let start: TimeInterval
        let end: TimeInterval
        let eventIDs: [EditableChordEvent.ID]

        var isInstrumental: Bool { lyric == nil }
    }

    /// Rows in time order. Every event lands in exactly one row; events before the first lyric
    /// line become an intro row, events after the last become an outro row, and events in a gap
    /// between lines become an instrumental row.
    ///
    /// A lyric line with no chords under it still gets a row — the gap is the information (the
    /// chart shows that line with no chord change over it), and dropping it would misalign the
    /// grid against the sheet.
    static func rows(
        events: [EditableChordEvent],
        lyricSegments: [TimedLyricSegment],
        sourceDuration: TimeInterval? = nil,
        beatTimes: [TimeInterval] = [],
        beatsPerBar: Int = 4,
        barPhase: Int = 0
    ) -> [Row] {
        let sortedEvents = events.sorted { $0.time < $1.time }
        let lines = lyricSegments.sorted { $0.start < $1.start }
        let target = instrumentalLineTarget(
            lyricSegments: lyricSegments, beatTimes: beatTimes, beatsPerBar: beatsPerBar)

        /// Instrumental spans have no lyric to break them, so they are broken by the song's own
        /// line length instead — see `splitInstrumental`.
        func appendInstrumental(_ row: Row, to rows: inout [Row]) {
            rows.append(
                contentsOf: splitInstrumental(
                    row, events: sortedEvents, target: target,
                    beatTimes: beatTimes, beatsPerBar: beatsPerBar, barPhase: barPhase))
        }

        guard !lines.isEmpty else {
            guard !sortedEvents.isEmpty else { return [] }
            var only: [Row] = []
            appendInstrumental(
                Row(
                    id: "instrumental-0",
                    lyric: nil,
                    segment: nil,
                    instrumentalLabel: "Instrumental",
                    start: sortedEvents.first?.time ?? 0,
                    end: sourceDuration ?? sortedEvents.last?.time ?? 0,
                    eventIDs: sortedEvents.map(\.id)
                ), to: &only)
            return only
        }

        // Each lyric line owns events from its own start until the next line's start, so a chord
        // struck in the gap after a line belongs to whichever span actually contains it rather
        // than being silently dropped between `end` and the next `start`.
        var rows: [Row] = []
        let firstStart = lines[0].start
        let intro = sortedEvents.filter { $0.time < firstStart }
        if !intro.isEmpty {
            appendInstrumental(
                Row(
                    id: "intro",
                    lyric: nil,
                    segment: nil,
                    instrumentalLabel: "Intro",
                    start: intro.first?.time ?? 0,
                    end: firstStart,
                    eventIDs: intro.map(\.id)
                ), to: &rows)
        }

        for (index, line) in lines.enumerated() {
            let lineEnd = index + 1 < lines.count ? lines[index + 1].start : line.end
            let inLine = sortedEvents.filter { $0.time >= line.start && $0.time < line.end }
            rows.append(
                Row(
                    id: "lyric-\(line.id)",
                    lyric: line.text,
                    segment: line,
                    instrumentalLabel: nil,
                    start: line.start,
                    end: line.end,
                    eventIDs: inLine.map(\.id)
                ))

            // The span between this line's end and the next line's start: a real instrumental
            // break in the sheet, not part of either line.
            guard lineEnd > line.end else { continue }
            let between = sortedEvents.filter { $0.time >= line.end && $0.time < lineEnd }
            guard !between.isEmpty else { continue }
            appendInstrumental(
                Row(
                    id: "instrumental-\(line.id)",
                    lyric: nil,
                    segment: nil,
                    instrumentalLabel: "Instrumental",
                    start: line.end,
                    end: lineEnd,
                    eventIDs: between.map(\.id)
                ), to: &rows)
        }

        let lastEnd = lines[lines.count - 1].end
        let outro = sortedEvents.filter { $0.time >= lastEnd }
        if !outro.isEmpty {
            appendInstrumental(
                Row(
                    id: "outro",
                    lyric: nil,
                    segment: nil,
                    instrumentalLabel: "Outro",
                    start: lastEnd,
                    end: sourceDuration ?? outro.last?.time ?? lastEnd,
                    eventIDs: outro.map(\.id)
                ), to: &rows)
        }
        return rows
    }

    /// Longest an instrumental row may run before it is broken onto another line, and the most
    /// chords one may carry. A long intro is one continuous span with no lyric to break it, so
    /// without this it renders as a single crowded line — and because every row shares one
    /// seconds-per-pixel scale, that one row also squeezes every sung line in the song.
    ///
    /// The target comes from the song itself, in preference order:
    /// 1. the median sung-line duration — this song's own idea of a comfortable line;
    /// 2. four bars at the measured tempo, when there are no lyrics to learn from;
    /// 3. a plain 8 seconds, when there is neither.
    static func instrumentalLineTarget(
        lyricSegments: [TimedLyricSegment],
        beatTimes: [TimeInterval],
        beatsPerBar: Int = 4
    ) -> TimeInterval {
        let sung = lyricSegments.map { $0.end - $0.start }.filter { $0 > 0 }.sorted()
        if !sung.isEmpty {
            return sung[sung.count / 2]
        }
        if beatTimes.count >= 2 {
            let spans = zip(beatTimes.dropFirst(), beatTimes).map(-).filter { $0 > 0 }.sorted()
            if !spans.isEmpty {
                return spans[spans.count / 2] * Double(beatsPerBar * 4)
            }
        }
        return 8
    }

    /// Most chords one instrumental line may carry, so a dense passage breaks on chord count even
    /// when it is short enough in time.
    static let maximumInstrumentalChords = 8

    /// Breaks one instrumental row into however many lines it needs.
    ///
    /// A break goes BEFORE the chord that would push the line past `target`, so no chord is ever
    /// separated from its own attack, and — when a beat grid is available — the boundary is moved
    /// to the nearest downbeat within half a bar, since a chart reads wrong when a line starts
    /// mid-bar. A line always keeps at least one chord, so a target shorter than the gap between
    /// two chords degrades to one chord per line rather than looping.
    static func splitInstrumental(
        _ row: Row,
        events: [EditableChordEvent],
        target: TimeInterval,
        beatTimes: [TimeInterval] = [],
        beatsPerBar: Int = 4,
        barPhase: Int = 0
    ) -> [Row] {
        guard row.isInstrumental, row.eventIDs.count > 1, target > 0 else { return [row] }
        let timeByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0.time) })
        // Downbeats honor the song's shared bar phase (`SongBarGrid.barPhase`): a phase-1 song's
        // first downbeat is beat 1, so striding from 0 would snap every split one beat early.
        let firstDownbeat = max(0, barPhase) % max(beatsPerBar, 1)
        let downbeats = stride(from: firstDownbeat, to: beatTimes.count, by: max(beatsPerBar, 1))
            .map { beatTimes[$0] }
        let barLength =
            beatTimes.count >= 2 ? (beatTimes[1] - beatTimes[0]) * Double(beatsPerBar) : 0

        var chunks: [[EditableChordEvent.ID]] = []
        var current: [EditableChordEvent.ID] = []
        var chunkStart = row.start
        for id in row.eventIDs {
            let time = timeByID[id] ?? chunkStart
            let wouldOverrun = time - chunkStart > target
            let wouldCrowd = current.count >= maximumInstrumentalChords
            if !current.isEmpty, wouldOverrun || wouldCrowd {
                chunks.append(current)
                current = []
                chunkStart = time
            }
            current.append(id)
        }
        if !current.isEmpty { chunks.append(current) }
        guard chunks.count > 1 else { return [row] }

        return chunks.enumerated().map { index, ids in
            let rawStart =
                index == 0 ? row.start : (ids.first.flatMap { timeByID[$0] } ?? row.start)
            let rawEnd =
                index + 1 < chunks.count
                ? (chunks[index + 1].first.flatMap { timeByID[$0] } ?? row.end)
                : row.end
            return Row(
                id: "\(row.id)-\(index)",
                lyric: nil,
                segment: nil,
                instrumentalLabel: row.instrumentalLabel,
                start: index == 0 ? rawStart : snappedToDownbeat(rawStart, downbeats, barLength),
                end: index + 1 < chunks.count
                    ? snappedToDownbeat(rawEnd, downbeats, barLength) : rawEnd,
                eventIDs: ids
            )
        }
    }

    /// Nearest downbeat within half a bar of `time`, else `time` unchanged. Guarded so a grid that
    /// disagrees with the chord times can never drag a line start past the chord that opens it.
    private static func snappedToDownbeat(
        _ time: TimeInterval, _ downbeats: [TimeInterval], _ barLength: TimeInterval
    ) -> TimeInterval {
        guard barLength > 0, !downbeats.isEmpty else { return time }
        guard let nearest = downbeats.min(by: { abs($0 - time) < abs($1 - time) }) else {
            return time
        }
        return abs(nearest - time) <= barLength / 2 ? nearest : time
    }

    /// The chord sounding at `time` — the latest event at or before it. A chord rings until the
    /// next one is struck, so this holds through the whole span rather than lighting up only at
    /// the instant of the attack. `nil` before the first event.
    static func soundingEventID(
        events: [EditableChordEvent],
        at time: TimeInterval
    ) -> EditableChordEvent.ID? {
        events
            .filter { $0.time <= time }
            .max { $0.time < $1.time }?
            .id
    }

    /// Character range of the word being sung at `time`, for emphasis in the grid's lyric row.
    ///
    /// Falls back to the last word that has already started, so the emphasis stays on the final
    /// word through a held note or a trailing gap instead of blinking off. `nil` before the line's
    /// first word, or when the segment carries no word timings at all (some transcription paths
    /// produce line-level timings only, and guessing a range from character counts would put the
    /// emphasis on the wrong word).
    static func singingWordRange(
        in segment: TimedLyricSegment,
        at time: TimeInterval
    ) -> Range<Int>? {
        let words = segment.words.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return nil }
        if let current = words.last(where: { time >= $0.start && time < $0.end }) {
            return current.characterRange
        }
        guard let started = words.last(where: { time >= $0.start }) else { return nil }
        return started.characterRange
    }
}

/// Places a row's items along a uniform time axis, so the horizontal gap between two words is the
/// actual pause between them and a chord sits over the word it lands on.
///
/// This is the Review panel's idea — `ChordRowRuler`'s "one axis per row" rule — applied to the
/// chord grid. It deliberately uses the ruler's no-grid (uniform seconds) mode rather than its
/// metric beat axis: the metric axis makes a row's width depend on how many beats it spans, which
/// needs the fitted-chart machinery to stay inside a panel, and pauses are what this view is being
/// asked to show.
///
/// Overlap is resolved exactly the way `ChordRowStringBuilder` resolves it in the text chart: an
/// item whose time would land inside its predecessor is pushed just past it instead. The nudge is
/// a label offset only — it never feeds back into any other item's position, so the two rows
/// (chords and words) stay on the same axis.
struct TimeAxisRowLayout: Layout {
    /// Song time for each subview, in subview order. Shorter than the subview count is safe;
    /// extra subviews are laid out after the last placed item.
    let times: [TimeInterval]
    let start: TimeInterval
    let end: TimeInterval
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let duration = max(end - start, 0.0001)
        var cursor = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let time = index < times.count ? times[index] : end
            let fraction = (time - start) / duration
            var x = bounds.minX + CGFloat(min(max(fraction, 0), 1)) * bounds.width
            // Keep the item fully on-row, then honour the no-overlap cursor. Order matters: the
            // right-edge clamp must not be allowed to pull an item back over its predecessor.
            x = min(x, bounds.maxX - size.width)
            x = max(x, cursor)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            cursor = x + size.width + spacing
        }
    }
}

/// Confidence bands for the grid's colour coding. Replaces the per-row numeric percentage: at a
/// glance the useful question is "which chords should I check?", and a colour answers that across
/// a whole song where a column of percentages does not. The exact number stays available in the
/// cell's popover.
enum ChordConfidenceBand: String, Equatable, Sendable, CaseIterable {
    case low
    case medium
    case high
    /// No confidence recorded — a hand-added chord. Not a judgement about the audio, so it gets
    /// its own neutral band rather than being lumped in with `low`.
    case manual

    /// Thresholds are the band edges, not the ChordPro inclusion threshold — a chord can be
    /// `low` and still be included, or `high` and excluded, if the user moves that slider.
    static func band(for confidence: Float?) -> ChordConfidenceBand {
        guard let confidence else { return .manual }
        if confidence < 0.5 { return .low }
        if confidence < 0.75 { return .medium }
        return .high
    }

    var label: String {
        switch self {
        case .low: "Low confidence"
        case .medium: "Medium confidence"
        case .high: "High confidence"
        case .manual: "Added manually"
        }
    }
}
