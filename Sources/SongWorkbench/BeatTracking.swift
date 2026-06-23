import Accelerate
import Foundation

struct BeatEstimate: Codable, Equatable, Sendable {
    let bpm: Double
    let beatTimes: [TimeInterval]
    let confidence: Float
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
