import Foundation

/// A line from one transcription mode's pass, pending clustering into a `LyricBlendRow`.
private struct Tagged {
    let mode: TranscriptionMode
    let segment: TimedLyricSegment
}

/// Builds `LyricBlendRow`s (backlog #11, Lyric Blending) from up to 3 independent transcription
/// passes of the same song — one per `TranscriptionMode` — by clustering their lines into
/// model-agnostic time windows. Pure & deterministic.
enum LyricBlendRowBuilder {
    /// Modes are stacked in this fixed order within a row's `candidates`, so the blend UI's
    /// column order (and any "prefer accuracy" fallback) is stable regardless of which modes
    /// happened to produce a candidate for a given row.
    static let modeOrder: [TranscriptionMode] = [.accuracy, .balancedDraft, .fastDraft]

    /// - Parameters:
    ///   - fastDraft/balancedDraft/accuracy: each mode's OWN already-grouped lines (post
    ///     `TimedLyricSegmentGrouper`), or empty if that mode wasn't run/installed.
    ///   - clusterWindow: lines starting within this many seconds of a row's anchor (its
    ///     earliest-starting line) join that row rather than starting a new one. 1.5s is
    ///     generous relative to typical sung-line lengths/gaps, so genuinely different lines from
    ///     two modes describing "the same moment" cluster together even with a couple hundred
    ///     milliseconds of onset disagreement between engines, while distinct sung lines a beat
    ///     or more apart still separate.
    /// - Returns: rows sorted by start time. Empty when all 3 inputs are empty.
    static func buildRows(
        fastDraft: [TimedLyricSegment],
        balancedDraft: [TimedLyricSegment],
        accuracy: [TimedLyricSegment],
        clusterWindow: TimeInterval = 1.5
    ) -> [LyricBlendRow] {
        let tagged =
            fastDraft.map { Tagged(mode: .fastDraft, segment: $0) }
            + balancedDraft.map { Tagged(mode: .balancedDraft, segment: $0) }
            + accuracy.map { Tagged(mode: .accuracy, segment: $0) }
        guard !tagged.isEmpty else { return [] }
        let sorted = tagged.sorted { $0.segment.start < $1.segment.start }

        // Greedily cluster by proximity to each row's ANCHOR (its first/earliest line), not by
        // chaining to the last-added line — chaining a long run of lines each within
        // `clusterWindow` of the previous one could drift a row's effective span far past the
        // window with no single pair ever exceeding it. Anchoring keeps every row's start/end
        // ties bounded to `clusterWindow` of where the row began.
        var clusters: [[Tagged]] = []
        for item in sorted {
            if let anchor = clusters.last?.first?.segment.start,
                item.segment.start - anchor <= clusterWindow
            {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }

        return clusters.map(row(from:)).sorted { $0.start < $1.start }
    }

    private static func row(from cluster: [Tagged]) -> LyricBlendRow {
        var byMode: [TranscriptionMode: [TimedLyricSegment]] = [:]
        for item in cluster { byMode[item.mode, default: []].append(item.segment) }

        let candidates: [LyricBlendCandidate] = modeOrder.compactMap { mode in
            guard let segments = byMode[mode]?.sorted(by: { $0.start < $1.start }) else {
                return nil
            }
            return LyricBlendCandidate(
                mode: mode,
                text: segments.map(\.text).joined(separator: " "),
                words: segments.flatMap(\.words))
        }
        let start = cluster.map(\.segment.start).min() ?? 0
        let end = cluster.map(\.segment.end).max() ?? start
        return LyricBlendRow(start: start, end: end, candidates: candidates, selectedMode: nil)
    }

    /// The "official" lyric lines implied by the CURRENT state of `rows` — each row's
    /// `effectiveCandidate` becomes one `TimedLyricSegment`, using that candidate's own per-word
    /// timings so playback highlighting stays accurate to whichever mode's line won. This is what
    /// `AppModel` writes back to `document.lyrics` after every blend pick (and right after the 3
    /// passes first complete, before the user has picked anything).
    static func effectiveLyrics(from rows: [LyricBlendRow]) -> [TimedLyricSegment] {
        rows.compactMap { row -> TimedLyricSegment? in
            guard let candidate = row.effectiveCandidate() else { return nil }
            return TimedLyricSegment(
                start: row.start, end: row.end, text: candidate.text, words: candidate.words)
        }.sorted { $0.start < $1.start }
    }
}
