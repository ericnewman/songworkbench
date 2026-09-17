import Foundation

/// The single source of truth for the chart's structure × time (audit: tasks/audit-ball-timing.md,
/// spec: tasks/spec-songtimeline.md). Produced by `ChordProDraftBuilder` in the same pass that
/// renders the ChordPro text, so every rendered musical line (the preview's numbered rows) has an
/// authoritative time window here — consumers look rows up by playhead time instead of re-deriving
/// structure from the serialized string with adjacency heuristics (the whack-a-mole engine).
///
/// `rows[i].number` is 1-based and matches the preview's `displayLineNumber` exactly when the
/// previewed source is the generated draft; callers verify that by comparing the built source
/// string with the source being previewed (see `AppModel.songTimelineForPreview`).
struct SongTimeline: Equatable, Codable, Sendable {
    var rows: [Row]

    struct Row: Equatable, Codable, Sendable {
        /// 1-based musical line number (lyric AND chord-only lines), == preview displayLineNumber.
        let number: Int
        let kind: Kind
        /// Authoritative window `[start, end)`. Rows ascend and do not overlap (a sub-4-bar gap
        /// after a lyric line belongs to that line — its trailing chords are folded there too).
        let start: TimeInterval
        let end: TimeInterval
        /// Onset times of the chords rendered on this row (chart order).
        let chordTimes: [TimeInterval]
        /// True when this row's window overlaps a sung-but-untranscribed region (audit RC-4):
        /// the "instrumental" here actually contains vocals the ASR missed.
        let containsUntranscribedVocals: Bool

        enum Kind: Equatable, Codable, Sendable {
            /// Index into the SORTED lyric segments (same ordinal the preview/highlight uses).
            case lyric(ordinal: Int)
            case instrumental(role: InstrumentalRole)
        }

        enum InstrumentalRole: Equatable, Codable, Sendable {
            case intro
            case interlude
            case outro
        }

        var isLyric: Bool {
            if case .lyric = kind { return true }
            return false
        }

        /// Stable identity: the row's kind and its window start to the millisecond. Row numbers
        /// shift when a row is added above; a row that still covers the same stretch of the song
        /// keeps its id through rebuilds and reloads.
        var id: String {
            let tag: String
            switch kind {
            case .lyric: tag = "lyric"
            case .instrumental(let role): tag = "\(role)"
            }
            return "\(tag)@\(Int((start * 1000).rounded()))"
        }
    }

    /// True when `source` numbers the same musical lines, in order, as these rows: a lyric line
    /// where a row is a lyric row and a chord-only line where it is instrumental. Edited text on
    /// the same lines keeps every row's window valid.
    func matchesRowStructure(of source: String) -> Bool {
        guard let document = try? ChordProPreviewDocument(parsing: source) else { return false }
        let lines = ChordProPreviewIndexing.indexedBlocks(for: document)
            .filter { $0.displayLineNumber != nil }
            .map { $0.lyricOrdinal != nil }
        return lines == rows.map(\.isLyric)
    }

    /// The row the playhead is in: the LAST row whose `start <= time`. A time inside the short
    /// un-rowed gap between two rows resolves to the earlier row (hold-through-gap semantics —
    /// matching how the chart folds short trailing intervals into the preceding line). `nil`
    /// before the first row starts.
    func row(at time: TimeInterval) -> Row? {
        var candidate: Row?
        for row in rows {
            if row.start <= time { candidate = row } else { break }
        }
        return candidate
    }

    /// The first row starting after `time` (the row a waiting ball parks toward), if any.
    func nextRow(after time: TimeInterval) -> Row? {
        rows.first { $0.start > time }
    }
}

/// The chart layout a generated ChordPro draft was built with, persisted beside it (the
/// `SongTimeline` sidecar). Row windows are authoritative for the chart they were built for, so
/// they stay valid when the chart's text is edited on the same lines, and they are withdrawn when
/// the lyrics they were cut from change underneath a kept chart.
struct PersistedChartLayout: Equatable, Codable, Sendable {
    /// Bump when the persisted shape or its meaning changes; other versions are ignored.
    static let currentVersion = 1

    var version = currentVersion
    var timeline: SongTimeline
    var chartLines: [ChartLyricLine] = []
    var periodBeats: Int? = nil
    var rowOrigins: [Int: TimeInterval] = [:]
    /// `LyricStructureDigest` of the lyrics the chart was built from.
    var lyricStructureDigest: String

    init(result: ChordProDraftResult, lyrics: [TimedLyricSegment]) {
        timeline = result.timeline
        chartLines = result.chartLines
        periodBeats = result.periodBeats
        rowOrigins = result.rowOrigins
        lyricStructureDigest = LyricStructureDigest.of(lyrics)
    }

    func result(source: String) -> ChordProDraftResult {
        ChordProDraftResult(
            source: source, timeline: timeline, chartLines: chartLines, periodBeats: periodBeats,
            rowOrigins: rowOrigins)
    }
}

/// A fingerprint of what a chart's lyric rows are cut from: the resolved words in order (text as
/// rendered, lowercased letters and digits), not their times or line breaks. Timing retunes and
/// re-cuts keep it; a transcription that hears different words, or more or fewer, changes it.
enum LyricStructureDigest {
    static func of(_ lyrics: [TimedLyricSegment]) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        let words = lyrics.sorted { $0.start < $1.start }.flatMap { line in
            LyricWordRanges.tokens(in: line.resolved.text).map { LyricWordRanges.key($0.text) }
        }
        for byte in words.joined(separator: " ").utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 36)
    }
}
