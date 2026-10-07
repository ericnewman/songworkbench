import Accelerate
import Foundation

/// The chord network's input: `librosa.cqt(y, sr: 22050, hop_length: 512, fmin: F#0, n_bins: 288,
/// bins_per_octave: 36, tuning: 0)` magnitudes, bins 18..<270. The published model was trained on
/// `hybrid_cqt` with estimated tuning; on 22 charted songs the full CQT at tuning 0 scores within
/// 0.01 F1 of it, and the cheaper pseudo-CQT 0.04 below (tools/chord_model_export).
///
/// librosa's recursive algorithm, octave by octave from the top: a 512-point rectangular-window
/// STFT (centred, zero padded) times one sparse constant-Q basis (`basis`, the same for every
/// octave), then the signal is halved in rate and the hop halved, so every octave has the same
/// frame times. Each bin is finally divided by the square root of its filter length.
enum ChordNetFeatures {
    static let sampleRate: Double = 22050
    static let hop = 512
    static let firstNetworkBin = 18
    static let networkBins = 252
    private static let fftSize = 512
    private static let binsPerOctave = 36
    private static let octaves = 8

    static var framesPerSecond: Double { sampleRate / Double(hop) }

    /// `[frame][252]`; frame `i` is centred on sample `i * 512` at 22,050 Hz.
    static func spectrogram(samples: [Float]) throws -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        let binCount = octaves * binsPerOctave
        var signal = samples
        var rate = sampleRate
        var octaveHop = hop
        var octaveResponses: [[[Float]]] = []
        for octave in 0..<octaves {
            // librosa rescales the basis by sqrt(sr / my_sr) to compensate for downsampling.
            octaveResponses.append(
                response(signal, hop: octaveHop, gain: Float(1 << octave).squareRoot()))
            guard octave < octaves - 1 else { break }
            // `librosa.resample(scale: true)` keeps the energy: halving the rate multiplies by √2.
            signal = try BasicPitchNoteTranscriber.resampled(signal, from: rate, to: rate / 2)
            vDSP.multiply(Float(2).squareRoot(), signal, result: &signal)
            rate /= 2
            octaveHop /= 2
        }
        let frameCount = octaveResponses.map(\.count).min() ?? 0
        let scale = filterLengths.map { 1 / $0.squareRoot() }
        return (0..<frameCount).map { frame in
            var row = [Float](repeating: 0, count: networkBins)
            for index in 0..<networkBins {
                let bin = firstNetworkBin + index
                // Octave 0 holds the top 36 bins.
                let octave = (binCount - 1 - bin) / binsPerOctave
                let within = bin - (binCount - (octave + 1) * binsPerOctave)
                row[index] = octaveResponses[octave][frame][within] * scale[bin]
            }
            return row
        }
    }

    /// `|basis · STFT|` for one octave: `[frame][36]`, frames centred on multiples of `hop`.
    private static func response(_ signal: [Float], hop: Int, gain: Float) -> [[Float]] {
        let half = fftSize / 2
        var padded = [Float](repeating: 0, count: half)
        padded += signal
        padded += [Float](repeating: 0, count: half)
        let frameCount = 1 + signal.count / hop
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        // vDSP's real FFT doubles its output.
        let fftScale = 0.5 * gain
        var real = [Float](repeating: 0, count: half + 1)
        var imaginary = [Float](repeating: 0, count: half + 1)
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let offset = frame * hop
            guard offset + fftSize <= padded.count else { break }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    padded.withUnsafeBufferPointer { source in
                        (source.baseAddress! + offset).withMemoryRebound(
                            to: DSPComplex.self, capacity: half
                        ) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP packs the Nyquist bin into imagp[0].
            real[half] = imaginary[0]
            imaginary[half] = 0
            imaginary[0] = 0
            var sumReal = [Float](repeating: 0, count: binsPerOctave)
            var sumImaginary = [Float](repeating: 0, count: binsPerOctave)
            for entry in basis {
                let x = real[entry.column]
                let y = imaginary[entry.column]
                sumReal[entry.row] += entry.real * x - entry.imaginary * y
                sumImaginary[entry.row] += entry.real * y + entry.imaginary * x
            }
            frames.append(
                (0..<binsPerOctave).map {
                    (sumReal[$0] * sumReal[$0] + sumImaginary[$0] * sumImaginary[$0]).squareRoot()
                        * fftScale
                })
        }
        return frames
    }
}
