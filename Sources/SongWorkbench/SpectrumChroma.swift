import Accelerate
import Foundation

struct MagnitudeSpectrum: Equatable, Sendable {
    let timestamp: TimeInterval
    let binWidth: Double
    let magnitudes: [Float]
}

struct MagnitudeSpectrumAnalyzer: Sendable {
    func analyze(_ frame: AudioFrame, sampleRate: Double) throws -> MagnitudeSpectrum {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioAnalysisError.invalidSampleRate
        }
        guard frame.samples.count >= 2 else {
            throw AudioAnalysisError.invalidFrameLength
        }

        guard frame.samples.count.isMultiple(of: 2) else {
            throw AudioAnalysisError.invalidFrameLength
        }

        let transform = try vDSP.DiscreteFourierTransform<Float>(
            count: frame.samples.count,
            direction: .forward,
            transformType: .complexReal,
            ofType: Float.self
        )
        let halfCount = frame.samples.count / 2
        let inputReal = stride(from: 0, to: frame.samples.count, by: 2).map {
            frame.samples[$0]
        }
        let inputImaginary = stride(from: 1, to: frame.samples.count, by: 2).map {
            frame.samples[$0]
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
