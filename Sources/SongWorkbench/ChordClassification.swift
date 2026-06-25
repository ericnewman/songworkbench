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
    /// Template weight given to the chord root (third and fifth are 1). Weighting the
    /// root biases classification toward the chord whose root carries the most chroma
    /// energy — the bass/root note — which disambiguates triads that share two notes
    /// (e.g. Ab major vs C minor). Tunable for trial-and-error detection comparisons.
    var rootWeight: Float = 1.6

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
        values[root.rawValue] = rootWeight
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
    /// Root-weight passed to the classifier; tunable for trial-and-error comparisons.
    var rootWeight: Float = ChordClassifier().rootWeight

    func analyze(samples: [Float]) throws -> [ChordObservation] {
        let framer = MonoSampleFramer(configuration: configuration)
        let startIndices = framer.frameStartIndices(forSampleCount: samples.count)
        let frameCount = startIndices.count
        guard frameCount > 0 else { return [] }

        let spectrumAnalyzer = MagnitudeSpectrumAnalyzer()
        let chromaAnalyzer = ChromaAnalyzer()
        let classifier = ChordClassifier(rootWeight: rootWeight)
        let sampleRate = configuration.sampleRate

        // Partition the frame indices into N contiguous chunks. Each chunk builds exactly ONE DFT
        // transform and processes its frames serially, so a transform instance is never shared
        // across threads. Chunks run in parallel; results are written into a preallocated array so
        // the final order matches the serial order exactly.
        let chunkCount = min(
            max(ProcessInfo.processInfo.activeProcessorCount, 1),
            frameCount
        )
        let baseChunkSize = frameCount / chunkCount
        let remainder = frameCount % chunkCount

        // Preallocated result slots. Each slot is written exactly once by exactly one chunk, so the
        // concurrent writes never overlap and the final order matches the original serial order.
        let results = ResultBuffer(count: frameCount)
        // Holds the first error (cancellation or otherwise) seen by any chunk.
        let errorBox = ErrorBox()

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            if errorBox.hasError { return }

            // Compute this chunk's contiguous [lower, upper) range over the frame list. The first
            // `remainder` chunks get one extra frame so every frame is covered exactly once.
            let lower: Int
            let count: Int
            if chunk < remainder {
                lower = chunk * (baseChunkSize + 1)
                count = baseChunkSize + 1
            } else {
                lower = remainder * (baseChunkSize + 1) + (chunk - remainder) * baseChunkSize
                count = baseChunkSize
            }
            guard count > 0 else { return }
            let upper = lower + count

            do {
                // Exactly one transform per chunk (OPT A), reused serially within the chunk.
                let transform = try MagnitudeSpectrumAnalyzer.makeTransform(
                    frameLength: configuration.frameLength
                )
                for index in lower..<upper {
                    if errorBox.hasError { return }
                    try Task.checkCancellation()
                    let frame = framer.frame(from: samples, startIndex: startIndices[index])
                    let spectrum = try spectrumAnalyzer.analyze(
                        frame,
                        sampleRate: sampleRate,
                        transform: transform
                    )
                    let observation = classifier.classify(chromaAnalyzer.analyze(spectrum))
                    results.store(observation, at: index)
                }
            } catch {
                errorBox.record(error)
            }
        }

        if let error = errorBox.error {
            throw error
        }

        return results.finished()
    }
}

/// Fixed-size buffer of optional observations written from parallel chunks. Each index is written
/// exactly once by exactly one chunk, so the unsynchronized element writes do not race.
private final class ResultBuffer: @unchecked Sendable {
    private var storage: [ChordObservation?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func store(_ observation: ChordObservation, at index: Int) {
        storage[index] = observation
    }

    /// Returns the fully-populated array. Only call after all chunks have completed successfully.
    func finished() -> [ChordObservation] {
        storage.map { $0! }
    }
}

/// Thread-safe holder for the first error encountered across parallel chunks.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedError != nil
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if storedError == nil { storedError = error }
    }
}
