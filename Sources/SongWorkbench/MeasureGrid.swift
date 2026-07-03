import Foundation

/// A continuous musical measure grid built from detected beat times. It maps song time to a
/// fractional beat index (so every element can be placed on ONE shared metric scale, not a
/// per-line stretched axis) and identifies bar downbeats given a bar phase. Pure & deterministic.
///
/// The grid follows the REAL (snapped) beat times where they exist and extrapolates at a uniform
/// `beatLength` beyond the ends, so times before the first / after the last detected beat still map
/// to a sensible fractional index.
struct MeasureGrid: Equatable, Sendable {
    /// Sorted detected beat times.
    let beatTimes: [TimeInterval]
    /// Seconds per beat (60 / bpm), the extrapolation spacing outside `beatTimes`.
    let beatLength: TimeInterval
    /// Beats per bar (4/4 assumed).
    let beatsPerBar: Int
    /// Which beat index is a bar downbeat: index `i` is a downbeat iff `(i - barPhase) % beatsPerBar == 0`.
    let barPhase: Int

    init(beatTimes: [TimeInterval], bpm: Double, beatsPerBar: Int = 4, barPhase: Int = 0) {
        self.beatTimes = beatTimes.sorted()
        self.beatLength = bpm > 0 ? 60.0 / bpm : 0
        self.beatsPerBar = max(1, beatsPerBar)
        let bp = beatsPerBar > 0 ? ((barPhase % beatsPerBar) + beatsPerBar) % beatsPerBar : 0
        self.barPhase = bp
    }

    /// True once the grid can place events (has beats and a positive beat length).
    var isUsable: Bool { !beatTimes.isEmpty && beatLength > 0 }

    /// The fractional beat index of a song time. `beatTimes[i]` maps to `i`; times between beats
    /// interpolate; times outside the detected range extrapolate at `beatLength`.
    func beatIndex(atTime time: TimeInterval) -> Double {
        guard beatLength > 0 else { return 0 }
        guard let first = beatTimes.first, let last = beatTimes.last else {
            return time / beatLength
        }
        if time <= first {
            return -(first - time) / beatLength
        }
        let n = beatTimes.count
        if time >= last {
            return Double(n - 1) + (time - last) / beatLength
        }
        // Binary search for the beat interval containing `time`.
        var lo = 0
        var hi = n - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if beatTimes[mid] <= time { lo = mid } else { hi = mid }
        }
        let t0 = beatTimes[lo]
        let t1 = beatTimes[lo + 1]
        let frac = t1 > t0 ? (time - t0) / (t1 - t0) : 0
        return Double(lo) + frac
    }

    /// The song time at a (possibly fractional) beat index — inverse of `beatIndex(atTime:)`.
    func time(atBeatIndex index: Double) -> TimeInterval {
        guard beatLength > 0 else { return 0 }
        guard let first = beatTimes.first, let last = beatTimes.last else {
            return index * beatLength
        }
        let n = beatTimes.count
        if index <= 0 {
            return first + index * beatLength
        }
        if index >= Double(n - 1) {
            return last + (index - Double(n - 1)) * beatLength
        }
        let i = Int(index.rounded(.down))
        let frac = index - Double(i)
        let t0 = beatTimes[i]
        let t1 = beatTimes[min(i + 1, n - 1)]
        return t0 + frac * (t1 - t0)
    }

    /// Whether integer beat index `i` falls on a bar downbeat.
    func isDownbeat(beatIndex i: Int) -> Bool {
        ((i - barPhase) % beatsPerBar + beatsPerBar) % beatsPerBar == 0
    }

    /// The integer downbeat index nearest to a (fractional) beat index. A pickup one beat before a
    /// downbeat rounds FORWARD to that downbeat, so a line "resolves" onto its downbeat column.
    func nearestDownbeatIndex(toBeatIndex x: Double) -> Int {
        let bars = (x - Double(barPhase)) / Double(beatsPerBar)
        return Int(bars.rounded()) * beatsPerBar + barPhase
    }

    /// The nearest bar downbeat time to a song time.
    func nearestDownbeatTime(toTime songTime: TimeInterval) -> TimeInterval {
        time(atBeatIndex: Double(nearestDownbeatIndex(toBeatIndex: beatIndex(atTime: songTime))))
    }
}

/// Estimates the bar phase (which beat is beat 1) by aligning event onsets to the beat grid.
/// Vocal-line onsets in most songs cluster on the downbeat and on the pickup just before it; the
/// phase that puts the most onset mass on the downbeat (with the pickup weighted next) wins.
/// Pure & deterministic.
enum DownbeatEstimator {
    /// Per-beat-in-bar weight when scoring a candidate downbeat phase: the downbeat (0) is strongest,
    /// then the pickup beat just before the next downbeat, then the mid-bar beats.
    /// Index = beat position within the bar for a candidate phase.
    static let beatWeights4: [Double] = [1.0, 0.25, 0.5, 0.75]

    /// Returns the bar phase in `0..<beatsPerBar` best explaining `onsets` on the `beatTimes` grid.
    /// Returns 0 for degenerate input.
    static func barPhase(
        beatTimes: [TimeInterval],
        onsets: [TimeInterval],
        beatsPerBar: Int = 4
    ) -> Int {
        let beats = beatTimes.sorted()
        guard beats.count >= beatsPerBar, !onsets.isEmpty, beatsPerBar > 0 else { return 0 }
        let weights =
            beatsPerBar == 4
            ? beatWeights4
            : (0..<beatsPerBar).map { $0 == 0 ? 1.0 : 0.5 }

        // Residue histogram: for each onset, the index (mod beatsPerBar) of its nearest beat.
        var residueCounts = [Int](repeating: 0, count: beatsPerBar)
        for onset in onsets {
            let idx = nearestBeatIndex(to: onset, in: beats)
            let residue = ((idx % beatsPerBar) + beatsPerBar) % beatsPerBar
            residueCounts[residue] += 1
        }

        var bestPhase = 0
        var bestScore = -Double.infinity
        for phase in 0..<beatsPerBar {
            var score = 0.0
            for residue in 0..<beatsPerBar {
                let beatInBar = ((residue - phase) % beatsPerBar + beatsPerBar) % beatsPerBar
                score += Double(residueCounts[residue]) * weights[beatInBar]
            }
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
        }
        return bestPhase
    }

    /// Returns the bar phase in `0..<beatsPerBar` whose beats carry the most rhythmic accent — the
    /// downbeat. `beatStrengths[i]` is the accent energy (e.g. drums + bass) at beat `i`. This is
    /// more reliable than vocal onsets when the singing enters at varied points in the bar (the
    /// kick/bass land on the downbeat regardless of where the vocal comes in). Returns 0 for
    /// degenerate input.
    static func barPhase(beatStrengths: [Double], beatsPerBar: Int = 4) -> Int {
        guard beatStrengths.count >= beatsPerBar, beatsPerBar > 0 else { return 0 }
        var best = 0
        var bestMean = -Double.infinity
        for phase in 0..<beatsPerBar {
            var sum = 0.0
            var n = 0
            var i = phase
            while i < beatStrengths.count {
                sum += beatStrengths[i]
                n += 1
                i += beatsPerBar
            }
            let mean = n > 0 ? sum / Double(n) : 0
            if mean > bestMean {
                bestMean = mean
                best = phase
            }
        }
        return best
    }

    /// How strongly a beat-strength profile favors ITS best downbeat phase over the bar average, in
    /// `0...1` (0 = flat/ambiguous, higher = a clear accented downbeat). Lets callers fall back to
    /// another cue when the accent signal is inconclusive.
    static func downbeatConfidence(beatStrengths: [Double], beatsPerBar: Int = 4) -> Double {
        guard beatStrengths.count >= beatsPerBar, beatsPerBar > 0 else { return 0 }
        let overall = beatStrengths.reduce(0, +) / Double(beatStrengths.count)
        guard overall > 0 else { return 0 }
        var bestMean = 0.0
        for phase in 0..<beatsPerBar {
            var sum = 0.0
            var n = 0
            var i = phase
            while i < beatStrengths.count {
                sum += beatStrengths[i]
                n += 1
                i += beatsPerBar
            }
            let mean = n > 0 ? sum / Double(n) : 0
            bestMean = max(bestMean, mean)
        }
        return min(max((bestMean - overall) / overall, 0), 1)
    }

    /// Estimates beats-per-bar from lyric-line onsets: successive line starts in a song with a
    /// steady phrase structure are spaced by whole bars, so the candidate bar length whose
    /// multiples best explain the onset spacings wins. Detects e.g. the 5-beat verse phrasing of
    /// a song whose tactus the beat tracker found at a 5:4 level — with a hard-coded 4/4 grid each
    /// line lands one beat later in the bar and the rendered lines cascade.
    ///
    /// Conservative: returns `preferred` (4) unless a challenger beats it by a clear margin.
    static func estimateBeatsPerBar(
        beatTimes: [TimeInterval],
        onsets: [TimeInterval],
        candidates: [Int] = [3, 4, 5, 6],
        preferred: Int = 4,
        margin: Double = 0.15
    ) -> Int {
        let beats = beatTimes.sorted()
        guard beats.count >= 8, onsets.count >= 4 else { return preferred }
        let grid = MeasureGrid(
            beatTimes: beats,
            bpm: 60.0 / max((beats.last! - beats.first!) / Double(beats.count - 1), 0.001)
        )
        let indices = onsets.sorted().map { grid.beatIndex(atTime: $0) }
        // Successive line spacings in beats, keeping phrase-scale gaps only (skip section breaks).
        var spacings: [Double] = []
        for i in 0..<(indices.count - 1) {
            let d = indices[i + 1] - indices[i]
            if d >= 2, d <= 12 { spacings.append(d) }
        }
        guard spacings.count >= 3 else { return preferred }

        func score(_ barBeats: Int) -> Double {
            let b = Double(barBeats)
            let total = spacings.reduce(0.0) { acc, d in
                let dist = abs(d - (d / b).rounded() * b)
                return acc + max(0, 1 - dist / 0.75)
            }
            return total / Double(spacings.count)
        }

        let preferredScore = score(preferred)
        var best = preferred
        var bestScore = preferredScore
        for candidate in candidates where candidate != preferred {
            let s = score(candidate)
            if s > bestScore, s >= preferredScore + margin {
                best = candidate
                bestScore = s
            }
        }
        return best
    }

    /// How tightly a set of onsets sits ON beat positions, in -1...1 (1 = every onset exactly
    /// on a beat, ~0 or below = onsets uncorrelated with the grid). Circular mean of
    /// cos(2π · distance-to-nearest-beat). Loosely performed songs (rubato vocal entrances)
    /// score low; a metric downbeat anchor then renders honest chaos, and the caller should
    /// fall back to first-word anchoring instead.
    static func beatAlignment(beatTimes: [TimeInterval], onsets: [TimeInterval]) -> Double {
        let beats = beatTimes.sorted()
        guard beats.count >= 2, !onsets.isEmpty else { return 0 }
        let bpm = 60.0 / max((beats.last! - beats.first!) / Double(beats.count - 1), 0.001)
        let grid = MeasureGrid(beatTimes: beats, bpm: bpm)
        let total = onsets.reduce(0.0) { acc, onset in
            let index = grid.beatIndex(atTime: onset)
            return acc + cos(2 * .pi * (index - index.rounded()))
        }
        return total / Double(onsets.count)
    }

    /// Index of the beat nearest to `time` in a sorted beat array.
    static func nearestBeatIndex(to time: TimeInterval, in sortedBeats: [TimeInterval]) -> Int {
        guard !sortedBeats.isEmpty else { return 0 }
        if time <= sortedBeats[0] { return 0 }
        if time >= sortedBeats[sortedBeats.count - 1] { return sortedBeats.count - 1 }
        var lo = 0
        var hi = sortedBeats.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if sortedBeats[mid] <= time { lo = mid } else { hi = mid }
        }
        return (time - sortedBeats[lo]) <= (sortedBeats[hi] - time) ? lo : hi
    }
}
