import Accelerate
import Foundation

/// The mel spectrogram the lyrics-alignment acoustic model was trained on.
///
/// This must reproduce `torchaudio.transforms.MelSpectrogram(sample_rate: 22050, n_mels: 128,
/// n_fft: 512)` exactly, defaults included, because the model learned those features and nothing
/// downstream can recover from feeding it different ones. The defaults that matter, and that are
/// easy to get wrong:
///
/// - **power, not log.** The transform returns magnitude squared. There is no `log`, no `log1p`
///   and no dB conversion anywhere in the training path.
/// - `hop = n_fft / 2 = 256`, `win = n_fft = 512`, periodic Hann.
/// - `center: true` with **reflect** padding, so frame `i` is centred on sample `i * hop` and the
///   frame count is `1 + samples / hop`.
/// - HTK mel scale, `norm: nil` — filters are NOT area-normalised (Slaney normalisation would
///   scale every band and silently change the input distribution).
/// - `f_min: 0`, `f_max: sampleRate / 2`.
///
/// With 128 mels over 257 FFT bins some filters come out all-zero, which torchaudio warns about.
/// That is reproduced deliberately: those dead bands are what the model saw in training.
enum LyricsAlignmentMel {
    static let sampleRate: Double = 22050
    static let fftSize = 512
    static let hop = 256
    static let melBands = 128

    private static let binCount = fftSize / 2 + 1  // 257

    /// `[frame][mel]` power values. Frame `i` is centred on sample `i * hop`.
    static func spectrogram(samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }

        // center: true — reflect-pad by half a window so the first frame is centred on sample 0.
        let pad = fftSize / 2
        let padded = reflectPadded(samples, by: pad)
        let frameCount = 1 + samples.count / hop

        let window = hannPeriodic(fftSize)
        let filterbank = melFilterbank()

        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var windowed = [Float](repeating: 0, count: fftSize)
        var power = [Float](repeating: 0, count: binCount)
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let offset = frame * hop
            guard offset + fftSize <= padded.count else { break }
            vDSP_vmul(
                Array(padded[offset..<(offset + fftSize)]), 1, window, 1, &windowed, 1,
                vDSP_Length(fftSize))

            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: fftSize / 2
                        ) { reinterpreted in
                            vDSP_ctoz(reinterpreted, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }

            // vDSP packs DC in realp[0] and Nyquist in imagp[0], and scales results by 2.
            power[0] = (real[0] * 0.5) * (real[0] * 0.5)
            power[binCount - 1] = (imaginary[0] * 0.5) * (imaginary[0] * 0.5)
            for bin in 1..<(fftSize / 2) {
                let re = real[bin] * 0.5
                let im = imaginary[bin] * 0.5
                power[bin] = re * re + im * im
            }

            var melRow = [Float](repeating: 0, count: melBands)
            for band in 0..<melBands {
                var sum: Float = 0
                vDSP_dotpr(power, 1, filterbank[band], 1, &sum, vDSP_Length(binCount))
                melRow[band] = sum
            }
            frames.append(melRow)
        }
        return frames
    }

    // MARK: - Pieces

    /// `torch.hann_window(n)` is PERIODIC: it divides by `n`, not `n - 1`.
    static func hannPeriodic(_ count: Int) -> [Float] {
        (0..<count).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(count)) }
    }

    static func reflectPadded(_ samples: [Float], by pad: Int) -> [Float] {
        guard pad > 0, samples.count > 1 else { return samples }
        var out = [Float]()
        out.reserveCapacity(samples.count + 2 * pad)
        // Reflect excludes the edge sample itself: [3,2,1] for a pad of 3 starting at index 0.
        for index in stride(from: pad, to: 0, by: -1) {
            out.append(samples[min(index, samples.count - 1)])
        }
        out += samples
        for index in 1...pad {
            out.append(samples[max(0, samples.count - 1 - index)])
        }
        return out
    }

    static func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
    static func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

    /// `[band][bin]`, matching torchaudio's `melscale_fbanks(..., norm: nil, mel_scale: .htk)`.
    static func melFilterbank() -> [[Float]] {
        let minimumMel = hzToMel(0)
        let maximumMel = hzToMel(sampleRate / 2)
        let points = (0..<(melBands + 2)).map { index -> Double in
            melToHz(minimumMel + (maximumMel - minimumMel) * Double(index) / Double(melBands + 1))
        }
        let binFrequencies = (0..<binCount).map { Double($0) * sampleRate / Double(fftSize) }

        var bank = [[Float]](repeating: [Float](repeating: 0, count: binCount), count: melBands)
        for band in 0..<melBands {
            let lower = points[band]
            let centre = points[band + 1]
            let upper = points[band + 2]
            for bin in 0..<binCount {
                let frequency = binFrequencies[bin]
                // Two slopes meeting at the centre; the filter is their minimum, clamped at zero.
                let rising = (frequency - lower) / max(centre - lower, .leastNormalMagnitude)
                let falling = (upper - frequency) / max(upper - centre, .leastNormalMagnitude)
                bank[band][bin] = Float(max(0, min(rising, falling)))
            }
        }
        return bank
    }
}
