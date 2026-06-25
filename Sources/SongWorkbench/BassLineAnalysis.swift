import AVFoundation
import Accelerate
import Foundation

/// A single detected bass note: the fundamental pitch played at `timestamp`,
/// expressed as a MIDI note number, with a clarity-derived `confidence` in
/// `[0, 1]`.
struct BassNoteObservation: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let midiNote: Int
    let confidence: Float
}

/// Maps a MIDI note number to a pitch-class name (no octave), e.g. `45` → `A`.
enum BassNoteNaming {
    private static let names = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    static func name(forMidiNote midiNote: Int) -> String {
        let pitchClass = ((midiNote % 12) + 12) % 12
        return names[pitchClass]
    }
}

/// Detects the monophonic bass line from a separated BASS stem using
/// autocorrelation-based fundamental-frequency estimation.
///
/// Pure and deterministic given the audio: load mono samples, decimate toward
/// ~8 kHz (bass fundamentals are below ~400 Hz), estimate `f0` per frame via a
/// normalized autocorrelation peak, gate silence/unvoiced frames, then
/// median-filter and segment the per-frame MIDI sequence into one observation
/// per stable note.
struct BassLineAnalyzer: Sendable {
    /// Target rate after decimation. 8 kHz comfortably covers bass
    /// fundamentals (E1 ≈ 41 Hz to G4 ≈ 392 Hz) with margin.
    private let targetSampleRate: Double = 8_000
    private let frameLength = 2_048
    private let hopLength = 1_024
    /// Lowest bass fundamental searched (E1).
    private let minimumFrequency: Double = 41
    /// Highest bass fundamental searched (G4).
    private let maximumFrequency: Double = 392
    /// Frames below this RMS (after peak normalization) are treated as silence.
    private let silenceThreshold: Float = 0.003
    /// Quiet bass stems are scaled up so their peak reaches this before detection, so a
    /// low separation level doesn't sink real bass below the silence floor. Detection stays
    /// volume-independent (the clarity metric is already energy-normalized); true silence
    /// stays silent and the clarity gate still rejects amplified noise.
    private let detectionTargetPeak: Float = 0.7
    /// Frames whose best normalized autocorrelation peak is below this are
    /// treated as unvoiced (no clear pitch). Kept fairly permissive so quieter, less
    /// perfectly-periodic bass (e.g. intros, separation artifacts) is still tracked; the
    /// median filter and minimum-segment-duration gate suppress isolated spurious frames.
    private let clarityThreshold: Float = 0.35
    /// Window (in frames) of the per-frame MIDI median filter.
    private let medianWindow = 5
    /// Segments shorter than this are discarded as jitter.
    private let minimumSegmentDuration: TimeInterval = 0.12

    func analyze(url: URL) throws -> [BassNoteObservation] {
        let (samples, sampleRate) = try loadMonoSamples(url: url)
        try Task.checkCancellation()
        return analyze(samples: samples, sampleRate: sampleRate)
    }

    /// Core detection over raw samples at a known rate. Exposed so callers (and
    /// tests) can analyze a `[Float]` buffer directly without a real file.
    func analyze(samples: [Float], sampleRate: Double) -> [BassNoteObservation] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }

        let leveled = peakNormalized(samples)
        let (decimated, decimatedRate) = decimate(samples: leveled, sampleRate: sampleRate)
        guard decimated.count >= frameLength else { return [] }

        let minimumLag = max(Int((decimatedRate / maximumFrequency).rounded(.down)), 1)
        let maximumLag = min(
            Int((decimatedRate / minimumFrequency).rounded(.up)),
            frameLength - 1
        )
        guard maximumLag > minimumLag else { return [] }

        // One entry per frame: the detected MIDI note (or nil for
        // silent/unvoiced frames) plus the frame's clarity.
        var frameMidi: [Int?] = []
        var frameClarity: [Float] = []
        var frameStartTime: [TimeInterval] = []

        var frameStart = 0
        while frameStart + frameLength <= decimated.count {
            let frame = Array(decimated[frameStart..<(frameStart + frameLength)])
            let time = Double(frameStart) / decimatedRate
            frameStartTime.append(time)

            let rms = rootMeanSquare(frame)
            if rms < silenceThreshold {
                frameMidi.append(nil)
                frameClarity.append(0)
                frameStart += hopLength
                continue
            }

            let (lag, clarity) = bestLag(
                frame: frame,
                minimumLag: minimumLag,
                maximumLag: maximumLag
            )
            if let lag, clarity >= clarityThreshold {
                let frequency = decimatedRate / Double(lag)
                let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
                frameMidi.append(midi)
                frameClarity.append(clarity)
            } else {
                frameMidi.append(nil)
                frameClarity.append(0)
            }
            frameStart += hopLength
        }

        let smoothed = medianFiltered(frameMidi, window: medianWindow)
        return segments(
            midi: smoothed,
            clarity: frameClarity,
            startTimes: frameStartTime
        )
    }

    // MARK: - Detection helpers

    private func rootMeanSquare(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(frame)
    }

    /// Scales the whole signal up so its peak reaches `detectionTargetPeak`, lifting quiet
    /// bass above the silence floor. Only boosts (never attenuates) so already-loud stems
    /// are untouched; a fully silent signal is returned unchanged.
    private func peakNormalized(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0, peak < detectionTargetPeak else { return samples }
        var gain = detectionTargetPeak / peak
        var output = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &gain, &output, 1, vDSP_Length(samples.count))
        return output
    }

    /// Normalized autocorrelation peak over the bass lag range. Returns the
    /// best lag and its clarity in `[0, 1]` (correlation divided by frame
    /// energy `r[0]`).
    private func bestLag(
        frame: [Float],
        minimumLag: Int,
        maximumLag: Int
    ) -> (lag: Int?, clarity: Float) {
        return frame.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            let count = frame.count

            // r[0] — total energy — normalizes the correlation into [0, 1].
            let energy = vDSP.dot(
                UnsafeBufferPointer(start: base, count: count),
                UnsafeBufferPointer(start: base, count: count)
            )
            guard energy > 0 else { return (nil, 0) }

            var bestLag: Int?
            var bestClarity: Float = 0
            for lag in minimumLag...maximumLag {
                let pairCount = count - lag
                guard pairCount > 0 else { break }
                let correlation = vDSP.dot(
                    UnsafeBufferPointer(start: base, count: pairCount),
                    UnsafeBufferPointer(start: base + lag, count: pairCount)
                )
                let clarity = correlation / energy
                if clarity > bestClarity {
                    bestClarity = clarity
                    bestLag = lag
                }
            }
            return (bestLag, max(min(bestClarity, 1), 0))
        }
    }

    /// Decimate toward `targetSampleRate` by averaging each block of `factor`
    /// samples. Returns the decimated samples and their effective rate.
    private func decimate(samples: [Float], sampleRate: Double) -> ([Float], Double) {
        let factor = max(Int((sampleRate / targetSampleRate).rounded(.down)), 1)
        guard factor > 1 else { return (samples, sampleRate) }

        let outputCount = samples.count / factor
        guard outputCount > 0 else { return (samples, sampleRate) }

        var output = [Float](repeating: 0, count: outputCount)
        samples.withUnsafeBufferPointer { input in
            let base = input.baseAddress!
            for index in 0..<outputCount {
                output[index] = vDSP.mean(
                    UnsafeBufferPointer(start: base + index * factor, count: factor)
                )
            }
        }
        return (output, sampleRate / Double(factor))
    }

    private func medianFiltered(_ values: [Int?], window: Int) -> [Int?] {
        guard window > 1, values.count >= window else { return values }
        let radius = window / 2
        var output = values
        for index in 0..<values.count {
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            let present = (lower...upper).compactMap { values[$0] }.sorted()
            // Keep silence (nil) when the window has no pitched frames.
            output[index] = present.isEmpty ? nil : present[present.count / 2]
        }
        return output
    }

    /// Merge consecutive frames with equal MIDI into segments, drop short
    /// segments, and emit one observation per surviving segment at its start.
    private func segments(
        midi: [Int?],
        clarity: [Float],
        startTimes: [TimeInterval]
    ) -> [BassNoteObservation] {
        var observations: [BassNoteObservation] = []
        var index = 0
        while index < midi.count {
            guard let note = midi[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < midi.count, midi[end + 1] == note {
                end += 1
            }

            let startTime = startTimes[index]
            // The segment spans from its first frame's start to the start of
            // the frame after its last frame (one hop past the last frame).
            let hopDuration = frameAdvance(startTimes)
            let endTime: TimeInterval =
                end + 1 < startTimes.count
                ? startTimes[end + 1]
                : startTimes[end] + hopDuration
            let duration = max(endTime - startTime, 0)

            if duration >= minimumSegmentDuration {
                let claritySlice = clarity[index...end]
                let meanClarity =
                    claritySlice.isEmpty
                    ? 0
                    : claritySlice.reduce(0, +) / Float(claritySlice.count)
                observations.append(
                    BassNoteObservation(
                        timestamp: startTime,
                        midiNote: note,
                        confidence: meanClarity
                    )
                )
            }
            index = end + 1
        }
        return observations
    }

    /// Per-frame hop advance in seconds, derived from the spacing of the
    /// recorded frame start times (falls back to 0 if unavailable).
    private func frameAdvance(_ startTimes: [TimeInterval]) -> TimeInterval {
        guard startTimes.count >= 2 else { return 0 }
        return startTimes[1] - startTimes[0]
    }

    // MARK: - Loading

    /// Mirrors `AudioFileAnalysisService.loadMonoSamples`: reads the file,
    /// sums channels to mono, and returns the samples plus sample rate. Honors
    /// security-scoped resource access.
    private func loadMonoSamples(url: URL) throws -> ([Float], Double) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else {
                throw WaveformAnalyzerError.unsupportedAudioFormat
            }
            for frame in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    value += channels[channel][frame]
                }
                samples.append(value / Float(format.channelCount))
            }
        }
        return (samples, format.sampleRate)
    }
}
