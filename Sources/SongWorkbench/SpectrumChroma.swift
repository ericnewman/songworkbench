import Accelerate
import Foundation

struct MagnitudeSpectrum: Equatable, Sendable {
    let timestamp: TimeInterval
    let binWidth: Double
    let magnitudes: [Float]
}

struct MagnitudeSpectrumAnalyzer: Sendable {
    /// Builds a forward complex-real DFT for the given frame length. The transform depends only on
    /// the frame length, so it can be created once and reused across frames of the same length.
    static func makeTransform(frameLength: Int) throws -> vDSP.DiscreteFourierTransform<Float> {
        try vDSP.DiscreteFourierTransform<Float>(
            count: frameLength,
            direction: .forward,
            transformType: .complexReal,
            ofType: Float.self
        )
    }

    func analyze(_ frame: AudioFrame, sampleRate: Double) throws -> MagnitudeSpectrum {
        try validate(frame, sampleRate: sampleRate)
        let transform = try Self.makeTransform(frameLength: frame.samples.count)
        return compute(frame, sampleRate: sampleRate, transform: transform)
    }

    /// Reusable-transform variant. The caller is responsible for supplying a transform whose
    /// `count` equals `frame.samples.count`. A single transform instance must NOT be shared across
    /// threads concurrently; reuse it only within one serial chunk.
    func analyze(
        _ frame: AudioFrame,
        sampleRate: Double,
        transform: vDSP.DiscreteFourierTransform<Float>
    ) throws -> MagnitudeSpectrum {
        try validate(frame, sampleRate: sampleRate)
        return compute(frame, sampleRate: sampleRate, transform: transform)
    }

    private func validate(_ frame: AudioFrame, sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioAnalysisError.invalidSampleRate
        }
        guard frame.samples.count >= 2 else {
            throw AudioAnalysisError.invalidFrameLength
        }

        guard frame.samples.count.isMultiple(of: 2) else {
            throw AudioAnalysisError.invalidFrameLength
        }
    }

    private func compute(
        _ frame: AudioFrame,
        sampleRate: Double,
        transform: vDSP.DiscreteFourierTransform<Float>
    ) -> MagnitudeSpectrum {
        let halfCount = frame.samples.count / 2
        var inputReal = [Float](repeating: 0, count: halfCount)
        var inputImaginary = [Float](repeating: 0, count: halfCount)
        frame.samples.withUnsafeBufferPointer { samples in
            for index in 0..<halfCount {
                inputReal[index] = samples[2 * index]
                inputImaginary[index] = samples[2 * index + 1]
            }
        }
        let output = transform.transform(real: inputReal, imaginary: inputImaginary)
        var real = output.real
        var imaginary = output.imaginary
        var squaredMagnitudes = Array(repeating: Float.zero, count: halfCount)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                let splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP.squareMagnitudes(splitComplex, result: &squaredMagnitudes)
            }
        }

        var magnitudes = squaredMagnitudes.map { sqrt($0) }
        magnitudes[0] = abs(real[0])
        magnitudes.append(abs(imaginary[0]))

        return MagnitudeSpectrum(
            timestamp: frame.timestamp,
            binWidth: sampleRate / Double(frame.samples.count),
            magnitudes: magnitudes
        )
    }
}

enum PitchClass: Int, CaseIterable, Codable, Sendable {
    case c
    case cSharp
    case d
    case dSharp
    case e
    case f
    case fSharp
    case g
    case gSharp
    case a
    case aSharp
    case b
}

struct ChromaVector: Equatable, Sendable {
    let timestamp: TimeInterval
    let values: [Float]

    init(timestamp: TimeInterval, values: [Float]) {
        precondition(values.count == PitchClass.allCases.count)
        self.timestamp = timestamp
        self.values = values
    }
}

struct ChromaAnalyzer: Sendable {
    let minimumFrequency: Double

    init(minimumFrequency: Double = 32.7) {
        self.minimumFrequency = minimumFrequency
    }

    func analyze(_ spectrum: MagnitudeSpectrum) -> ChromaVector {
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)

        for bin in spectrum.magnitudes.indices.dropFirst() {
            let frequency = Double(bin) * spectrum.binWidth
            guard frequency >= minimumFrequency else { continue }

            let midiNote = Int((69 + 12 * log2(frequency / 440)).rounded())
            let pitchClass = ((midiNote % values.count) + values.count) % values.count
            values[pitchClass] += spectrum.magnitudes[bin]
        }

        let total = vDSP.sum(values)
        if total > 0 {
            values = vDSP.divide(values, total)
        }
        return ChromaVector(timestamp: spectrum.timestamp, values: values)
    }
}
