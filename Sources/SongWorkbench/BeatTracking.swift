import Accelerate
import Foundation

struct BeatEstimate: Codable, Equatable, Sendable {
    let bpm: Double
    let beatTimes: [TimeInterval]
    let confidence: Float
}

/// Builds a metronome grid whose phase follows drum onsets while its tempo stays rigid. A kick can
/// establish the pulse even when it only sounds every second or fourth beat; it must never pull an
/// individual click early or late. Pure & deterministic — no I/O.
enum DrumBeatGrid {
    /// Returns a phase-locked, constant-period beat grid.
    ///
    /// - Keeps the supplied tempo (`bpm`) as the spacing prior.
    /// - PHASE: picks the grid offset φ in `[0, interval)` whose uniform grid best lines up with the
    ///   onsets, via a histogram of each onset's residual `onset mod interval` (densest bin, refined
    ///   to that bin's mean).
    /// - TEMPO: every returned beat is exactly `60 / bpm` seconds after the preceding one. Onsets
    ///   are phase evidence only — this remains correct when a kick marks a metrical multiple.
    /// - Result starts with the first grid point near the drum entrance and remains within
    ///   `[0, duration]`.
    ///
    /// Degenerate input (`bpm <= 0`, no onsets, or `duration <= 0`) returns `[]`.
    static func beatTimes(
        onsets: [TimeInterval],
        bpm: Double,
        duration: TimeInterval
    ) -> [TimeInterval] {
        guard bpm > 0, !onsets.isEmpty, duration > 0 else { return [] }
        let interval = 60 / bpm
        guard interval > 0 else { return [] }

        let phase = bestPhase(onsets: onsets, interval: interval)

        // Keep the same late-start policy as the former onset-snapped grid: no beat is invented
        // far ahead of the first drum hit. Once it starts, index arithmetic keeps every interval
        // exactly rigid (and avoids accumulated addition drift).
        let tolerance = interval * 0.25
        let sortedOnsets = onsets.sorted()
        let firstBeat = (sortedOnsets.first ?? 0) - tolerance
        let firstIndex = Int(ceil((max(firstBeat, 0) - phase) / interval))
        let lastIndex = Int(floor((duration - phase) / interval))
        guard lastIndex >= firstIndex else { return [] }
        return (firstIndex...lastIndex).map { phase + Double($0) * interval }
    }

    /// Resolves the tracker's tempo past its autocorrelation-lag quantization.
    ///
    /// `BeatTracker` reports `60 * envelopeRate / lag` for an INTEGER lag, so at hop 512 / 44.1 kHz
    /// every tempo is `5168 / n`: 87.59, 99.38, 112.35… One lag step is ~2 % at 112 BPM. A rigid
    /// grid needs ~0.02 % to stay on the drums for four minutes; at the quantized tempo it rotates
    /// through whole beats instead. Measured 2026-09-19 on 16 library songs: none held its drums
    /// (section-to-section spread 101–244 ms), and the onsets' coherence with the stored grid was
    /// ≤ 0.034 — no better than random.
    ///
    /// The onsets span the whole song, so they resolve the period far more finely than the lag
    /// does: the candidate whose beat, eighth and sixteenth grids the onsets agree with most
    /// (mean resultant length) is the tempo. The grid stays rigid and at the same metrical level —
    /// the search covers ±2 lag steps only.
    ///
    /// Returns `bpm` unchanged when no rigid tempo fits (a performance whose tempo drifts): on the
    /// same songs every lockable one reached coherence ≥ 0.094 and every drifting one ≤ 0.068.
    static func refinedBPM(
        onsets: [TimeInterval],
        bpm: Double,
        lagStep: TimeInterval = 512.0 / 44_100,
        minimumCoherence: Double = 0.08
    ) -> Double {
        guard bpm > 0, lagStep > 0, onsets.count >= 32 else { return bpm }
        let prior = 60 / bpm
        let lowest = prior - 2 * lagStep
        guard lowest > 0 else { return bpm }
        // ponytail: one exhaustive pass, ~2,300 candidates x 3 harmonics x onsets (~20M trig calls,
        // well under a second optimized). Go coarse-to-fine if this ever shows up in a profile.
        let step = 0.000_02
        let candidateCount = Int((4 * lagStep / step).rounded(.down))
        var bestCoherence = 0.0
        var bestInterval = prior
        for index in 0...candidateCount {
            let interval = lowest + Double(index) * step
            var total = 0.0
            for harmonic in [1.0, 2.0, 4.0] {
                let angular = 2 * Double.pi * harmonic / interval
                var x = 0.0
                var y = 0.0
                for onset in onsets {
                    x += cos(angular * onset)
                    y += sin(angular * onset)
                }
                total += (x * x + y * y).squareRoot()
            }
            let coherence = total / (3 * Double(onsets.count))
            if coherence > bestCoherence {
                bestCoherence = coherence
                bestInterval = interval
            }
        }
        // Chance coherence falls as 1/sqrt(N), and the best of thousands of candidates sits well
        // above the mean, so a sparse (kick-only) stem needs a higher bar than the ~1,000–1,700
        // onset stems the floor was calibrated on. 3/sqrt(N) meets the floor at N ≈ 1,400.
        let required = max(minimumCoherence, 3 / Double(onsets.count).squareRoot())
        return bestCoherence >= required ? 60 / bestInterval : bpm
    }

    // MARK: - Following a drummer whose tempo drifts

    /// The share of on-grid onsets a followed grid must gain over the rigid one — on all the
    /// onsets AND on onsets the fit never saw. Measured 2026-09-21 on the 39 library songs, on the
    /// onsets the stage itself uses: the four that truly drift gained 29–43 points on both; no
    /// other song passed 18 on both, and several LOST points on the held-out half.
    static let minimumFollowGain = 0.25

    /// A grid that follows the drummer, or nil when the rigid grid should stay.
    ///
    /// Some performances fit no rigid tempo (`refinedBPM` returns its input). Following them is
    /// dangerous: a tracker free to move will chase noise, which is why the grid went rigid
    /// (2026-09-14, "a hit can no longer pull an individual beat early or late"). So the followed
    /// grid stays rigid in 16-beat stretches, re-fitted every 4 beats, and it must EARN its place:
    /// fitted on every other onset, it has to land the held-out onsets on the grid far more often
    /// than the rigid grid does. Real drift generalizes to unseen hits; chased noise does not.
    static func followedBeatTimes(onsets: [TimeInterval], rigid: [TimeInterval])
        -> [TimeInterval]?
    {
        let sorted = onsets.sorted()
        guard rigid.count >= 8, sorted.count >= 64 else { return nil }
        let followed = follow(onsets: sorted, rigid: rigid)
        let gain = onGridShare(sorted, beats: followed) - onGridShare(sorted, beats: rigid)
        guard gain >= minimumFollowGain else { return nil }
        let fitted = stride(from: 0, to: sorted.count, by: 2).map { sorted[$0] }
        let heldOut = stride(from: 1, to: sorted.count, by: 2).map { sorted[$0] }
        let heldOutGain =
            onGridShare(heldOut, beats: follow(onsets: fitted, rigid: rigid))
            - onGridShare(heldOut, beats: rigid)
        return heldOutGain >= minimumFollowGain ? followed : nil
    }

    /// Walks the song four beats at a time, re-fitting period (±2 %) and phase (± an eighth of a
    /// beat) to the onsets of the next 16 beats. A stretch with too few onsets, or too little
    /// agreement, keeps the tempo it arrived with.
    static func follow(onsets: [TimeInterval], rigid: [TimeInterval]) -> [TimeInterval] {
        guard rigid.count >= 2, let end = rigid.last else { return rigid }
        let prior = rigid[1] - rigid[0]
        guard prior > 0 else { return rigid }
        var beats: [TimeInterval] = []
        var start = rigid[0]
        var period = prior
        while start < end {
            let window = onsets.filter { $0 >= start - period && $0 < start + 16 * period }
            if window.count >= 6 {
                var best = (
                    score: coherence(window, from: start, period: period), shift: 0.0,
                    period: period
                )
                for periodStep in -10...10 {
                    let candidate = period * (1 + 0.002 * Double(periodStep))
                    var shift = -period / 8
                    while shift <= period / 8 {
                        // A small cost on moving at all, so a tie keeps the grid where it is.
                        let score =
                            coherence(window, from: start + shift, period: candidate)
                            - 0.015 * abs(shift) / (period / 8) - 0.01 * abs(Double(periodStep))
                            / 10
                        if score > best.score { best = (score, shift, candidate) }
                        shift += 0.004
                    }
                }
                if best.score >= 0.15, abs(best.period / prior - 1) <= 0.08 {
                    start += best.shift
                    period = best.period
                }
            }
            for index in 0..<4 { beats.append(start + Double(index) * period) }
            start += 4 * period
        }
        return smoothed(beats.filter { $0 <= end }, first: rigid[0], period: prior)
    }

    /// Each re-fit may shift the phase by up to an eighth of a beat, which is a hit pulling a
    /// beat. A drummer's drift is slow, so only the slow part is kept: each beat's departure from
    /// the rigid grid becomes a Hann-weighted average over 8 beats either side. Measured
    /// 2026-09-21: the largest change between neighbouring beat lengths fell from 41–94 ms to
    /// 2–5 ms, and the songs that truly drift kept their gain.
    private static func smoothed(
        _ beats: [TimeInterval], first: TimeInterval, period: TimeInterval, reach: Int = 8
    ) -> [TimeInterval] {
        guard beats.count > 1 else { return beats }
        let rigid = beats.indices.map { first + Double($0) * period }
        let drift = zip(beats, rigid).map { $0 - $1 }
        let weights = (-reach...reach).map {
            0.5 + 0.5 * cos(Double.pi * Double($0) / Double(reach + 1))
        }
        let total = weights.reduce(0, +)
        return beats.indices.map { index in
            var sum = 0.0
            for (offset, weight) in zip(-reach...reach, weights) {
                sum += weight * drift[min(max(index + offset, 0), drift.count - 1)]
            }
            return rigid[index] + sum / total
        }
    }

    /// How well `onsets` agree with the beat, eighth and sixteenth grids counted from `start`.
    private static func coherence(
        _ onsets: [TimeInterval], from start: TimeInterval, period: TimeInterval
    ) -> Double {
        guard !onsets.isEmpty, period > 0 else { return 0 }
        var total = 0.0
        for harmonic in [1.0, 2.0, 4.0] {
            let angular = 2 * Double.pi * harmonic / period
            for onset in onsets { total += cos(angular * (onset - start)) }
        }
        return total / (3 * Double(onsets.count))
    }

    /// The share of onsets within 30 ms of the sixteenth-note grid drawn between `beats`.
    static func onGridShare(_ onsets: [TimeInterval], beats: [TimeInterval]) -> Double {
        guard beats.count >= 2, let first = beats.first, let last = beats.last else { return 0 }
        let inside = onsets.filter { $0 >= first && $0 <= last }
        guard !inside.isEmpty else { return 0 }
        var beat = 0
        var hits = 0
        for onset in inside {
            while beat + 2 < beats.count, beats[beat + 1] <= onset { beat += 1 }
            let sixteenth = (beats[beat + 1] - beats[beat]) / 4
            guard sixteenth > 0 else { continue }
            let offset = (onset - beats[beat]).truncatingRemainder(dividingBy: sixteenth)
            if min(offset, sixteenth - offset) <= 0.03 { hits += 1 }
        }
        return Double(hits) / Double(inside.count)
    }

    /// Chooses the phase offset φ in `[0, interval)` that best aligns a uniform grid to the onsets.
    /// Histograms each onset's residual (`onset mod interval`) into a handful of bins, picks the
    /// densest bin, and refines φ to the mean of the residuals that fell in it (handling wrap-around
    /// at the `interval`/`0` seam so a cluster straddling it is not split).
    private static func bestPhase(onsets: [TimeInterval], interval: Double) -> Double {
        let residuals: [Double] = onsets.map { onset in
            var r = onset.truncatingRemainder(dividingBy: interval)
            if r < 0 { r += interval }
            return r
        }
        guard !residuals.isEmpty else { return 0 }

        let binCount = 12
        let binWidth = interval / Double(binCount)
        guard binWidth > 0 else { return residuals.first ?? 0 }
        var counts = [Int](repeating: 0, count: binCount)
        for r in residuals {
            var bin = Int(r / binWidth)
            if bin >= binCount { bin = binCount - 1 }
            if bin < 0 { bin = 0 }
            counts[bin] += 1
        }
        let densestBin = counts.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0

        // Center of the densest bin; refine φ to the mean of residuals within half a bin of it,
        // measuring distance circularly so a cluster spanning the 0/interval seam stays together.
        let binCenter = (Double(densestBin) + 0.5) * binWidth
        var sumX = 0.0
        var sumY = 0.0
        var members = 0
        let half = binWidth * 0.5
        for r in residuals {
            let raw = abs(r - binCenter)
            let circular = min(raw, interval - raw)
            if circular <= half + 1e-9 {
                // Average on the circle to avoid the seam-split bias.
                let angle = (r / interval) * 2 * Double.pi
                sumX += cos(angle)
                sumY += sin(angle)
                members += 1
            }
        }
        guard members > 0 else { return binCenter }
        var phase = atan2(sumY, sumX) / (2 * Double.pi) * interval
        if phase < 0 { phase += interval }
        if phase >= interval { phase -= interval }
        return phase
    }

}

struct BeatTracker: Sendable {
    let minimumBPM: Double
    let maximumBPM: Double
    let frameLength: Int
    let hopLength: Int

    init(
        minimumBPM: Double = 60,
        maximumBPM: Double = 180,
        frameLength: Int = 1_024,
        hopLength: Int = 512
    ) {
        self.minimumBPM = minimumBPM
        self.maximumBPM = maximumBPM
        self.frameLength = frameLength
        self.hopLength = hopLength
    }

    func analyze(samples: [Float], sampleRate: Double) -> BeatEstimate? {
        guard sampleRate > 0, samples.count >= frameLength * 2 else { return nil }
        let envelope = onsetEnvelope(samples: samples)
        guard envelope.contains(where: { $0 > 0 }) else { return nil }

        let envelopeRate = sampleRate / Double(hopLength)
        let minimumLag = max(Int((60 / maximumBPM) * envelopeRate), 1)
        let maximumLag = min(Int((60 / minimumBPM) * envelopeRate), envelope.count - 1)
        guard maximumLag >= minimumLag else { return nil }

        var bestLag = minimumLag
        var bestScore: Float = -.infinity
        var bestRawScore: Float = 0
        var totalScore: Float = 0
        let envelopeCount = envelope.count
        envelope.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for lag in minimumLag...maximumLag {
                // Dot of envelope[0..<count-lag] with envelope[lag..<count] — same elements and
                // order as the previous Array(dropLast)/Array(dropFirst) pair, no copies.
                let pairCount = envelopeCount - lag
                let lhs = UnsafeBufferPointer(start: base, count: pairCount)
                let rhs = UnsafeBufferPointer(start: base + lag, count: pairCount)
                let score = max(vDSP.dot(lhs, rhs), 0)
                totalScore += score
                let bpm = 60 * envelopeRate / Double(lag)
                let octaveDistance = log2(bpm / 105)
                let pulsePreference = exp(-0.5 * pow(octaveDistance / 0.6, 2))
                let weightedScore = score * Float(pulsePreference)
                if weightedScore > bestScore {
                    bestScore = weightedScore
                    bestRawScore = score
                    bestLag = lag
                }
            }
        }

        let bpm = 60 * envelopeRate / Double(bestLag)
        let strongestOnset = envelope.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let firstBeat = Double(strongestOnset * hopLength) / sampleRate
        let interval = 60 / bpm
        let duration = Double(samples.count) / sampleRate
        var beatTimes: [TimeInterval] = []
        var time = firstBeat
        while time - interval >= 0 { time -= interval }
        while time <= duration {
            beatTimes.append(time)
            time += interval
        }

        return BeatEstimate(
            bpm: bpm,
            beatTimes: beatTimes,
            confidence: totalScore > 0 ? bestRawScore / totalScore : 0
        )
    }

    private func onsetEnvelope(samples: [Float]) -> [Float] {
        let starts = stride(
            from: 0,
            through: samples.count - frameLength,
            by: hopLength
        )
        let energies = starts.map { start -> Float in
            let frame = Array(samples[start..<(start + frameLength)])
            return vDSP.rootMeanSquare(frame)
        }
        var previous: Float = 0
        return energies.map { energy in
            defer { previous = energy }
            return max(energy - previous, 0)
        }
    }
}
