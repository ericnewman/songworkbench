import Accelerate
import Foundation

enum ChordQuality: String, Codable, Equatable, Sendable {
    case major
    case minor
}

struct Chord: Codable, Equatable, Sendable {
    let root: PitchClass
    let quality: ChordQuality
}

struct ChordObservation: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let chord: Chord
    let confidence: Float
}

struct ChordClassifier: Sendable {
    func classify(_ chroma: ChromaVector) -> ChordObservation {
        var bestChord = Chord(root: .c, quality: .major)
        var bestScore = Float.zero

        for root in PitchClass.allCases {
            for quality in [ChordQuality.major, .minor] {
                let score = cosineSimilarity(
                    chroma.values,
                    template(root: root, quality: quality)
                )
                if score > bestScore {
                    bestScore = score
                    bestChord = Chord(root: root, quality: quality)
                }
            }
        }

        return ChordObservation(
            timestamp: chroma.timestamp,
            chord: bestChord,
            confidence: bestScore
        )
    }

    private func template(root: PitchClass, quality: ChordQuality) -> [Float] {
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        let third = quality == .major ? 4 : 3
        values[root.rawValue] = 1
        values[(root.rawValue + third) % values.count] = 1
        values[(root.rawValue + 7) % values.count] = 1
        return values
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let denominator = sqrt(vDSP.sumOfSquares(lhs) * vDSP.sumOfSquares(rhs))
        guard denominator > 0 else { return 0 }
        return vDSP.dot(lhs, rhs) / denominator
    }
}

struct ChordAnalysisPipeline: Sendable {
    let configuration: AudioAnalysisConfiguration

    func analyze(samples: [Float]) throws -> [ChordObservation] {
        let spectrumAnalyzer = MagnitudeSpectrumAnalyzer()
        let chromaAnalyzer = ChromaAnalyzer()
        let classifier = ChordClassifier()
        let framer = MonoSampleFramer(configuration: configuration)
        var observations: [ChordObservation] = []
        for startIndex in framer.frameStartIndices(forSampleCount: samples.count) {
            try Task.checkCancellation()
            let spectrum = try spectrumAnalyzer.analyze(
                framer.frame(from: samples, startIndex: startIndex),
                sampleRate: configuration.sampleRate
            )
            observations.append(classifier.classify(chromaAnalyzer.analyze(spectrum)))
        }
        return observations
    }
}
