import Accelerate
import CoreML
import Foundation

/// A song's beats and bar grid from the bundled beat_this model.
struct ModelBeatGrid: Equatable, Sendable {
    var bpm: Double
    var beatTimes: [TimeInterval]
    var barGrid: SongBarGrid
}

/// Measures a recording's beat grid. The pipeline injects it so tests, which have no app bundle,
/// can run without the model.
typealias BeatGridMeasurer = @Sendable (_ recordingURL: URL) throws -> ModelBeatGrid

/// Beats and downbeats from beat_this (CPJKU, MIT), converted to Core ML by
/// `tools/beat_this_export/export_coreml.py`, which checks it against PyTorch (probabilities
/// within 0.005; every reference beat peak kept).
///
/// Eric, 2026-10-06: the autocorrelation `BeatTracker` picked 4/3 or 2x the real tempo on 8 of 14
/// album tracks (Doc Holiday 103.4 BPM against the 77 he counts), so every measure was drawn in the
/// wrong place and lyrics looked crammed into the end of a bar. beat_this, decoded at ONE tempo
/// level for the whole song (`BeatThisDecoder`), gave his counts: Doc Holiday 77.0, Key West Bar
/// 93.6. Its own peak picking switched levels mid-song (Key West Bar: half at 94, half at 188).
enum BeatThisTracker {
    private static let resourceName = "BeatThis"
    /// Frames per model evaluation: 30 s at 50 frames per second, fixed at conversion time.
    static let chunkFrames = 1500
    /// Frames discarded at each chunk edge, where the model was not trained (beat_this's
    /// `split_piece`); consecutive chunks overlap by this much.
    static let borderFrames = 6

    static var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "mlpackage")
    }

    /// The bundled model on the recording. Throws when the model is missing: the app does not
    /// analyze without its models (Eric, 2026-09-26).
    @Sendable
    static func measuredWithBundledModel(_ recordingURL: URL) throws -> ModelBeatGrid {
        guard let url = bundledURL,
            let model = try? MLModel(contentsOf: MLModel.compileModel(at: url))
        else { throw SongAnalysisPipelineError.missingBundledModel(resourceName) }
        let samples = try MeasuredLyricTiming.monoSamples(
            at: recordingURL, sampleRate: BeatThisMel.sampleRate)
        let (beat, downbeat) = try probabilities(
            spectrogram: BeatThisMel.spectrogram(samples: samples), model: model)
        guard let grid = BeatThisDecoder.decode(beat: beat, downbeat: downbeat) else {
            throw BeatThisDecoder.Failure.noPulse
        }
        return grid
    }

    /// Frame-wise beat and downbeat probabilities for a whole song, assembled from overlapping
    /// chunks exactly as beat_this's `split_predict_aggregate` with `keep_first`.
    static func probabilities(spectrogram: [[Float]], model: MLModel) throws -> ([Float], [Float]) {
        let frames = spectrogram.count
        var beat = [Float](repeating: 0, count: frames)
        var downbeat = [Float](repeating: 0, count: frames)
        // Later chunks first, so an earlier chunk's prediction wins where they overlap.
        for start in chunkStarts(frameCount: frames).reversed() {
            let (chunkBeat, chunkDownbeat) = try predict(
                chunk: start, spectrogram: spectrogram, model: model)
            let kept =
                max(start + borderFrames, 0)..<min(start + chunkFrames - borderFrames, frames)
            for frame in kept {
                beat[frame] = chunkBeat[frame - start]
                downbeat[frame] = chunkDownbeat[frame - start]
            }
        }
        return (beat, downbeat)
    }

    /// beat_this's `split_piece`: chunks step by `chunkFrames - 2 * borderFrames` from
    /// `-borderFrames`, and the last one is pulled back to end at the end of the song.
    static func chunkStarts(frameCount: Int) -> [Int] {
        let step = chunkFrames - 2 * borderFrames
        var starts = Array(stride(from: -borderFrames, to: frameCount - borderFrames, by: step))
        if frameCount > step, !starts.isEmpty {
            starts[starts.count - 1] = frameCount - (chunkFrames - borderFrames)
        }
        return starts
    }

    private static func predict(chunk start: Int, spectrogram: [[Float]], model: MLModel) throws
        -> ([Float], [Float])
    {
        let bands = BeatThisMel.melBands
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: chunkFrames), NSNumber(value: bands)], dataType: .float32)
        // Through the array's own strides: Core ML may pad rows.
        let frameStride = input.strides[1].intValue
        let bandStride = input.strides[2].intValue
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        for offset in 0..<chunkFrames {
            let frame = start + offset
            let row = spectrogram.indices.contains(frame) ? spectrogram[frame] : nil
            for band in 0..<bands {
                // Outside the song is zero padding, as in beat_this's `zeropad`.
                pointer[offset * frameStride + band * bandStride] = row?[band] ?? 0
            }
        }
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["spect": input]))
        guard let beat = output.featureValue(for: "beat")?.multiArrayValue,
            let downbeat = output.featureValue(for: "downbeat")?.multiArrayValue
        else { throw BeatThisDecoder.Failure.unexpectedModelOutput }
        return (values(beat), values(downbeat))
    }

    /// By index rather than raw pointer: the output's element type and strides are Core ML's call.
    private static func values(_ array: MLMultiArray) -> [Float] {
        (0..<chunkFrames).map { array[[0, NSNumber(value: $0)]].floatValue }
    }
}

/// The log-mel spectrogram beat_this was trained on: `beat_this.preprocessing.LogMelSpect`, i.e.
/// torchaudio `MelSpectrogram(sample_rate: 22050, n_fft: 1024, hop_length: 441, f_min: 30,
/// f_max: 11000, n_mels: 128, mel_scale: "slaney", normalized: "frame_length", power: 1)` and then
/// `log1p(1000 * x)`. The details that matter: magnitude (power 1), the STFT scaled by
/// `1 / sqrt(n_fft)` ("frame_length"), centred frames with reflect padding, a periodic Hann window,
/// Slaney mel points with NO area normalisation.
enum BeatThisMel {
    static let sampleRate: Double = 22050
    static let fftSize = 1024
    static let hop = 441
    static let melBands = 128
    static let framesPerSecond = sampleRate / Double(hop)
    private static let binCount = fftSize / 2 + 1

    /// `[frame][band]`; frame `i` is centred on sample `i * hop`.
    static func spectrogram(samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        let padded = LyricsAlignmentMel.reflectPadded(samples, by: fftSize / 2)
        let frameCount = 1 + samples.count / hop
        let window = LyricsAlignmentMel.hannPeriodic(fftSize)
        let filterbank = melFilterbank()
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        // vDSP's real FFT doubles its output; frame_length normalisation divides by sqrt(n_fft).
        let scale = 0.5 / Float(fftSize).squareRoot()

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var windowed = [Float](repeating: 0, count: fftSize)
        var magnitude = [Float](repeating: 0, count: binCount)
        var frames: [[Float]] = []
        frames.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let offset = frame * hop
            guard offset + fftSize <= padded.count else { break }
            padded.withUnsafeBufferPointer { source in
                vDSP_vmul(
                    source.baseAddress! + offset, 1, window, 1, &windowed, 1,
                    vDSP_Length(fftSize))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: fftSize / 2
                        ) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP packs DC in realp[0] and Nyquist in imagp[0].
            magnitude[0] = abs(real[0]) * scale
            magnitude[binCount - 1] = abs(imaginary[0]) * scale
            for bin in 1..<(fftSize / 2) {
                magnitude[bin] =
                    (real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
                    .squareRoot() * scale
            }
            frames.append(
                filterbank.map { band in
                    var sum: Float = 0
                    vDSP_dotpr(magnitude, 1, band, 1, &sum, vDSP_Length(binCount))
                    return log1p(1000 * sum)
                })
        }
        return frames
    }

    /// torchaudio's Slaney mel scale: linear below 1 kHz, logarithmic above.
    static func hzToMel(_ hz: Double) -> Double {
        hz < 1000 ? hz / (200.0 / 3) : 15 + log(hz / 1000) / (log(6.4) / 27)
    }

    static func melToHz(_ mel: Double) -> Double {
        mel < 15 ? mel * 200.0 / 3 : 1000 * exp((log(6.4) / 27) * (mel - 15))
    }

    /// `[band][bin]`, matching `melscale_fbanks(513, 30, 11000, 128, 22050, norm: nil,
    /// mel_scale: "slaney")`.
    static func melFilterbank() -> [[Float]] {
        let low = hzToMel(30)
        let high = hzToMel(11000)
        let points = (0..<(melBands + 2)).map {
            melToHz(low + (high - low) * Double($0) / Double(melBands + 1))
        }
        let nyquist = Double(Int(sampleRate) / 2)
        return (0..<melBands).map { band in
            (0..<binCount).map { bin in
                let frequency = nyquist * Double(bin) / Double(binCount - 1)
                let rising = (frequency - points[band]) / (points[band + 1] - points[band])
                let falling = (points[band + 2] - frequency) / (points[band + 2] - points[band + 1])
                return Float(max(0, min(rising, falling)))
            }
        }
    }
}

/// Turns beat_this's frame-wise probabilities into one steady beat grid and its downbeats.
///
/// beat_this's own "minimal" peak picking keeps every peak above 0.5, so where the model hears
/// eighth notes as strongly as beats the grid doubles for a section (Key West Bar: 232 beats at
/// 94 BPM, 247 at ~188). Here the song gets ONE tempo — the autocorrelation peak of the beat
/// probabilities, weighted towards ~105 BPM across octaves — and a dynamic-programming pass picks
/// the beats along it while still letting a live band drift (Ellis 2007). Pure; no I/O.
enum BeatThisDecoder {
    enum Failure: Error, Equatable {
        case noPulse
        case unexpectedModelOutput
    }

    static let framesPerSecond = BeatThisMel.framesPerSecond
    /// Tempo search range and the octave preference (the `BeatTracker` prior it replaces).
    static let tempoRange: ClosedRange<Double> = 55...210
    static let preferredBPM = 105.0
    static let preferenceOctaves = 0.6
    /// How hard the beat path resists a beat length away from the song's tempo.
    static let tightness = 100.0

    /// A frame at or above this probability is a beat to the model (beat_this's own threshold).
    static let beatThreshold: Float = 0.5

    static func decode(beat: [Float], downbeat: [Float]) -> ModelBeatGrid? {
        // No pulse at all (silence, a spoken track): nothing for a grid to follow.
        guard beat.lazy.filter({ $0 >= beatThreshold }).count >= 8,
            let period = beatPeriod(beat)
        else { return nil }
        let beatFrames = beatPath(beat, period: period)
        guard beatFrames.count >= 8 else { return nil }
        let bar = barGrid(downbeat: downbeat, beatFrames: beatFrames)
        return ModelBeatGrid(
            bpm: 60 * framesPerSecond / period,
            beatTimes: beatFrames.map { Double($0) / framesPerSecond },
            barGrid: bar)
    }

    /// The beat length in frames (fractional), or nil for a song with no pulse.
    static func beatPeriod(_ beat: [Float]) -> Double? {
        let mean = beat.reduce(0, +) / Float(max(beat.count, 1))
        let centred = beat.map { $0 - mean }
        let shortest = Int((60 * framesPerSecond / tempoRange.upperBound).rounded(.down))
        let longest = Int((60 * framesPerSecond / tempoRange.lowerBound).rounded(.up))
        guard centred.count > longest + 1, shortest >= 2 else { return nil }
        func correlation(_ lag: Int) -> Double {
            var sum: Float = 0
            centred.withUnsafeBufferPointer {
                vDSP_dotpr(
                    $0.baseAddress!, 1, $0.baseAddress! + lag, 1, &sum,
                    vDSP_Length(centred.count - lag))
            }
            return Double(sum)
        }
        let scores = (shortest - 1...longest + 1).map { (lag: $0, value: correlation($0)) }
        var best: (lag: Int, weighted: Double)?
        for entry in scores.dropFirst().dropLast() {
            let bpm = 60 * framesPerSecond / Double(entry.lag)
            let octaves = log2(bpm / preferredBPM) / preferenceOctaves
            let weighted = entry.value * exp(-0.5 * octaves * octaves)
            if weighted > (best?.weighted ?? 0) { best = (entry.lag, weighted) }
        }
        guard let lag = best?.lag else { return nil }
        // Parabolic refinement between neighbouring lags: the frame grid alone is ~1 % coarse.
        let before = correlation(lag - 1)
        let at = correlation(lag)
        let after = correlation(lag + 1)
        let curvature = before - 2 * at + after
        let shift = curvature < 0 ? 0.5 * (before - after) / curvature : 0
        return Double(lag) + max(-0.5, min(0.5, shift))
    }

    /// Ellis's dynamic-programming beat tracker on the beat probabilities: each beat adds its
    /// probability and pays `tightness * log(interval / period)^2` for straying from the tempo.
    static func beatPath(_ beat: [Float], period: Double) -> [Int] {
        let count = beat.count
        guard count > 0, period >= 2 else { return [] }
        var score = [Double](repeating: 0, count: count)
        var previous = [Int](repeating: -1, count: count)
        let earliest = Int((2 * period).rounded())
        let latest = Int((period / 2).rounded())
        for frame in 0..<count {
            score[frame] = Double(beat[frame])
            let lower = max(0, frame - earliest)
            let upper = frame - latest
            guard upper > lower else { continue }
            // Starting a fresh path scores 0, so a beat near the song's start is never charged
            // for having only too-close predecessors (which put the first beat on a non-beat).
            var best = 0.0
            for candidate in lower..<upper {
                let deviation = log(Double(frame - candidate) / period)
                let total = score[candidate] - tightness * deviation * deviation
                if total > best {
                    best = total
                    previous[frame] = candidate
                }
            }
            score[frame] += best
        }
        // End on the song's last beat, then walk back: the best-scoring frame among the
        // model's beats in the last two beat lengths. The best frame overall can be a non-beat
        // past the last real one, which added a beat 13 % late.
        let tail = max(0, count - Int((2 * period).rounded(.up)))
        let lastBeats = (tail..<count).filter { beat[$0] >= beatThreshold }
        var frame =
            (lastBeats.isEmpty ? Array(tail..<count) : lastBeats)
            .max { score[$0] < score[$1] } ?? count - 1
        var frames: [Int] = []
        while frame >= 0 {
            frames.append(frame)
            frame = previous[frame]
        }
        return frames.reversed()
    }

    /// The meter (3 or 4 beats) and the beat that starts the first bar: the phase whose beats
    /// carry the most downbeat probability, measured against the average beat.
    static func barGrid(downbeat: [Float], beatFrames: [Int]) -> SongBarGrid {
        let values = beatFrames.map { downbeat.indices.contains($0) ? Double(downbeat[$0]) : 0 }
        let average = values.reduce(0, +) / Double(max(values.count, 1))
        var best = (beatsPerBar: 4, phase: 0, mean: 0.0, contrast: -Double.infinity)
        for beatsPerBar in [4, 3] {
            for phase in 0..<beatsPerBar {
                let onPhase = stride(from: phase, to: values.count, by: beatsPerBar).map {
                    values[$0]
                }
                let mean = onPhase.reduce(0, +) / Double(max(onPhase.count, 1))
                // A 4/4 song read in 3 still has some strong beats on phase; demand a clear win.
                let contrast = mean - average - (beatsPerBar == 3 ? 0.05 : 0)
                if contrast > best.contrast { best = (beatsPerBar, phase, mean, contrast) }
            }
        }
        return SongBarGrid(
            beatsPerBar: best.beatsPerBar, barPhase: best.phase, confidence: best.mean,
            phaseSource: .beatModel)
    }
}
