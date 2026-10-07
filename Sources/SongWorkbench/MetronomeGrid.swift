import Foundation

/// The song's metronome: one rigid period extended over [0, duration], never nudged by the
/// recording's content. This is BOTH what the beat click plays when the metronome toggle is on
/// and the bucket edges the per-stem note timeline is cut on — one function, so what you hear is
/// exactly the boundary the analysis measured against. Pure so it lives in the analysis code
/// without dragging AVFoundation playback along.
enum MetronomeGrid {
    /// Period is `60 / bpm` — the analysis's reconciled tempo, the same number the chart shows —
    /// and the phase anchor is the detected beat the bar grid calls the first downbeat
    /// (`beatTimes[barPhase]`), so beat 1 of the grid is beat 1 of the chart. Without a usable
    /// BPM the period falls back to the median inter-beat interval of the detected beats
    /// (`uniformBeatGrid`); with fewer than two beats there is nothing to fit and the input is
    /// returned as-is.
    static func clickTimes(
        beatTimes: [TimeInterval], bpm: Double?, barGrid: SongBarGrid?, duration: TimeInterval
    ) -> [TimeInterval] {
        let sorted = beatTimes.sorted()
        guard let first = sorted.first else { return [] }
        let anchor = sorted[anchorIndex(barGrid: barGrid, beatCount: sorted.count)]
        if let followed = followedGrid(sorted, duration: duration) { return followed }
        if let bpm, bpm.isFinite, bpm > 0 {
            let period = 60 / bpm
            guard period > 0.05 else { return sorted }
            return periodicGrid(period: period, anchor: anchor, duration: duration)
        }
        // No tempo: fit the period from the beats themselves, keeping the downbeat anchor.
        return uniformBeatGrid(from: sorted, anchor: anchor, duration: duration) ?? [first]
    }

    /// Beats whose spacing varies are a grid that follows the drummer
    /// (`DrumBeatGrid.followedBeatTimes`): a rigid click would walk off the recording, so the
    /// click IS those beats, carried to both ends of the song at the nearest stretch's tempo.
    /// A rigid analysis grid (spacing equal to well under a millisecond) returns nil.
    static func followedGrid(_ sorted: [TimeInterval], duration: TimeInterval) -> [TimeInterval]? {
        guard sorted.count >= 3, let first = sorted.first, let last = sorted.last else {
            return nil
        }
        let intervals = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        guard let shortest = intervals.min(), let longest = intervals.max(), shortest > 0.05,
            longest - shortest > 0.001
        else { return nil }
        // ponytail: recognized by shape, not by a stored flag — a followed grid drifts SMOOTHLY
        // (neighbouring beat lengths within a few ms; measured 2–5 ms), where a tracker's raw
        // beats jump by a hop (11.6 ms) or more and still get the rigid click. Persist a flag on
        // the document if this ever misfires.
        let steps = zip(intervals.dropFirst(), intervals).map { abs($0 - $1) }
        guard let largestStep = steps.max(), largestStep < 0.008 else { return nil }
        let lead = stride(from: first - intervals[0], through: 0, by: -intervals[0]).reversed()
        let tailStep = intervals[intervals.count - 1]
        let tail = stride(from: last + tailStep, through: duration, by: tailStep)
        return Array(lead) + sorted + Array(tail)
    }

    /// The phase anchor `clickTimes` uses: the bar grid's first downbeat, clamped into the
    /// detected beats. Exposed so a persisted bucket timeline can record which grid it was cut
    /// on and detect when the document's timing has since moved.
    static func anchorTime(beatTimes: [TimeInterval], barGrid: SongBarGrid?) -> TimeInterval? {
        let sorted = beatTimes.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[anchorIndex(barGrid: barGrid, beatCount: sorted.count)]
    }

    private static func anchorIndex(barGrid: SongBarGrid?, beatCount: Int) -> Int {
        min(max(barGrid?.barPhase ?? 0, 0), beatCount - 1)
    }

    /// Median inter-beat interval of `sorted` as the period, phase-anchored at `anchor`. `nil`
    /// when there aren't enough beats (or they are degenerately spaced) to estimate a period.
    static func uniformBeatGrid(
        from sorted: [TimeInterval], anchor: TimeInterval, duration: TimeInterval
    ) -> [TimeInterval]? {
        guard sorted.count >= 2 else { return nil }
        var intervals: [TimeInterval] = []
        for index in 1..<sorted.count { intervals.append(sorted[index] - sorted[index - 1]) }
        intervals.sort()
        let period = intervals[intervals.count / 2]  // median
        guard period > 0.05 else { return nil }  // sanity: ignore degenerate spacing
        return periodicGrid(period: period, anchor: anchor, duration: duration)
    }

    /// `anchor + k·period` for every integer k that lands in [0, duration], ascending. Computed by
    /// index rather than by repeated addition so a 4-minute grid does not accumulate float drift.
    static func periodicGrid(
        period: TimeInterval, anchor: TimeInterval, duration: TimeInterval
    ) -> [TimeInterval] {
        guard period > 0, duration >= 0 else { return [] }
        let firstIndex = Int(ceil(-anchor / period))
        let lastIndex = Int(floor((duration - anchor) / period))
        guard lastIndex >= firstIndex else { return [] }
        return (firstIndex...lastIndex).map { anchor + Double($0) * period }
    }
}
