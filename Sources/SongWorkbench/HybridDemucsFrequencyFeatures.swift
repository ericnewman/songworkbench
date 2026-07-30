import Accelerate
import Foundation

/// Frequency-branch features for Hybrid Demucs / DrumSep ONNX exports that expect a
/// precomputed complex spectrogram packed as `[1, 4, F, T]` (stereo real/imag).
///
/// Matches Meta Demucs `HTDemucs._spec` + `_magnitude` with `cac == true`:
/// n_fft 4096, hop 1024, normalized Hann STFT, reflect padding, drop Nyquist bin,
/// then pack channels as `[L_re, L_im, R_re, R_im]`.
enum HybridDemucsFrequencyFeatures: Sendable {
    static let nFFT = 4_096
    static let hopLength = 1_024
    static let frequencyBins = nFFT / 2  // after dropping Nyquist

    /// Returns planar magnitude/complex features shaped `[4][F][frames]`.
    static func complexChannelFeatures(
        left: [Float],
        right: [Float]
    ) throws -> [[[Float]]] {
        precondition(left.count == right.count)
        let leftSpec = try spectrogram(left)
        let rightSpec = try spectrogram(right)
        let frames = leftSpec.count
        let bins = frequencyBins
        precondition(rightSpec.count == frames)
        var features = Array(
            repeating: Array(
                repeating: [Float](repeating: 0, count: frames),
                count: bins
            ),
            count: 4
        )
        for frame in 0..<frames {
            precondition(leftSpec[frame].count == bins && rightSpec[frame].count == bins)
            for bin in 0..<bins {
                features[0][bin][frame] = leftSpec[frame][bin].real
                features[1][bin][frame] = leftSpec[frame][bin].imag
                features[2][bin][frame] = rightSpec[frame][bin].real
                features[3][bin][frame] = rightSpec[frame][bin].imag
            }
        }
        return features
    }

    /// Frame count after Demucs `_spec` trimming for an input of `sampleCount` samples.
    static func frameCount(forSampleCount sampleCount: Int) -> Int {
        Int(ceil(Double(sampleCount) / Double(hopLength)))
    }

    private struct ComplexBin {
        var real: Float
        var imag: Float
    }

    /// Demucs `_spec` for one mono channel: custom reflect pad, centered normalized STFT,
    /// drop last frequency bin, then keep frames `[2, 2 + le)`.
    private static func spectrogram(_ samples: [Float]) throws -> [[ComplexBin]] {
        let le = frameCount(forSampleCount: samples.count)
        let pad = hopLength / 2 * 3
        let rightPad = pad + le * hopLength - samples.count
        let padded = reflectPad(samples, left: pad, right: rightPad)
        let full = try centeredNormalizedSTFT(padded)
        // Drop Nyquist (`[..., :-1, :]`) then trim the 2-frame shoulder on each side.
        guard full.count == le + 4 else {
            throw CoreMLStemSeparationError.invalidPrediction
        }
        return Array(full[2..<(2 + le)]).map { frame in
            Array(frame.prefix(frequencyBins))
        }
    }

    private static func centeredNormalizedSTFT(_ samples: [Float]) throws -> [[ComplexBin]] {
        let window = hannWindow(nFFT)
        let windowNorm = sqrt(window.reduce(Float(0)) { $0 + $1 * $1 })
        guard windowNorm > 0 else { throw CoreMLStemSeparationError.invalidConfiguration }
        let centerPad = nFFT / 2
        let centered = reflectPad(samples, left: centerPad, right: centerPad)
        let frameCount = max(0, 1 + (centered.count - nFFT) / hopLength)
        var frames: [[ComplexBin]] = []
        frames.reserveCapacity(frameCount)
        var real = [Float](repeating: 0, count: nFFT)
        var imag = [Float](repeating: 0, count: nFFT)
        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw CoreMLStemSeparationError.invalidConfiguration
        }
        defer { vDSP_destroy_fftsetup(setup) }

        for frameIndex in 0..<frameCount {
            let start = frameIndex * hopLength
            for i in 0..<nFFT {
                real[i] = centered[start + i] * window[i] / windowNorm
                imag[i] = 0
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var local = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imagBuffer.baseAddress!
                    )
                    vDSP_fft_zip(setup, &local, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            let bins = nFFT / 2 + 1
            var frame = [ComplexBin](repeating: ComplexBin(real: 0, imag: 0), count: bins)
            for bin in 0..<bins {
                frame[bin] = ComplexBin(real: real[bin], imag: imag[bin])
            }
            frames.append(frame)
        }
        return frames
    }

    private static func hannWindow(_ length: Int) -> [Float] {
        (0..<length).map { index in
            let phase = 2 * Float.pi * Float(index) / Float(length - 1)
            return 0.5 - 0.5 * cos(phase)
        }
    }

    private static func reflectPad(_ samples: [Float], left: Int, right: Int) -> [Float] {
        guard !samples.isEmpty else {
            return [Float](repeating: 0, count: left + right)
        }
        if samples.count == 1 {
            return [Float](repeating: samples[0], count: left + 1 + right)
        }
        var output = [Float](repeating: 0, count: left + samples.count + right)
        for i in 0..<samples.count {
            output[left + i] = samples[i]
        }
        // Match NumPy/PyTorch reflect padding: mirror about the edge without duplicating it.
        for i in 0..<left {
            let source = reflectIndex(i - left, length: samples.count)
            output[i] = samples[source]
        }
        for i in 0..<right {
            let source = reflectIndex(samples.count + i, length: samples.count)
            output[left + samples.count + i] = samples[source]
        }
        return output
    }

    private static func reflectIndex(_ index: Int, length: Int) -> Int {
        var i = index
        let period = 2 * length - 2
        i %= period
        if i < 0 { i += period }
        return i <= length - 1 ? i : period - i
    }
}
