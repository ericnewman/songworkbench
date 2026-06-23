import Accelerate
import Foundation

enum AudioAnalysisError: Error, Equatable, Sendable {
    case invalidSampleRate
    case invalidFrameLength
    case invalidHopLength
    case inconsistentFrameLength(expected: Int, actual: Int)
}

struct AudioAnalysisConfiguration: Equatable, Sendable {
    let sampleRate: Double
    let frameLength: Int
    let hopLength: Int

    init(sampleRate: Double, frameLength: Int, hopLength: Int) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioAnalysisError.invalidSampleRate
        }
        guard frameLength >= 2 else {
            throw AudioAnalysisError.invalidFrameLength
        }
        guard hopLength > 0 else {
            throw AudioAnalysisError.invalidHopLength
        }

        self.sampleRate = sampleRate
        self.frameLength = frameLength
        self.hopLength = hopLength
    }
}

struct AudioFrame: Equatable, Sendable {
    let timestamp: TimeInterval
    let samples: [Float]
}

struct MonoSampleFramer: Sendable {
    let configuration: AudioAnalysisConfiguration
    private let window: [Float]

    init(configuration: AudioAnalysisConfiguration) {
        self.configuration = configuration
        self.window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: configuration.frameLength,
            isHalfWindow: false
        )
    }

    init(frameLength: Int, hopLength: Int, sampleRate: Double) throws {
        self.init(
            configuration: try AudioAnalysisConfiguration(
                sampleRate: sampleRate,
                frameLength: frameLength,
                hopLength: hopLength
            ))
    }

    func frames(from samples: [Float]) -> [AudioFrame] {
        frameStartIndices(forSampleCount: samples.count).map {
            frame(from: samples, startIndex: $0)
        }
    }

    func frameStartIndices(forSampleCount sampleCount: Int) -> [Int] {
        guard sampleCount >= configuration.frameLength else { return [] }
        return Array(
            stride(
                from: 0,
                through: sampleCount - configuration.frameLength,
                by: configuration.hopLength
            ))
    }

    func frame(from samples: [Float], startIndex: Int) -> AudioFrame {
        precondition(startIndex >= 0)
        precondition(startIndex + configuration.frameLength <= samples.count)
        let frameSamples = Array(samples[startIndex..<(startIndex + configuration.frameLength)])
        return AudioFrame(
            timestamp: TimeInterval(startIndex) / configuration.sampleRate,
            samples: vDSP.multiply(frameSamples, window)
        )
    }
}
