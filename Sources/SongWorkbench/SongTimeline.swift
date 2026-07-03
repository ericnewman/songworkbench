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
struct SongTimeline: Equatable, Sendable {
    var rows: [Row]

    struct Row: Equatable, Sendable {
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

        enum Kind: Equatable, Sendable {
            /// Index into the SORTED lyric segments (same ordinal the preview/highlight uses).
            case lyric(ordinal: Int)
            case instrumental(role: InstrumentalRole)
        }

        enum InstrumentalRole: Equatable, Sendable {
            case intro
            case interlude
            case outro
        }

        var isLyric: Bool {
            if case .lyric = kind { return true }
            return false
        }
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
