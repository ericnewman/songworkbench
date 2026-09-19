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
