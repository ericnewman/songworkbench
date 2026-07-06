import AVFoundation
import Accelerate
import Foundation

/// A single detected bass note: the fundamental pitch played at `timestamp`,
/// expressed as a MIDI note number, with a clarity-derived `confidence` in
/// `[0, 1]`. `pitch` keeps the tuning-normalized FRACTIONAL MIDI value the note
/// was rounded from, so downstream passes can re-arbitrate borderline roundings
/// (e.g. against the concurrent chord); `nil` on documents from before it existed.
struct BassNoteObservation: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let midiNote: Int
    let confidence: Float
    var pitch: Double?

    init(timestamp: TimeInterval, midiNote: Int, confidence: Float, pitch: Double? = nil) {
        self.timestamp = timestamp
        self.midiNote = midiNote
        self.confidence = confidence
        self.pitch = pitch
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case midiNote
        case confidence
        case pitch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        midiNote = try container.decode(Int.self, forKey: .midiNote)
        confidence = try container.decode(Float.self, forKey: .confidence)
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch)
    }
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

/// Re-arbitrates BORDERLINE bass-note roundings against the final chord timeline: a note
/// whose fractional pitch sits near the boundary between two semitones, where the rounded
/// pick clashes with the concurrent chord but the other side IS a chord tone, snaps to the
/// chord tone. Field-measured: residual ±1-semitone bass-vs-chord clashes go BOTH
/// directions (per-note boundary noise, not a grid offset), so only the audio-ambiguous
/// cases flip — a decisive fractional pitch is never overridden, preserving genuinely
/// chromatic playing.
enum BassChordReconciler {
    /// Maximum distance from `pitch` to the alternative semitone for a flip — 0.65 means
    /// the fraction leans at least 0.35 toward the alternative (a genuinely ambiguous read).
    static let maximumFlipDistance = 0.65

    static func snapped(
        _ observations: [BassNoteObservation], chords: [EditableChordEvent]
    ) -> [BassNoteObservation] {
        guard !observations.isEmpty, !chords.isEmpty else { return observations }
        let sorted = chords.sorted { $0.time < $1.time }
        return observations.map { observation in
            guard let pitch = observation.pitch,
                let active = sorted.last(where: { $0.time <= observation.timestamp }),
                let tones = chordTonePitchClasses(active.chord)
            else { return observation }
            let current = observation.midiNote
            if tones.contains(((current % 12) + 12) % 12) { return observation }
            let alternative = pitch >= Double(current) ? current + 1 : current - 1
            guard
                tones.contains(((alternative % 12) + 12) % 12),
                abs(pitch - Double(alternative)) <= maximumFlipDistance
            else { return observation }
            return BassNoteObservation(
                timestamp: observation.timestamp,
                midiNote: alternative,
                confidence: observation.confidence,
                pitch: observation.pitch
            )
        }
    }

    /// Pitch classes of the chord's tones (root/third/fifth + any seventh), parsed from a
    /// display label like "Ebm7", "Bbmaj7", "F#", "C7"; `nil` for unparseable labels.
    static func chordTonePitchClasses(_ label: String) -> Set<Int>? {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let flats = ["Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#"]
        var rest = label
        var rootName = String(rest.prefix(1))
        rest = String(rest.dropFirst())
        if let accidental = rest.first, accidental == "#" || accidental == "b" {
            rootName.append(accidental)
            rest = String(rest.dropFirst())
        }
        rootName = flats[rootName] ?? rootName
        guard let root = names.firstIndex(of: rootName) else { return nil }
        let isMinor = rest.hasPrefix("m") && !rest.hasPrefix("maj")
        var tones: Set<Int> = [0, isMinor ? 3 : 4, 7]
        if rest.hasSuffix("maj7") {
            tones.insert(11)
        } else if rest.hasSuffix("7") {
            tones.insert(10)
        }
        return Set(tones.map { (root + $0) % 12 })
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

        // One entry per frame: the detected fractional MIDI pitch (or nil for
        // silent/unvoiced frames) plus the frame's clarity. Fractional pitch is kept
        // through the tuning-offset pass below; rounding to note numbers happens last.
        var framePitch: [Double?] = []
        var frameClarity: [Float] = []
        var frameStartTime: [TimeInterval] = []

        var frameStart = 0
        while frameStart + frameLength <= decimated.count {
            let frame = Array(decimated[frameStart..<(frameStart + frameLength)])
            let time = Double(frameStart) / decimatedRate
            frameStartTime.append(time)

            let rms = rootMeanSquare(frame)
            if rms < silenceThreshold {
                framePitch.append(nil)
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
                let frequency = decimatedRate / lag
                framePitch.append(69 + 12 * log2(frequency / 440))
                frameClarity.append(clarity)
            } else {
                framePitch.append(nil)
                frameClarity.append(0)
            }
            frameStart += hopLength
        }

        // Global tuning normalization: recordings tuned off A440 (down-tuned guitars,
        // varispeed) shift EVERY note by the same cents; naive rounding then flips
        // borderline notes to the wrong semitone — the ±1-semitone bass-vs-chord clashes
        // Eric heard. Deviations from equal temperament live on a circle (+0.4 and −0.45
        // are 0.15 apart, not 0.85), so the shared offset is the clarity-weighted CIRCULAR
        // mean of the per-frame deviations — a plain median splits at the ±0.5 boundary
        // exactly where detuned recordings sit. Genuinely chromatic playing is unaffected
        // (per-note deviations around the shared offset still round correctly).
        var sinSum = 0.0
        var cosSum = 0.0
        var deviationWeight = 0.0
        for (pitch, clarity) in zip(framePitch, frameClarity) {
            guard let pitch, clarity > 0 else { continue }
            let deviation = pitch - pitch.rounded()
            sinSum += Double(clarity) * sin(2 * .pi * deviation)
            cosSum += Double(clarity) * cos(2 * .pi * deviation)
            deviationWeight += Double(clarity)
        }
        let tuningOffset: Double
        if deviationWeight >= 3, sinSum * sinSum + cosSum * cosSum > 1e-9 {
            tuningOffset = atan2(sinSum, cosSum) / (2 * .pi)
        } else {
            tuningOffset = 0
        }
        let adjustedPitch: [Double?] = framePitch.map { pitch in
            guard let pitch else { return nil }
            return pitch - tuningOffset
        }
        let frameMidi: [Int?] = adjustedPitch.map { pitch in
            guard let pitch else { return nil }
            return Int(pitch.rounded())
        }

        let smoothed = medianFiltered(frameMidi, window: medianWindow)
        return segments(
            midi: smoothed,
            pitch: adjustedPitch,
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

    /// Normalized autocorrelation peak over the bass lag range. Returns the best lag —
    /// parabolically interpolated to sub-sample precision — and its clarity in `[0, 1]`
    /// (correlation divided by frame energy `r[0]`).
    ///
    /// Integer lags quantize pitch coarsely in the upper bass register (near G4 at the
    /// 8 kHz working rate, adjacent lags are ~80 cents apart), which flipped detected
    /// notes a semitone off the played pitch. The standard 3-point parabolic fit around
    /// the peak recovers the fractional lag.
    private func bestLag(
        frame: [Float],
        minimumLag: Int,
        maximumLag: Int
    ) -> (lag: Double?, clarity: Float) {
        return frame.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            let count = frame.count

            // r[0] — total energy — normalizes the correlation into [0, 1].
            let energy = vDSP.dot(
                UnsafeBufferPointer(start: base, count: count),
                UnsafeBufferPointer(start: base, count: count)
            )
            guard energy > 0 else { return (nil, 0) }

            func clarity(at lag: Int) -> Float {
                let pairCount = count - lag
                guard pairCount > 0 else { return 0 }
                let correlation = vDSP.dot(
                    UnsafeBufferPointer(start: base, count: pairCount),
                    UnsafeBufferPointer(start: base + lag, count: pairCount)
                )
                return correlation / energy
            }

            var bestLag: Int?
            var bestClarity: Float = 0
            for lag in minimumLag...maximumLag {
                let value = clarity(at: lag)
                if value > bestClarity {
                    bestClarity = value
                    bestLag = lag
                }
            }
            guard let bestLag else { return (nil, 0) }

            // Parabolic refinement using the peak's neighbours (guarded at range edges).
            var refined = Double(bestLag)
            if bestLag > minimumLag, bestLag < maximumLag {
                let left = Double(clarity(at: bestLag - 1))
                let center = Double(bestClarity)
                let right = Double(clarity(at: bestLag + 1))
                let denominator = left - 2 * center + right
                if denominator < 0 {
                    let delta = 0.5 * (left - right) / denominator
                    if abs(delta) <= 0.5 { refined += delta }
                }
            }
            return (refined, max(min(bestClarity, 1), 0))
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
        pitch: [Double?],
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
                // Mean fractional pitch across the segment's PITCHED frames — kept on the
                // observation so borderline roundings can be re-arbitrated downstream.
                let pitches = (index...end).compactMap { pitch[$0] }
                let meanPitch =
                    pitches.isEmpty ? nil : pitches.reduce(0, +) / Double(pitches.count)
                observations.append(
                    BassNoteObservation(
                        timestamp: startTime,
                        midiNote: note,
                        confidence: meanClarity,
                        pitch: meanPitch
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
