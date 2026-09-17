import AVFoundation
import Foundation

struct SongAudioAnalysis: Codable, Equatable, Sendable {
    let beat: BeatEstimate?
    let chords: [ChordObservation]
    let estimatedKey: MusicalKey?
    /// Times where the chroma itself genuinely changes, from `ChromaChangePointDetector` — the
    /// direct answer to "did the harmony change here?", as opposed to `chords`, whose labels
    /// change wherever the classifier's winner flips (including on a single noisy frame).
    ///
    /// Only the TIMES are persisted, not the chroma frames they came from: a few hundred doubles
    /// per song instead of tens of thousands of vectors, and nothing downstream needs the frames.
    /// `nil` on analyses cached before this existed — consumers must treat that as "unavailable"
    /// and fall back, never as "no harmonic changes in this song".
    let harmonicChangePoints: [TimeInterval]?

    init(
        beat: BeatEstimate?,
        chords: [ChordObservation],
        estimatedKey: MusicalKey? = nil,
        harmonicChangePoints: [TimeInterval]? = nil
    ) {
        self.beat = beat
        self.chords = chords
        self.estimatedKey = estimatedKey
        self.harmonicChangePoints = harmonicChangePoints
    }
}

struct VocalStemActivitySummary: Equatable, Sendable {
    let intervals: [ClosedRange<TimeInterval>]
    let waveform: WaveformEnvelope
}

actor AudioFileAnalysisService {
    func analyze(url: URL) throws -> SongAudioAnalysis {
        let (samples, sampleRate) = try loadMonoSamples(url: url)
        try Task.checkCancellation()
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: sampleRate,
            frameLength: 8_192,
            hopLength: 4_096
        )
        let frames = try ChordAnalysisPipeline(configuration: configuration).analyzeFrames(
            samples: samples)
        let chords = frames.observations
        return SongAudioAnalysis(
            beat: BeatTracker().analyze(samples: samples, sampleRate: sampleRate),
            chords: chords,
            estimatedKey: MusicalKeyEstimator().estimate(from: chords),
            harmonicChangePoints: ChromaChangePointDetector.changePoints(frames: frames.chroma)
        )
    }

    /// Chord/beat analysis over several isolated stems weighted together, so chord detection is
    /// not restricted to whichever single stem happened to come first. Stems are mixed by
    /// `HarmonyStemMix` (unit-RMS normalized, leakage-gated) and the result runs through the same
    /// pipeline as a single file.
    ///
    /// Falls back to analyzing the first URL alone when the mix comes back empty — every
    /// contributor silent, or all but one gated out as leakage — so a degenerate mix can never
    /// produce a worse result than the previous single-stem behaviour.
    func analyze(weighted: [(url: URL, weight: Float, label: String)]) throws
        -> SongAudioAnalysis
    {
        guard let primary = weighted.first else {
            throw HarmonyAudioSourceError.missingAccompanimentStem
        }
        guard weighted.count > 1 else { return try analyze(url: primary.url) }

        // Two passes so only ONE stem is ever resident alongside the accumulator, instead of
        // every stem at once. Separation already peaks in the gigabytes, so the harmony stage
        // must not add a full-length Float buffer per contributor on top of it — a stem is ~64 MB
        // per six minutes of 44.1 kHz audio, and they were all held simultaneously.
        //
        // The cost is decoding each stem twice (once to measure, once to accumulate). That is a
        // few seconds against a stage already dominated by onset detection, and it converts a
        // per-contributor peak into a constant one.
        var sampleRate: Double = 0
        var levels: [(entry: (url: URL, weight: Float, label: String), rms: Float)] = []
        for entry in weighted {
            guard let (samples, rate) = try? loadMonoSamples(url: entry.url), !samples.isEmpty
            else { continue }
            // Stems come from one separation of one recording, so their rates match. A mismatch
            // means something unexpected produced this set; skip rather than resample silently.
            if sampleRate == 0 {
                sampleRate = rate
            } else if rate != sampleRate {
                continue
            }
            levels.append((entry, HarmonyStemMix.rootMeanSquare(samples)))
        }
        try Task.checkCancellation()

        let kept = HarmonyStemMix.keptAfterLeakageGate(levels.map(\.rms))
        var mixSamples: [Float] = []
        var included: [String] = []
        for (index, level) in levels.enumerated() where kept.contains(index) {
            guard let (samples, _) = try? loadMonoSamples(url: level.entry.url), !samples.isEmpty
            else { continue }
            try Task.checkCancellation()
            // Unit-RMS normalization, so `weight` expresses priority rather than mix level.
            let scale = level.entry.weight / level.rms
            if mixSamples.isEmpty {
                mixSamples = samples.map { $0 * scale }
            } else {
                let length = min(mixSamples.count, samples.count)
                mixSamples.removeLast(mixSamples.count - length)
                for i in 0..<length { mixSamples[i] += samples[i] * scale }
            }
            included.append(level.entry.label)
        }
        let mix = HarmonyStemMix.normalizedToUnitPeak(mixSamples, included: included)
        mixSamples = []
        guard !mix.samples.isEmpty, sampleRate > 0 else { return try analyze(url: primary.url) }

        let configuration = try AudioAnalysisConfiguration(
            sampleRate: sampleRate,
            frameLength: 8_192,
            hopLength: 4_096
        )
        let frames = try ChordAnalysisPipeline(configuration: configuration).analyzeFrames(
            samples: mix.samples)
        let chords = frames.observations
        return SongAudioAnalysis(
            beat: BeatTracker().analyze(samples: mix.samples, sampleRate: sampleRate),
            chords: chords,
            estimatedKey: MusicalKeyEstimator().estimate(from: chords),
            harmonicChangePoints: ChromaChangePointDetector.changePoints(frames: frames.chroma)
        )
    }

    /// Vocal-activity intervals (singing regions) for a vocals-stem file, used to evaluate and
    /// later correct lyric timing against where the voice is actually present.
    func vocalActivityIntervals(url: URL) throws -> [ClosedRange<TimeInterval>] {
        let (samples, sampleRate) = try loadMonoSamples(url: url)
        try Task.checkCancellation()
        return VocalActivityEnvelope.voicedIntervals(samples: samples, sampleRate: sampleRate)
    }

    /// Reads the vocals stem once and derives both UI outputs that need it: strict singing
    /// intervals and a compact display waveform. Long iPad runs previously decoded the same full
    /// stem twice when opening a separated song.
    func vocalActivitySummary(
        url: URL,
        targetSampleCount: Int = 4_000
    ) throws -> VocalStemActivitySummary {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0, targetSampleCount > 0 else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        let totalFrames = max(Int(file.length), 1)
        var peaks = [Float](repeating: 0, count: targetSampleCount)
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))

        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        var absoluteFrame = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw WaveformAnalyzerError.unsupportedAudioFormat
            }

            for frame in 0..<frameCount {
                var summedSample: Float = 0
                var peakSample: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    let value = channels[channel][frame]
                    summedSample += value
                    peakSample = max(peakSample, abs(value))
                }
                samples.append(summedSample / Float(format.channelCount))
                let bin = min(
                    (absoluteFrame + frame) * targetSampleCount / totalFrames,
                    targetSampleCount - 1
                )
                peaks[bin] = max(peaks[bin], peakSample)
            }
            absoluteFrame += frameCount
        }

        try Task.checkCancellation()
        return VocalStemActivitySummary(
            intervals: VocalActivityEnvelope.voicedIntervals(
                samples: samples,
                sampleRate: format.sampleRate
            ),
            waveform: WaveformEnvelope(
                peaks: peaks,
                duration: Double(file.length) / format.sampleRate
            )
        )
    }

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

extension Chord {
    var displayName: String {
        let roots = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        let rootName = roots[root.rawValue]
        switch quality {
        case .major: return rootName
        case .minor: return rootName + "m"
        case .major7: return rootName + "maj7"
        case .minor7: return rootName + "m7"
        case .dominant7: return rootName + "7"
        }
    }
}

/// Per-frame channel energy for onset/VAD analysis. Waveform averaging can cancel opposite-polarity
/// stereo channels; root-mean-square channel combination preserves energy without affecting the
/// later RMS envelope's scale for ordinary dual-mono stems.
enum PhaseInvariantChannelEnergy {
    static func sample(_ channelValues: [Float]) -> Float {
        let sumOfSquares = channelValues.reduce(Float(0)) { $0 + $1 * $1 }
        return sample(sumOfSquares: sumOfSquares, channelCount: channelValues.count)
    }

    static func sample(sumOfSquares: Float, channelCount: Int) -> Float {
        guard channelCount > 0, sumOfSquares > 0 else { return 0 }
        return (sumOfSquares / Float(channelCount)).squareRoot()
    }
}

/// Per-hop RMS envelope shared by vocal onset/offset/VAD detectors.
enum VocalRMSEnvelope {
    static func compute(
        samples: [Float],
        sampleRate: Double,
        windowSeconds: Double,
        hopSeconds: Double
    ) -> [Float] {
        let window = max(2, Int(sampleRate * windowSeconds))
        let hop = max(1, Int(sampleRate * hopSeconds))
        guard samples.count >= window else { return [] }
        var rms: [Float] = []
        rms.reserveCapacity((samples.count - window) / hop + 1)
        var index = 0
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) {
                let value = samples[i]
                sum += value * value
            }
            rms.append((sum / Float(window)).squareRoot())
            index += hop
        }
        return rms
    }
}

/// Vocal-energy enter threshold: relative (noise floor × multiple, peak × fraction) plus an
/// adaptive floor from the sung body. Instrumental bleed after real singing often still clears
/// the relative threshold once the noise floor drops, but stays well below typical sung RMS;
/// requiring frames to exceed `vocalBodyFraction` of the median body level filters that bleed
/// while preserving quiet endings.
enum VocalEnergyThreshold {
    struct Parameters: Sendable {
        var peakFraction: Float
        var noiseFloorMultiple: Float
        /// Minimum fraction of median sung-frame RMS for a window to count as voiced.
        var vocalBodyFraction: Float = 0.30
    }

    static func enterThreshold(rms: [Float], parameters: Parameters) -> Float? {
        guard let peak = rms.max(), peak > 0 else { return nil }
        // Prefer the median of clearly quiet frames; when vocals dominate the file the 5th
        // percentile can sit at singing level and inflate the relative bar (noise × multiple).
        let quietCutoff = peak * 0.20
        let quietFrames = rms.filter { $0 < quietCutoff }
        let noiseFloor: Float
        if quietFrames.count >= 3 {
            let quietSorted = quietFrames.sorted()
            noiseFloor = quietSorted[quietSorted.count / 2]
        } else {
            let sorted = rms.sorted()
            let floorIndex = max(0, min(sorted.count - 1, Int(Double(sorted.count) * 0.05)))
            noiseFloor = min(sorted[floorIndex], peak * 0.10)
        }
        let relative = max(
            noiseFloor * parameters.noiseFloorMultiple, peak * parameters.peakFraction)

        // 75th percentile of body frames ≈ typical sung level (median tracks dips/fade-outs).
        let bodyFrames = rms.filter { $0 >= relative }
        guard bodyFrames.count >= 3 else { return relative }
        let bodySorted = bodyFrames.sorted()
        let bodyIndex = min(bodySorted.count - 1, Int(Double(bodySorted.count) * 0.75))
        let bodyReference = bodySorted[bodyIndex]
        return max(relative, bodyReference * parameters.vocalBodyFraction)
    }
}

/// Finds the first moment vocals actually enter in an ISOLATED vocals stem. ASR models (Whisper
/// especially) hallucinate or anchor "lyrics" during a silent instrumental intro, leaving the
/// first lyric line timestamped at ~0:00. Run on the separated vocals stem — where the intro is
/// near-silent — a simple energy threshold reliably finds the true onset, so any transcribed
/// words before it can be dropped. The pure core (`firstOnset(samples:sampleRate:)`) is unit
/// tested; the file loader is a thin wrapper. Only meaningful on the vocals stem, never the mix.
enum VocalOnsetDetector {
    struct Configuration: Sendable {
        var windowSeconds: Double = 0.05
        var hopSeconds: Double = 0.025
        /// Energy must stay above threshold for this long before a window counts as the onset.
        var sustainSeconds: Double = 0.15
        /// Onsets earlier than this are treated as "the song starts right away" → no gating.
        var minIntroSeconds: Double = 0.75
        /// Fraction of peak RMS used for the threshold (combined with the noise floor).
        var peakFraction: Float = 0.06
        /// Multiple of the noise floor the signal must exceed to count as vocal energy.
        var noiseFloorMultiple: Float = 3
        /// Minimum fraction of median sung-frame RMS (see `VocalEnergyThreshold`).
        var vocalBodyFraction: Float = 0.30
    }

    /// First sustained vocal onset in seconds, or `nil` when there is no clear silent intro to gate
    /// (song starts immediately, detection inconclusive, or input too short).
    static func firstOnset(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .init()
    ) -> TimeInterval? {
        guard sampleRate > 0 else { return nil }
        let rms = VocalRMSEnvelope.compute(
            samples: samples,
            sampleRate: sampleRate,
            windowSeconds: configuration.windowSeconds,
            hopSeconds: configuration.hopSeconds)
        guard !rms.isEmpty else { return nil }
        guard
            let threshold = VocalEnergyThreshold.enterThreshold(
                rms: rms,
                parameters: .init(
                    peakFraction: configuration.peakFraction,
                    noiseFloorMultiple: configuration.noiseFloorMultiple,
                    vocalBodyFraction: configuration.vocalBodyFraction))
        else { return nil }
        let hop = max(1, Int(sampleRate * configuration.hopSeconds))

        let sustainWindows = max(1, Int(configuration.sustainSeconds / configuration.hopSeconds))
        let duration = Double(samples.count) / sampleRate
        var run = 0
        for (i, value) in rms.enumerated() where value >= threshold {
            run = (i > 0 && rms[i - 1] >= threshold) ? run + 1 : 1
            guard run >= sustainWindows else { continue }
            let onset = Double((i - run + 1) * hop) / sampleRate
            // Only gate when there's a real intro; if onset is essentially at the end, detection
            // failed — don't gate either.
            guard onset >= configuration.minIntroSeconds, onset < duration * 0.9 else { return nil }
            return onset
        }
        return nil
    }

    /// Loads `url` as mono and returns the first vocal onset, or `nil`.
    static func firstOnset(url: URL, configuration: Configuration = .init()) throws -> TimeInterval?
    {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { return nil }
            for frame in 0..<Int(buffer.frameLength) {
                var sumOfSquares: Float = 0
                for channel in 0..<channelCount {
                    let value = channels[channel][frame]
                    sumOfSquares += value * value
                }
                samples.append(
                    PhaseInvariantChannelEnergy.sample(
                        sumOfSquares: sumOfSquares, channelCount: channelCount))
            }
        }
        return firstOnset(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
    }
}

/// Finds where vocals actually END in an isolated vocals stem — the mirror of `VocalOnsetDetector`.
/// ASR models hallucinate lyric lines during a silent instrumental outro (often triggered by guitar
/// bleed in the vocals stem). Run on the separated vocals stem to find the last sustained singing
/// before a real outro silence, so transcribed words after that point can be dropped. The pure core
/// is unit tested; the file loader is a thin wrapper. Only meaningful on the vocals stem.
enum VocalOffsetDetector {
    struct Configuration: Sendable {
        var windowSeconds: Double = 0.05
        var hopSeconds: Double = 0.025
        /// Energy must stay below threshold for this long before a window counts as outro silence.
        var sustainSeconds: Double = 0.15
        /// Outros shorter than this are treated as "vocals run to the end" → no gating.
        var minOutroSeconds: Double = 0.75
        /// Fraction of peak RMS used for the threshold (combined with the noise floor).
        var peakFraction: Float = 0.06
        /// Multiple of the noise floor the signal must exceed to count as vocal energy.
        var noiseFloorMultiple: Float = 3
        /// Minimum fraction of median sung-frame RMS (see `VocalEnergyThreshold`).
        var vocalBodyFraction: Float = 0.30
    }

    /// Last moment of sustained singing (seconds), or `nil` when there is no clear silent outro
    /// to gate (song ends with vocals, detection inconclusive, or input too short).
    static func lastOffset(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .init()
    ) -> TimeInterval? {
        guard sampleRate > 0 else { return nil }
        let rms = VocalRMSEnvelope.compute(
            samples: samples,
            sampleRate: sampleRate,
            windowSeconds: configuration.windowSeconds,
            hopSeconds: configuration.hopSeconds)
        guard !rms.isEmpty else { return nil }
        guard
            let threshold = VocalEnergyThreshold.enterThreshold(
                rms: rms,
                parameters: .init(
                    peakFraction: configuration.peakFraction,
                    noiseFloorMultiple: configuration.noiseFloorMultiple,
                    vocalBodyFraction: configuration.vocalBodyFraction))
        else { return nil }
        let hop = max(1, Int(sampleRate * configuration.hopSeconds))

        let sustainWindows = max(1, Int(configuration.sustainSeconds / configuration.hopSeconds))
        let duration = Double(samples.count) / sampleRate
        func time(at windowIndex: Int) -> TimeInterval { Double(windowIndex * hop) / sampleRate }

        // Last analysis window with vocal energy at/above threshold.
        guard let lastVoiced = rms.indices.last(where: { rms[$0] >= threshold }) else {
            return nil
        }
        // Require sustained silence immediately after that window (mirrors onset sustain).
        let silenceStart = lastVoiced + 1
        guard silenceStart + sustainWindows <= rms.count else { return nil }
        for k in silenceStart..<(silenceStart + sustainWindows) where rms[k] >= threshold {
            return nil
        }

        let offset = time(at: lastVoiced) + configuration.windowSeconds
        let outroLength = duration - offset
        guard outroLength >= configuration.minOutroSeconds, offset >= configuration.minOutroSeconds,
            offset < duration * 0.95
        else { return nil }
        return offset
    }

    /// Loads `url` as mono and returns the last vocal offset, or `nil`.
    static func lastOffset(url: URL, configuration: Configuration = .init()) throws -> TimeInterval?
    {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { return nil }
            for frame in 0..<Int(buffer.frameLength) {
                var sumOfSquares: Float = 0
                for channel in 0..<channelCount {
                    let value = channels[channel][frame]
                    sumOfSquares += value * value
                }
                samples.append(
                    PhaseInvariantChannelEnergy.sample(
                        sumOfSquares: sumOfSquares, channelCount: channelCount))
            }
        }
        return lastOffset(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
    }
}

/// Resolves the effective vocal tail cutoff for lyric gating. `VocalOffsetDetector` can return `nil`
/// when bleed keeps energy above threshold until file end, or a value anchored on bleed *after* real
/// singing when a short silent outro follows the bleed. Strict-VAD body-end inference takes the
/// minimum with the detector so tail filters still clip at the last real vocal (~107.7s Summertime).
enum VocalTailCutoffResolver {
    struct Configuration: Sendable {
        var minOutroSeconds: TimeInterval = 0.75
        /// Trailing voiced blips shorter than this after a gap are treated as bleed, not singing.
        var trailingBlipMaxDuration: TimeInterval = 1.0
        var minBodyToBlipGap: TimeInterval = 0.5
        /// A strict-VAD voiced interval sustained at least this long AFTER the resolved cutoff is
        /// REAL SINGING (quiet outro lines), not bleed — the cutoff extends through it. Bleed
        /// blips are shorter; this keeps the level-aware offset detector from truncating real
        /// outro vocals (Settle Down: two sung lines at 220.8–229.8 were cut at ~220.4).
        var minRealSingingSeconds: TimeInterval = 1.5
    }

    /// Returns `(effectiveOffset, lastVoicedEndForGating)` for tail filters and VAD clipping.
    static func resolve(
        detectedOffset: TimeInterval?,
        strictVoicedIntervals: [ClosedRange<TimeInterval>],
        sourceDuration: TimeInterval?,
        configuration: Configuration = .init()
    ) -> (effectiveOffset: TimeInterval?, lastVoicedEnd: TimeInterval?) {
        let bodyEnd = inferredVocalBodyEnd(
            strictVoicedIntervals: strictVoicedIntervals,
            sourceDuration: sourceDuration,
            configuration: configuration)
        let effectiveOffset: TimeInterval?
        switch (detectedOffset, bodyEnd) {
        case (let detector?, let body?):
            effectiveOffset = min(detector, body)
        case (let detector?, nil):
            effectiveOffset = detector
        case (nil, let body?):
            effectiveOffset = body
        case (nil, nil):
            effectiveOffset = nil
        }
        guard let effectiveOffset else {
            let voicedEnd = strictVoicedIntervals.map(\.upperBound).max()
            return (nil, voicedEnd)
        }
        // Never cut REAL singing: sustained strict-voiced intervals past the cutoff are sung
        // phrases (quiet outro repeats), not bleed blips — extend the cutoff through them.
        // Deleting transcribed words is destructive (tasks/lessons.md 2026-06-25); the level-aware
        // offset detector can anchor on the last LOUD phrase while strict VAD still hears voice.
        var resolvedOffset = effectiveOffset
        let ascending = strictVoicedIntervals.sorted { $0.lowerBound < $1.lowerBound }
        for interval in ascending where interval.upperBound > resolvedOffset {
            if interval.upperBound - interval.lowerBound >= configuration.minRealSingingSeconds {
                resolvedOffset = interval.upperBound
            }
        }
        let clipped = VocalActivityEnvelope.voicedIntervalsForGating(
            strictVoicedIntervals, trailingCutoff: resolvedOffset)
        let lastVoicedEnd = clipped.map(\.upperBound).max() ?? resolvedOffset
        return (resolvedOffset, lastVoicedEnd)
    }

    private static func inferredVocalBodyEnd(
        strictVoicedIntervals: [ClosedRange<TimeInterval>],
        sourceDuration: TimeInterval?,
        configuration: Configuration
    ) -> TimeInterval? {
        guard !strictVoicedIntervals.isEmpty else { return nil }
        let sorted = strictVoicedIntervals.sorted { $0.lowerBound < $1.lowerBound }
        if sorted.count >= 2, let last = sorted.last {
            let previous = sorted[sorted.count - 2]
            let lastDuration = last.upperBound - last.lowerBound
            let gap = last.lowerBound - previous.upperBound
            if lastDuration <= configuration.trailingBlipMaxDuration,
                gap >= configuration.minBodyToBlipGap
            {
                return previous.upperBound
            }
        }
        if let last = sorted.last, let duration = sourceDuration,
            duration - last.upperBound >= configuration.minOutroSeconds,
            last.upperBound < duration * 0.95
        {
            return last.upperBound
        }
        return nil
    }
}

/// Detects instrumental ATTACK onsets (where the played sound actually changes) from an isolated
/// instrumental stem — the GUITAR stem when present, otherwise the "other"/accompaniment stem.
/// Used to snap chord-change times to where the instrumental truly changes, mirroring how the
/// vocal-onset work snaps lyrics to where the voice enters. Built from an energy-flux envelope
/// (positive first-difference of per-hop RMS), then peak-picked: a frame is an onset when it is a
/// local maximum, exceeds a threshold (above both the noise floor and a fraction of the peak), and
/// is at least `minSpacingSeconds` after the previous onset. Pure + unit tested; the file loader is
/// a thin wrapper.
enum InstrumentOnsetDetector {
    struct Configuration: Sendable {
        var windowSeconds: Double = 0.02
        var hopSeconds: Double = 0.01
        /// Seconds of flux each local threshold is computed over. Long enough to hold several
        /// attacks (so a threshold is not set by one of them), short enough to track a song's
        /// dynamics from verse to chorus.
        var thresholdWindowSeconds: Double = 2.0
        /// Multiple of the (scaled) MAD added to the local median. Same robust-statistics shape
        /// as `ChromaChangePointDetector`, but a much lower multiple: this runs on an energy
        /// envelope where real attacks are large outliers, not on a chroma distance curve.
        var thresholdMultiplier: Float = 2.5
        /// Absolute floor as a fraction of the whole-file peak flux, so digital silence cannot
        /// produce onsets from floating-point noise.
        var silenceFloorFraction: Float = 0.001
        /// Minimum spacing between successive onsets (de-bounces a single attack into one onset).
        var minSpacingSeconds: Double = 0.12
    }

    /// Onset times (seconds) where the instrumental energy rises sharply. Pure, deterministic, no
    /// I/O. Returns [] for degenerate input (empty, too short, zero sample rate, or no flux).
    static func onsets(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .init()
    ) -> [TimeInterval] {
        guard sampleRate > 0 else { return [] }
        let window = max(2, Int(sampleRate * configuration.windowSeconds))
        let hop = max(1, Int(sampleRate * configuration.hopSeconds))
        guard samples.count >= window else { return [] }

        // Per-hop RMS energy.
        var rms: [Float] = []
        var index = 0
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) {
                let value = samples[i]
                sum += value * value
            }
            rms.append((sum / Float(window)).squareRoot())
            index += hop
        }
        guard rms.count >= 2 else { return [] }

        // Energy flux: positive first-difference of the RMS envelope (a rising attack).
        var flux = [Float](repeating: 0, count: rms.count)
        for k in 1..<rms.count {
            flux[k] = max(0, rms[k] - rms[k - 1])
        }
        guard let peak = flux.max(), peak > 0 else { return [] }

        // LOCAL adaptive threshold: median + k*MAD of the flux within a rolling block, the same
        // robust shape `ChromaChangePointDetector` uses.
        //
        // This was a single global gate at `peak * 0.1` over the whole file. Two things were
        // wrong with that. The noise-floor term was dead: `flux` is
        // `max(0, rms[k] - rms[k-1])`, which is exactly 0 across every sustain, decay and
        // silence, so its 5th percentile is 0 and `noiseFloor * 3` was always 0 — the `max` only
        // ever resolved to the peak term. And a global gate keyed to the loudest frame in the
        // song means a verse 20 dB below the chorus clears no threshold at all: ZERO onsets
        // across the whole quiet passage. Downstream that is severe, because the chord decoder
        // loses its switch discount there and `ChordEvidenceAudit` then deletes those markers as
        // unsupported — chords vanish, systematically, exactly where the music is quiet.
        let thresholds = Self.adaptiveThresholds(
            flux: flux,
            blockHops: max(1, Int(configuration.thresholdWindowSeconds / configuration.hopSeconds)),
            multiplier: configuration.thresholdMultiplier,
            // An absolute floor so pure digital silence cannot manufacture onsets from float
            // noise. Two orders of magnitude below the old gate, so it binds only on silence.
            absoluteFloor: peak * configuration.silenceFloorFraction
        )

        // Peak-pick: local maxima above threshold, spaced at least `minSpacingSeconds` apart.
        let minSpacingHops = max(1, Int(configuration.minSpacingSeconds / configuration.hopSeconds))
        var onsets: [TimeInterval] = []
        var lastOnsetHop = -minSpacingHops - 1
        for k in flux.indices where flux[k] >= thresholds[k] {
            let prev = k > 0 ? flux[k - 1] : -Float.infinity
            let next = k + 1 < flux.count ? flux[k + 1] : -Float.infinity
            guard flux[k] >= prev, flux[k] >= next else { continue }  // local maximum
            guard k - lastOnsetHop >= minSpacingHops else { continue }
            onsets.append(Double(k * hop) / sampleRate)
            lastOnsetHop = k
        }
        return onsets
    }

    /// Onsets from several stems merged onto one timeline, de-duplicated so two stems hitting
    /// the same beat count once.
    ///
    /// Stems are loaded and released one at a time: peak memory is one stem, not one per stem,
    /// which matters because separation has already taken gigabytes by this point.
    ///
    /// `minimumSpacingSeconds` matches the per-stem de-bounce — two attacks closer than one
    /// de-bounce window apart are the same musical event heard through two separations, and
    /// counting it twice would overstate how densely the song is attacked.
    static func mergedOnsets(
        urls: [URL],
        configuration: Configuration = .init()
    ) -> [TimeInterval] {
        var all: [TimeInterval] = []
        for url in urls {
            guard let onsets = try? onsets(url: url, configuration: configuration) else { continue }
            all.append(contentsOf: onsets)
        }
        guard !all.isEmpty else { return [] }
        all.sort()
        var merged: [TimeInterval] = [all[0]]
        for time in all.dropFirst()
        where time - (merged.last ?? -.infinity) >= configuration.minSpacingSeconds {
            merged.append(time)
        }
        return merged
    }

    /// Per-frame thresholds from a block-local median + `multiplier` x (scaled) MAD.
    ///
    /// Blockwise rather than a true sliding window: a rolling median over every frame costs
    /// O(n * w) sorts for no benefit here, since the statistic only needs to track dynamics over
    /// seconds. Each block's threshold is computed from its own flux, so a quiet verse is judged
    /// against the quiet verse.
    static func adaptiveThresholds(
        flux: [Float],
        blockHops: Int,
        multiplier: Float,
        absoluteFloor: Float,
        // 0.5 of the block peak, not the 0.1 the global gate used. A block's peak is far smaller
        // than the whole file's, so the same fraction would be far more permissive; measured on
        // the ground-truth corpus, 0.25 flooded the decoder with onsets (guitar root F1 50.9 ->
        // 46.4, over-segmentation 2.34 -> 2.84) because every extra onset discounts the Viterbi's
        // switch penalty. 0.5 lands at 51.1 / 2.25 on the guitar arm — a wash against the global
        // gate on this corpus, while fixing a defect the corpus cannot see: quiet-passage attacks
        // that the global gate missed entirely (see the unit test).
        localPeakFraction: Float = 0.5
    ) -> [Float] {
        guard !flux.isEmpty else { return [] }
        var thresholds = [Float](repeating: absoluteFloor, count: flux.count)
        var start = 0
        while start < flux.count {
            let end = min(start + blockHops, flux.count)
            let block = Array(flux[start..<end]).sorted()
            let median = block[block.count / 2]
            let deviations = flux[start..<end].map { abs($0 - median) }.sorted()
            // 1.4826 scales MAD to approximate a normal standard deviation — the same
            // consistency constant `ChromaChangePointDetector` documents.
            let mad = deviations[deviations.count / 2] * 1.4826
            // A block that is mostly silence has median AND MAD of exactly 0 — flux is zero
            // across every sustain and rest — so `median + k*MAD` collapses to 0 and the bar
            // falls to the silence floor, firing on every ripple inside a burst. Hold a fraction
            // of the block's OWN peak as well. That keeps the original peak-relative idea but
            // makes it local, which was the whole point: a quiet verse is judged against the
            // quiet verse's peak, not the chorus's.
            let blockPeak = block[block.count - 1]
            let local = max(median + multiplier * mad, blockPeak * localPeakFraction)
            for index in start..<end { thresholds[index] = max(local, absoluteFloor) }
            start = end
        }
        return thresholds
    }

    /// Loads `url` as mono and returns its instrumental onset times, or [] on failure.
    static func onsets(url: URL, configuration: Configuration = .init()) throws -> [TimeInterval] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return []
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { return [] }
            for frame in 0..<Int(buffer.frameLength) {
                var sumOfSquares: Float = 0
                for channel in 0..<channelCount {
                    let value = channels[channel][frame]
                    sumOfSquares += value * value
                }
                samples.append(
                    PhaseInvariantChannelEnergy.sample(
                        sumOfSquares: sumOfSquares, channelCount: channelCount))
            }
        }
        return onsets(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
    }
}

/// Per-beat accent strengths from the drums stem, for downbeat (bar-phase) estimation at
/// analysis time. Mirrors the preview's `refreshGrid` beat-strength logic (max envelope energy
/// within ±quarter-beat of each beat) but runs on raw RMS instead of a display waveform, so the
/// harmony stage can feed `DownbeatEstimator.barPhase(beatStrengths:)` without any UI state.
enum DrumAccentProfile {
    /// Max per-hop RMS within ±`beatLength/4` of each beat. Pure, deterministic, no I/O.
    /// Returns [] for degenerate input.
    static func beatStrengths(
        beatTimes: [TimeInterval],
        rms: [Float],
        hopSeconds: Double,
        beatLength: TimeInterval
    ) -> [Double] {
        guard !beatTimes.isEmpty, !rms.isEmpty, hopSeconds > 0, beatLength > 0 else { return [] }
        let half = beatLength * 0.25
        return beatTimes.map { beat in
            let lo = max(0, Int((beat - half) / hopSeconds))
            let hi = min(rms.count, max(lo + 1, Int((beat + half) / hopSeconds) + 1))
            guard lo < rms.count else { return 0 }
            var peak: Float = 0
            for i in lo..<hi { peak = max(peak, rms[i]) }
            return Double(peak)
        }
    }

    /// Loads the drums stem as mono and returns per-beat accent strengths, or [] on failure.
    static func beatStrengths(
        url: URL,
        beatTimes: [TimeInterval],
        bpm: Double
    ) throws -> [Double] {
        guard bpm > 0 else { return [] }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return []
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { return [] }
            for frame in 0..<Int(buffer.frameLength) {
                var sumOfSquares: Float = 0
                for channel in 0..<channelCount {
                    let value = channels[channel][frame]
                    sumOfSquares += value * value
                }
                samples.append(
                    PhaseInvariantChannelEnergy.sample(
                        sumOfSquares: sumOfSquares, channelCount: channelCount))
            }
        }
        let hopSeconds = 0.02
        let rms = VocalRMSEnvelope.compute(
            samples: samples,
            sampleRate: format.sampleRate,
            windowSeconds: 0.05,
            hopSeconds: hopSeconds
        )
        return beatStrengths(
            beatTimes: beatTimes, rms: rms, hopSeconds: hopSeconds, beatLength: 60.0 / bpm)
    }
}

/// Snaps chord-change times to nearby instrumental onsets (from `InstrumentOnsetDetector`) so a
/// detected chord change lands exactly where the instrumental actually changes. Non-destructive:
/// the event count and order are preserved — each event is only moved in time, and never to a value
/// before the previous event (snapped times are clamped up to keep the sequence nondecreasing).
enum ChordOnsetAligner {
    /// For each event, if an onset lies within `tolerance` of its time, move the event to the
    /// nearest such onset; otherwise leave it. Order/count preserved; times stay nondecreasing.
    /// Returns events unchanged when `onsets` is empty.
    ///
    /// When `beatTimes` is provided, an event is NOT snapped if doing so would compress its
    /// gap to the previous event below `minimumBeatFraction` of the local beat while the
    /// original spacing was at least that — snapping must never manufacture the sub-beat
    /// slivers that `ChordEventDurationFilter` then deletes (which erased REAL chord changes:
    /// an A–B–A pair compressed by the nondecreasing clamp collapsed to a single A).
    static func snap(
        _ events: [EditableChordEvent],
        toOnsets onsets: [TimeInterval],
        tolerance: TimeInterval = 0.35,
        beatTimes: [TimeInterval] = [],
        minimumBeatFraction: Double = 0.8
    ) -> [EditableChordEvent] {
        guard !onsets.isEmpty, !events.isEmpty else { return events }
        let sortedOnsets = onsets.sorted()
        var result = events
        var floor = -TimeInterval.infinity
        for index in result.indices {
            let time = result[index].time
            // Nearest onset to this event's time.
            var nearest = sortedOnsets[0]
            for onset in sortedOnsets where abs(onset - time) < abs(nearest - time) {
                nearest = onset
            }
            var newTime = time
            if abs(nearest - time) <= tolerance {
                newTime = nearest
            }
            if index > 0, let beat = localBeatLength(at: time, beatTimes: beatTimes) {
                let minimumGap = beat * minimumBeatFraction
                let previous = result[index - 1].time
                if newTime - previous < minimumGap, time - previous >= minimumGap {
                    // Snapping would create a sliver the duration filter deletes; keep the
                    // decoder's beat-aligned time instead of losing the change downstream.
                    newTime = time
                }
            }
            // Keep the sequence nondecreasing so chord order is preserved.
            newTime = max(newTime, floor)
            result[index].time = newTime
            floor = newTime
        }
        return result
    }

    /// Length of the beat interval nearest `time`, or nil without a usable grid.
    private static func localBeatLength(
        at time: TimeInterval, beatTimes: [TimeInterval]
    ) -> TimeInterval? {
        guard beatTimes.count >= 2 else { return nil }
        var best: (distance: TimeInterval, length: TimeInterval)?
        for index in 0..<(beatTimes.count - 1) {
            let length = beatTimes[index + 1] - beatTimes[index]
            guard length > 0 else { continue }
            let distance = abs(beatTimes[index] - time)
            if best == nil || distance < best!.distance {
                best = (distance, length)
            }
        }
        return best?.length
    }
}

/// Finds sung regions the ASR produced no words for (audit RC-4, tasks/audit-ball-timing.md):
/// strict-VAD voiced intervals minus (padded) transcribed word coverage. On Summertime this is the
/// chorus-1 tail (49.8–55.4), the verse-2 lead-in (58.1–61.7), and two outro vocal passages — all
/// silently mislabeled "Instrumental"/"Outro" today. Consumers use these to render a distinct
/// "vocals — not transcribed" row instead of an instrumental one, and to bound real break windows.
enum UntranscribedVocalRegionDetector {
    static func regions(
        voicedIntervals: [ClosedRange<TimeInterval>],
        lyrics: [TimedLyricSegment],
        minimumDuration: TimeInterval = 1.5,
        wordPadding: TimeInterval = 0.25
    ) -> [ClosedRange<TimeInterval>] {
        regions(
            voicedIntervals: voicedIntervals,
            wordSpans: lyrics.flatMap(\.words).map { $0.start...max($0.start, $0.end) },
            minimumDuration: minimumDuration,
            wordPadding: wordPadding)
    }

    /// The same regions from bare word time spans (raw transcription tokens, before grouping).
    static func regions(
        voicedIntervals: [ClosedRange<TimeInterval>],
        wordSpans: [ClosedRange<TimeInterval>],
        minimumDuration: TimeInterval = 1.5,
        wordPadding: TimeInterval = 0.25
    ) -> [ClosedRange<TimeInterval>] {
        guard !voicedIntervals.isEmpty else { return [] }
        // Padded, merged word coverage — every span the transcription accounts for.
        let covered: [ClosedRange<TimeInterval>] = merged(
            wordSpans.map {
                (max($0.lowerBound - wordPadding, 0))...($0.upperBound + wordPadding)
            }
        )
        var result: [ClosedRange<TimeInterval>] = []
        for voiced in merged(voicedIntervals) {
            var cursor = voiced.lowerBound
            for span in covered where span.upperBound > voiced.lowerBound {
                if span.lowerBound >= voiced.upperBound { break }
                if span.lowerBound - cursor >= minimumDuration {
                    result.append(cursor...span.lowerBound)
                }
                cursor = max(cursor, span.upperBound)
            }
            if voiced.upperBound - cursor >= minimumDuration {
                result.append(cursor...voiced.upperBound)
            }
        }
        return result
    }

    /// Sorted union of possibly-overlapping closed ranges.
    private static func merged(
        _ ranges: [ClosedRange<TimeInterval>]
    ) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Splits an ASR line that actually contains TWO sung phrases separated by a real musical pause.
/// Whisper sometimes emits one segment for e.g. "She makes me want to settle down, trading my
/// rowdy friends" with a ~1.7 s silent gap in the middle — the grouper preserves the segment, and
/// the chart shows one double-length line where every other chorus shows two. Splits at internal
/// word gaps that are LONG (≥ `minimumGap`) and mostly UNVOICED (a held note never splits — see
/// `VocalWordSpanNormalizer`), when both sides keep a plausible phrase (`minimumWordsPerSide`).
/// Recursive, so a line holding three phrases splits fully. Text and character ranges are sliced
/// exactly; word timings are untouched.
enum IntraLinePauseSplitter {
    static func split(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        minimumGap: TimeInterval = 1.0,
        maximumVoicedFraction: Double = 0.5,
        minimumWordsPerSide: Int = 4
    ) -> [TimedLyricSegment] {
        guard !segments.isEmpty, !voicedIntervals.isEmpty else { return segments }
        return segments.flatMap {
            splitRecursively(
                $0,
                voicedIntervals: voicedIntervals,
                minimumGap: minimumGap,
                maximumVoicedFraction: maximumVoicedFraction,
                minimumWordsPerSide: minimumWordsPerSide)
        }
    }

    private static func splitRecursively(
        _ segment: TimedLyricSegment,
        voicedIntervals: [ClosedRange<TimeInterval>],
        minimumGap: TimeInterval,
        maximumVoicedFraction: Double,
        minimumWordsPerSide: Int
    ) -> [TimedLyricSegment] {
        let words = segment.words
        guard words.count >= minimumWordsPerSide * 2 else { return [segment] }
        // The widest qualifying pause wins (phrase boundaries are the biggest gaps).
        var best: (index: Int, gap: TimeInterval)?
        for index in (minimumWordsPerSide - 1)..<(words.count - minimumWordsPerSide) {
            let gapStart = words[index].end
            let gapEnd = words[index + 1].start
            let gap = gapEnd - gapStart
            guard gap >= minimumGap else { continue }
            let voiced = voicedCoverage(from: gapStart, to: gapEnd, in: voicedIntervals)
            guard voiced / gap <= maximumVoicedFraction else { continue }
            if gap > (best?.gap ?? 0) { best = (index, gap) }
        }
        guard let best else { return [segment] }

        let leftWords = Array(words[...best.index])
        let rightWordsRaw = Array(words[(best.index + 1)...])
        let characters = Array(segment.text)
        let leftEnd = min(max(leftWords.last!.characterRange.upperBound, 0), characters.count)
        let rightStart = min(
            max(rightWordsRaw.first!.characterRange.lowerBound, 0), characters.count)
        let leftText = String(characters[..<leftEnd])
        let rightText = String(characters[rightStart...])
        // Right-hand character ranges shift to the new text origin.
        let rightWords = rightWordsRaw.map { word -> TimedLyricWord in
            var shifted = word
            let lower = max(word.characterRange.lowerBound - rightStart, 0)
            let upper = max(word.characterRange.upperBound - rightStart, lower)
            shifted.characterRange = lower..<upper
            return shifted
        }
        let left = TimedLyricSegment(
            start: leftWords.first!.start,
            end: max(leftWords.last!.end, leftWords.first!.start + 0.01),
            text: leftText.trimmingCharacters(in: .whitespaces),
            words: leftWords)
        let right = TimedLyricSegment(
            start: rightWords.first!.start,
            end: max(segment.end, rightWords.last!.end),
            text: rightText.trimmingCharacters(in: .whitespaces),
            words: rightWords)
        return splitRecursively(
            left, voicedIntervals: voicedIntervals, minimumGap: minimumGap,
            maximumVoicedFraction: maximumVoicedFraction,
            minimumWordsPerSide: minimumWordsPerSide)
            + splitRecursively(
                right, voicedIntervals: voicedIntervals, minimumGap: minimumGap,
                maximumVoicedFraction: maximumVoicedFraction,
                minimumWordsPerSide: minimumWordsPerSide)
    }

    private static func voicedCoverage(
        from start: TimeInterval,
        to end: TimeInterval,
        in intervals: [ClosedRange<TimeInterval>]
    ) -> TimeInterval {
        intervals.reduce(0) { total, interval in
            let lo = max(start, interval.lowerBound)
            let hi = min(end, interval.upperBound)
            return total + max(0, hi - lo)
        }
    }
}

/// Repairs ASR melisma artifacts INSIDE a line (audit RC-3, tasks/audit-ball-timing.md):
/// Whisper gives a held/stretched word a tiny span at its onset ("Sitting" 35.02–35.10) and often
/// places the NEXT word's onset late, so the chart renders a multi-beat "pause" where the voice
/// never stops. One conservative rule against the strict-VAD voiced intervals:
///
/// - Melisma bridge: a ≥ `minimumGap` inter-word gap that is CONTINUOUSLY voiced
///   (≥ `melismaVoicedFraction`) is a held word, not a pause → extend `word.end` to the next
///   word's onset.
///
/// Never deletes or reorders tokens (see tasks/lessons.md 2026-06-25) and never moves a start
/// (Eric, 2026-09-14: "There should be NO shifting code"); only extends word ends. Segment
/// `start`/`end` are re-derived from the adjusted words. No-op without voiced intervals.
enum VocalWordSpanNormalizer {
    static func normalized(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        minimumGap: TimeInterval = 0.4,
        melismaVoicedFraction: Double = 0.8
    ) -> [TimedLyricSegment] {
        guard !segments.isEmpty, !voicedIntervals.isEmpty else { return segments }
        let sortedIntervals = voicedIntervals.sorted { $0.lowerBound < $1.lowerBound }
        var result = segments
        for index in result.indices {
            var words = result[index].words
            guard words.count >= 2 else { continue }
            for wordIndex in 0..<(words.count - 1) {
                let gapStart = words[wordIndex].end
                let gapEnd = words[wordIndex + 1].start
                let gap = gapEnd - gapStart
                guard gap >= minimumGap else { continue }
                let voicedFraction =
                    voicedCoverage(
                        from: gapStart, to: gapEnd, in: sortedIntervals) / gap
                if voicedFraction >= melismaVoicedFraction {
                    // Held word: the voice never stops between the two onsets.
                    words[wordIndex].end = gapEnd
                }
            }
            result[index].words = words
            result[index].start = words.first!.start
            result[index].end = max(result[index].end, words.last!.end)
        }
        return result
    }

    private static func voicedCoverage(
        from start: TimeInterval,
        to end: TimeInterval,
        in intervals: [ClosedRange<TimeInterval>]
    ) -> TimeInterval {
        intervals.reduce(0) { total, interval in
            let lo = max(start, interval.lowerBound)
            let hi = min(end, interval.upperBound)
            return total + max(0, hi - lo)
        }
    }
}

/// Extends line-final held notes (Back to New Orleans, 2026-09-14): Whisper ends a sustained last
/// word near its onset, so 8 of 40 lines stopped 0.5–2.9 s before the voice did.
/// `VocalWordSpanNormalizer` only bridges gaps INSIDE a line; this stretches each line's last word
/// through the sung interval it ends inside, never into the next line and never by more than
/// `maximumExtension`. Line starts are left alone: voice before a line's first word is as likely an
/// untranscribed pickup as a late onset, and stretching the word over it would mistime it.
enum LineTailSustainExtender {
    static func extended(
        _ segments: [TimedLyricSegment],
        sungIntervals: [ClosedRange<TimeInterval>],
        maximumExtension: TimeInterval = 4,
        nextLineMargin: TimeInterval = 0.05
    ) -> [TimedLyricSegment] {
        guard !sungIntervals.isEmpty else { return segments }
        var result = segments
        for index in result.indices {
            guard let last = result[index].words.last,
                // ponytail: linear scan per line; a song has tens of lines and intervals.
                let held = sungIntervals.first(where: {
                    $0.lowerBound <= last.end && $0.upperBound > last.end
                })
            else { continue }
            var limit = min(held.upperBound, last.end + maximumExtension)
            if index + 1 < result.count {
                let next = result[index + 1]
                limit = min(limit, (next.words.first?.start ?? next.start) - nextLineMargin)
            }
            guard limit > last.end else { continue }
            result[index].words[result[index].words.count - 1].end = limit
            result[index].end = max(result[index].end, limit)
        }
        return result
    }
}

/// Monotonic, one-to-one assignment between ASR words and detected vocal attacks.
///
/// Independent nearest-neighbour matching lets one energy burst "support" several adjacent words.
/// Moving the duplicates a fixed number of milliseconds apart only fabricates precision. This
/// sequence matcher instead maximizes the number of distinct word/onset pairs, then minimizes total
/// displacement from the ASR timings. Words without their own supported onset remain untouched.
enum VocalOnsetMatcher {
    private struct Score {
        var matches: Int
        var error: TimeInterval
    }

    private enum Step: UInt8 {
        case none
        case skipWord
        case skipOnset
        case match
    }

    static func matchedOnsets(
        for words: [TimedLyricWord],
        onsets: [TimeInterval],
        tolerance: TimeInterval
    ) -> [TimeInterval?] {
        guard !words.isEmpty, !onsets.isEmpty, tolerance >= 0 else {
            return [TimeInterval?](repeating: nil, count: words.count)
        }
        let minimumWordStart = words.map(\.start).min() ?? 0
        let maximumWordStart = words.map(\.start).max() ?? minimumWordStart
        let relevantOnsets = Array(
            Set(
                onsets.filter {
                    $0 >= minimumWordStart - tolerance && $0 <= maximumWordStart + tolerance
                })
        ).sorted()
        guard !relevantOnsets.isEmpty else {
            return [TimeInterval?](repeating: nil, count: words.count)
        }

        let rowWidth = relevantOnsets.count + 1
        let cellCount = (words.count + 1) * rowWidth
        var scores = [Score?](repeating: nil, count: cellCount)
        var steps = [Step](repeating: .none, count: cellCount)
        func offset(_ wordCount: Int, _ onsetCount: Int) -> Int {
            wordCount * rowWidth + onsetCount
        }
        scores[offset(0, 0)] = Score(matches: 0, error: 0)
        for onsetCount in 1...relevantOnsets.count {
            scores[offset(0, onsetCount)] = Score(matches: 0, error: 0)
            steps[offset(0, onsetCount)] = .skipOnset
        }
        for wordCount in 1...words.count {
            scores[offset(wordCount, 0)] = Score(matches: 0, error: 0)
            steps[offset(wordCount, 0)] = .skipWord
        }

        for wordCount in 1...words.count {
            let word = words[wordCount - 1]
            for onsetCount in 1...relevantOnsets.count {
                let index = offset(wordCount, onsetCount)
                let skipWordScore = scores[offset(wordCount - 1, onsetCount)]!
                var best = skipWordScore
                var bestStep = Step.skipWord

                let skipOnsetScore = scores[offset(wordCount, onsetCount - 1)]!
                if isBetter(skipOnsetScore, than: best) {
                    best = skipOnsetScore
                    bestStep = .skipOnset
                }

                let onset = relevantOnsets[onsetCount - 1]
                let latestStart =
                    word.end > word.start ? word.end - 0.01 : TimeInterval.infinity
                if abs(onset - word.start) <= tolerance, onset <= latestStart,
                    let preceding = scores[offset(wordCount - 1, onsetCount - 1)]
                {
                    let matched = Score(
                        matches: preceding.matches + 1,
                        error: preceding.error + abs(onset - word.start))
                    if isBetter(matched, than: best) {
                        best = matched
                        bestStep = .match
                    }
                }
                scores[index] = best
                steps[index] = bestStep
            }
        }

        var result = [TimeInterval?](repeating: nil, count: words.count)
        var wordCount = words.count
        var onsetCount = relevantOnsets.count
        while wordCount > 0 || onsetCount > 0 {
            switch steps[offset(wordCount, onsetCount)] {
            case .match:
                result[wordCount - 1] = relevantOnsets[onsetCount - 1]
                wordCount -= 1
                onsetCount -= 1
            case .skipWord:
                wordCount -= 1
            case .skipOnset:
                onsetCount -= 1
            case .none:
                wordCount = 0
                onsetCount = 0
            }
        }

        // A matched onset can cross an unmatched neighbour's original ASR time. Reject only the
        // conflicting match; preserving an ASR onset is preferable to manufacturing a new one.
        var changed = true
        while changed {
            changed = false
            let starts = words.indices.map { result[$0] ?? words[$0].start }
            guard starts.count > 1 else { break }
            for index in 1..<starts.count where starts[index] < starts[index - 1] {
                if result[index] != nil {
                    result[index] = nil
                    changed = true
                    break
                }
                if result[index - 1] != nil {
                    result[index - 1] = nil
                    changed = true
                    break
                }
            }
        }
        return result
    }

    private static func isBetter(_ candidate: Score, than incumbent: Score) -> Bool {
        if candidate.matches != incumbent.matches {
            return candidate.matches > incumbent.matches
        }
        return candidate.error < incumbent.error - 1e-9
    }
}

/// Snaps each sung word's onset to a distinct nearby vocal-stem onset (from
/// `InstrumentOnsetDetector` run on the vocals stem), so words and their timeline consumers sit on
/// observed vocal energy instead of approximate ASR onsets. Word/segment count, order, text, and
/// unmatched ASR starts are preserved. Each segment's bounds are re-derived from its final words.
enum VocalWordOnsetAligner {
    static func snapped(
        _ segments: [TimedLyricSegment],
        toOnsets onsets: [TimeInterval],
        tolerance: TimeInterval = 0.15
    ) -> [TimedLyricSegment] {
        guard !onsets.isEmpty, !segments.isEmpty else { return segments }
        var result = segments
        for segmentIndex in result.indices {
            guard !result[segmentIndex].words.isEmpty else { continue }
            var words = result[segmentIndex].words
            let matched = VocalOnsetMatcher.matchedOnsets(
                for: words, onsets: onsets, tolerance: tolerance)
            for wordIndex in words.indices {
                if let onset = matched[wordIndex] {
                    words[wordIndex].start = onset
                }
            }
            result[segmentIndex].words = words
            result[segmentIndex].start = words.map(\.start).min() ?? result[segmentIndex].start
            let latestEnd = words.map(\.end).max() ?? result[segmentIndex].end
            result[segmentIndex].end = max(latestEnd, result[segmentIndex].start + 0.01)
        }
        return result
    }
}

/// Drops ASR segments and tokens after the detected vocal offset (outro hallucinations). Word times
/// are never changed.
enum TranscriptionOnsetCorrection {
    /// Drops whole ASR segments whose start is at/after the vocal `offset` (outro hallucinations).
    /// Stricter than token-level drop: a segment that begins in bleed after the last real vocal is
    /// removed entirely even when Whisper back-dates a few tokens before the offset.
    static func preparedSegments(
        _ segments: [TimedTranscriptionSegment],
        droppingSegmentsStartingAtOrAfter offset: TimeInterval
    ) -> [TimedTranscriptionSegment] {
        segments.filter { $0.startTime < offset }
    }

    /// Drops tokens that start at/after the detected vocal `offset` (outro hallucinations). No-op when
    /// `offset` is nil. Preserves lines that straddle the boundary (keeps words starting before).
    static func preparedSegments(
        _ segments: [TimedTranscriptionSegment],
        droppingAfter offset: TimeInterval
    ) -> [TimedTranscriptionSegment] {
        return segments.compactMap { segment in
            let kept = segment.tokens.filter { $0.startTime < offset }
            guard !kept.isEmpty else { return nil }
            return TimedTranscriptionSegment(
                text: kept.map(\.text).joined(separator: " "),
                startTime: kept.first?.startTime ?? segment.startTime,
                endTime: kept.last?.endTime ?? segment.endTime,
                tokens: kept,
                confidence: segment.confidence
            )
        }
    }
}

/// One word timing the stretched-word check acted on, kept on the song so the Review chart can mark
/// it for spot-checking. Matched back to its word by start time and text.
struct WordTimingFinding: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The start moved to a vocal attack inside the word. No longer produced; saved songs decode.
        case retimed
        /// Stretched and the vocals were vague: the start moved to the attack nearest where the
        /// word's rhymes land in the bar.
        case rhymeAligned
        /// Stretched, but no clear attack to move to: flagged only.
        case suspect
    }
    var kind: Kind
    var text: String
    /// The word's start as it now stands — where the chart finds it.
    var start: TimeInterval
    /// The transcriber's start.
    var transcribedStart: TimeInterval
}

/// Reads an audio file as one mono channel (channels averaged), with its sample rate.
enum MonoAudioFile {
    static func samples(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return ([], format.sampleRate)
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = max(Int(format.channelCount), 1)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][frame] }
                samples.append(sum / Float(channelCount))
            }
        }
        return (samples, format.sampleRate)
    }
}

/// The vocals stem's loudness in dB on a 10 ms hop, for judging how hard the voice ATTACKS at a
/// moment. Attack strength, not onset detection: `InstrumentOnsetDetector` also fires on consonant
/// flickers, and `VocalWordOnsetAligner` has usually snapped a word's start onto one of those, so
/// "is there an onset at the start" can't tell a stretched word from a correct one.
struct VocalAttackEnvelope: Sendable {
    let decibels: [Float]
    let hopSeconds: TimeInterval

    init(decibels: [Float], hopSeconds: TimeInterval) {
        self.decibels = decibels
        self.hopSeconds = hopSeconds
    }

    init(samples: [Float], sampleRate: Double) {
        let rms = VocalRMSEnvelope.compute(
            samples: samples, sampleRate: sampleRate, windowSeconds: 0.02, hopSeconds: 0.01)
        self.init(decibels: rms.map { 20 * log10(max($0, 1e-6)) }, hopSeconds: 0.01)
    }

    static func load(url: URL) throws -> VocalAttackEnvelope {
        let audio = try MonoAudioFile.samples(url: url)
        return VocalAttackEnvelope(samples: audio.samples, sampleRate: audio.sampleRate)
    }

    /// The sharpest loudness rise over `riseFrames` hops (30 ms) that completes within
    /// `[start, end]`, and the moment that rise begins.
    func sharpestRise(
        from start: TimeInterval, to end: TimeInterval, riseFrames: Int = 3
    ) -> (time: TimeInterval, rise: Float)? {
        guard hopSeconds > 0 else { return nil }
        let first = max(riseFrames, Int((start / hopSeconds).rounded(.up)))
        let last = min(decibels.count - 1, Int((end / hopSeconds).rounded(.down)))
        guard first <= last else { return nil }
        var best: (time: TimeInterval, rise: Float)?
        for frame in first...last {
            let rise = decibels[frame] - decibels[frame - riseFrames]
            if rise > (best?.rise ?? -.infinity) {
                best = (Double(frame - riseFrames + 1) * hopSeconds, rise)
            }
        }
        return best
    }

    /// Loudness in dB at `time`, or nil outside the envelope.
    func level(at time: TimeInterval) -> Float? {
        guard hopSeconds > 0 else { return nil }
        let frame = Int((time / hopSeconds).rounded())
        return decibels.indices.contains(frame) ? decibels[frame] : nil
    }

    /// The loudest level in `[start, end]`, or nil when the span holds no frames.
    func loudest(from start: TimeInterval, to end: TimeInterval) -> Float? {
        guard hopSeconds > 0 else { return nil }
        let first = max(0, Int((start / hopSeconds).rounded(.up)))
        let last = min(decibels.count - 1, Int((end / hopSeconds).rounded(.down)))
        guard first <= last else { return nil }
        return decibels[first...last].max()
    }

    /// Every attack in `[start, end]` rising at least `minimumRise` dB over `riseFrames` hops, as
    /// local peaks at least `minimumSpacing` apart (the stronger of two close peaks wins).
    func attacks(
        from start: TimeInterval, to end: TimeInterval, minimumRise: Float, riseFrames: Int = 3,
        minimumSpacing: TimeInterval = 0.12
    ) -> [(time: TimeInterval, rise: Float)] {
        guard hopSeconds > 0 else { return [] }
        let first = max(riseFrames, Int((start / hopSeconds).rounded(.up)))
        let last = min(decibels.count - 1, Int((end / hopSeconds).rounded(.down)))
        guard first <= last else { return [] }
        func rise(_ frame: Int) -> Float { decibels[frame] - decibels[frame - riseFrames] }
        var found: [(time: TimeInterval, rise: Float)] = []
        for frame in first...last {
            let value = rise(frame)
            guard value >= minimumRise,
                frame == first || value >= rise(frame - 1),
                frame == last || value > rise(frame + 1)
            else { continue }
            let time = Double(frame - riseFrames + 1) * hopSeconds
            if let previous = found.last, time - previous.time < minimumSpacing {
                if value > previous.rise { found[found.count - 1] = (time, value) }
            } else {
                found.append((time, value))
            }
        }
        return found
    }
}

/// Flags the transcriber's STRETCHED words for spot-checking (Eric, 2026-09-14: "…Louisiana breeze"
/// looked like 4–5 beats of silence before "I'm going back"). Whisper glues a held word's start to
/// the previous word's end and stretches it to the next line.
///
/// A word is stretched when its start is glued to the previous word's end and it lasts at least
/// `minimumSeconds` and `minimumBeats`. A stretched word whose start has no strong vocal attack is
/// flagged `.suspect`. Word times never change (Eric: "There should be NO shifting code"): this
/// pass used to move such starts onto an attack inside the word or toward the rhyme position, which
/// pushed Beach Weather's "places" 3.6 s past where all three transcribers heard it.
enum StretchedWordRetimer {
    /// Bump when the rule changes, so stored songs are checked again.
    // 2: squashed runs are spread across their singing (pass 0).
    // 3: pass 0 removed.
    // 4: flag only; no word moves.
    static let versionTag = "stretched-words-4"

    static func retimed(
        _ segments: [TimedLyricSegment],
        attacks: VocalAttackEnvelope,
        beatLength: TimeInterval?,
        glueTolerance: TimeInterval = 0.03,
        minimumSeconds: TimeInterval = 1.0,
        minimumBeats: Double = 2,
        startWindow: TimeInterval = 0.1,
        minimumRise: Float = 6
    ) -> (segments: [TimedLyricSegment], findings: [WordTimingFinding]) {
        let minimumLength = max(minimumSeconds, (beatLength ?? 0) * minimumBeats)
        var findings: [WordTimingFinding] = []
        for segment in segments {
            for (previous, word) in zip(segment.words, segment.words.dropFirst()) {
                let startRise =
                    attacks.sharpestRise(
                        from: word.start - startWindow, to: word.start + startWindow)?.rise ?? 0
                guard abs(word.start - previous.end) <= glueTolerance,
                    word.end - word.start >= minimumLength, startRise < minimumRise
                else { continue }
                findings.append(
                    WordTimingFinding(
                        kind: .suspect, text: word.text, start: word.start,
                        transcribedStart: word.start))
            }
        }
        return (segments, findings.sorted { $0.start < $1.start })
    }
}

/// Voice-activity envelope over an ISOLATED vocals stem: the time intervals where singing is
/// actually present, separated by the silent gaps (pauses). Built from short-window RMS energy
/// with hysteresis and minimum voiced/gap durations so it produces clean intervals rather than
/// chattering. Intended first to be SHOWN (overlaid on the waveform) so the detection can be
/// judged, then used to correct lyric timing so words respect the pauses. Pure + unit tested.
enum VocalActivityEnvelope {
    struct Configuration: Sendable {
        var windowSeconds: Double = 0.04
        var hopSeconds: Double = 0.02
        /// Fraction of peak RMS for the enter threshold (combined with the noise floor).
        var peakFraction: Float = 0.06
        /// Multiple of the noise floor the signal must exceed to count as voiced.
        var noiseFloorMultiple: Float = 3
        /// Hysteresis: once voiced, stay voiced until energy drops below `enter * exitFraction`.
        var exitFraction: Float = 0.6
        /// Voiced runs shorter than this are dropped (clicks/transients).
        var minVoicedSeconds: Double = 0.08
        /// Gaps shorter than this are bridged (don't split a word on a brief dip).
        var minGapSeconds: Double = 0.15
        /// Minimum fraction of median sung-frame RMS (see `VocalEnergyThreshold`).
        var vocalBodyFraction: Float = 0.30

        /// High relative-energy threshold for vocal-presence gating and alignment on the vocals stem
        /// (or full mix when stems are absent). Bleed from guitar/drums should not count as singing.
        static let strictVocalPresence = Configuration(
            peakFraction: 0.20,
            noiseFloorMultiple: 5,
            minVoicedSeconds: 0.18,
            vocalBodyFraction: 0.25
        )
    }

    static func voicedIntervals(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .init()
    ) -> [ClosedRange<TimeInterval>] {
        guard sampleRate > 0 else { return [] }
        let rms = VocalRMSEnvelope.compute(
            samples: samples,
            sampleRate: sampleRate,
            windowSeconds: configuration.windowSeconds,
            hopSeconds: configuration.hopSeconds)
        guard
            let enter = VocalEnergyThreshold.enterThreshold(
                rms: rms,
                parameters: .init(
                    peakFraction: configuration.peakFraction,
                    noiseFloorMultiple: configuration.noiseFloorMultiple,
                    vocalBodyFraction: configuration.vocalBodyFraction))
        else { return [] }
        let hop = max(1, Int(sampleRate * configuration.hopSeconds))
        let exit = enter * configuration.exitFraction

        // Hysteresis: enter voiced at `enter`, leave only when energy drops below `exit`.
        var voiced = [Bool](repeating: false, count: rms.count)
        var active = false
        for k in rms.indices {
            if active {
                if rms[k] < exit { active = false }
            } else if rms[k] >= enter {
                active = true
            }
            voiced[k] = active
        }

        func time(_ windowIndex: Int) -> TimeInterval { Double(windowIndex * hop) / sampleRate }
        var intervals: [ClosedRange<TimeInterval>] = []
        var runStart: Int?
        for k in voiced.indices {
            if voiced[k] {
                if runStart == nil { runStart = k }
            } else if let start = runStart {
                intervals.append(time(start)...time(k))
                runStart = nil
            }
        }
        if let start = runStart { intervals.append(time(start)...time(voiced.count)) }

        // Bridge short gaps, then drop short voiced blips.
        var merged: [ClosedRange<TimeInterval>] = []
        for interval in intervals {
            if let last = merged.last,
                interval.lowerBound - last.upperBound < configuration.minGapSeconds
            {
                merged[merged.count - 1] = last.lowerBound...interval.upperBound
            } else {
                merged.append(interval)
            }
        }
        return merged.filter {
            $0.upperBound - $0.lowerBound >= configuration.minVoicedSeconds
        }
    }

    /// Strict voiced intervals clipped to `[0, trailingCutoff]` for gating/distribution at the song
    /// tail. Bleed-only energy after the last real vocal offset must not keep hallucinated lines.
    static func voicedIntervalsForGating(
        _ intervals: [ClosedRange<TimeInterval>],
        trailingCutoff: TimeInterval?
    ) -> [ClosedRange<TimeInterval>] {
        guard let cutoff = trailingCutoff else { return intervals }
        return intervals.compactMap { interval in
            guard interval.lowerBound < cutoff else { return nil }
            let end = min(interval.upperBound, cutoff)
            return end > interval.lowerBound ? interval.lowerBound...end : nil
        }
    }

    /// Loads `url` as mono and returns its voiced intervals, or [] on failure.
    static func voicedIntervals(
        url: URL, configuration: Configuration = .init()
    ) throws -> [ClosedRange<TimeInterval>] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return []
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { return [] }
            for frame in 0..<Int(buffer.frameLength) {
                var sumOfSquares: Float = 0
                for channel in 0..<channelCount {
                    let value = channels[channel][frame]
                    sumOfSquares += value * value
                }
                samples.append(
                    PhaseInvariantChannelEnergy.sample(
                        sumOfSquares: sumOfSquares, channelCount: channelCount))
            }
        }
        return voicedIntervals(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
    }
}

/// Pitch-salience singing detector, used ONLY by the untranscribed-vocals path (audit RC-4) and
/// therefore by the review panel's "vocals — not transcribed" flags. The energy-only strict VAD
/// fails that consumer in BOTH directions: separation bleed during loud full-band passages
/// clears an energy gate (phantom flags on true instrumentals), while soft melodic vocals —
/// Settle Down's doo-doo intro — sit far below the peak-relative gate and are never flagged at
/// all. Singing is strongly PERIODIC where stem residue is not, so each window's evidence here
/// is its maximum normalized autocorrelation over vocal-range lags, with an energy floor set
/// deliberately far below strict VAD's — quiet singing is the point.
///
/// Meaningful only on an isolated vocals stem; on a full mix everything is pitched, so callers
/// without stems must keep using the strict VAD.
enum VocalPitchSalience {
    struct Configuration: Sendable {
        var windowSeconds: Double = 0.04
        var hopSeconds: Double = 0.02
        /// Autocorrelation runs on a boxcar-decimated copy near this rate — pitch in the vocal
        /// range survives, and the lag scan cost drops by the square of the factor.
        var decimatedRate: Double = 8_000
        var minimumFrequency: Double = 80
        var maximumFrequency: Double = 800
        /// Normalized autocorrelation at/above this counts as pitched: sung voice measures
        /// ~0.6–0.9, broadband separation residue well under 0.4 (white-noise NAC at this
        /// window size is ~10 sigma below the bar).
        var minimumSalience: Float = 0.55
        /// The ONLY energy gate: reject near-digital silence, nothing more. Pitch does the
        /// rejecting here — `VocalEnergyThreshold`-style relative floors were tried and gated
        /// out exactly the quiet singing this detector exists to catch (its quiet-frame
        /// median IS the soft vocal on a mostly-instrumental stem).
        var silenceFloorPeakFraction: Float = 0.005
        /// Sung phrases are sustained; isolated pitched blips (a string ringing through) drop.
        var minVoicedSeconds: Double = 0.30
        var minGapSeconds: Double = 0.25
    }

    static func sungIntervals(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .init()
    ) -> [ClosedRange<TimeInterval>] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        // Boxcar decimation.
        let factor = max(1, Int(sampleRate / configuration.decimatedRate))
        var decimated: [Float] = []
        decimated.reserveCapacity(samples.count / factor + 1)
        var index = 0
        while index + factor <= samples.count {
            var sum: Float = 0
            for offset in 0..<factor { sum += samples[index + offset] }
            decimated.append(sum / Float(factor))
            index += factor
        }
        let rate = sampleRate / Double(factor)
        let window = max(32, Int(rate * configuration.windowSeconds))
        let hop = max(1, Int(rate * configuration.hopSeconds))
        let minLag = max(2, Int(rate / configuration.maximumFrequency))
        let maxLag = max(minLag + 1, Int(rate / configuration.minimumFrequency))
        guard decimated.count > window + maxLag else { return [] }

        // Silence-only energy floor (see `silenceFloorPeakFraction`).
        let rms = VocalRMSEnvelope.compute(
            samples: decimated, sampleRate: rate,
            windowSeconds: configuration.windowSeconds,
            hopSeconds: configuration.hopSeconds)
        guard let peak = rms.max(), peak > 0 else { return [] }
        let enter = peak * configuration.silenceFloorPeakFraction

        let windowCount = min(rms.count, (decimated.count - window - maxLag) / hop + 1)
        var sung = [Bool](repeating: false, count: windowCount)
        for k in 0..<windowCount {
            guard rms[k] >= enter else { continue }
            let start = k * hop
            // Mean-removed normalized autocorrelation, best peak over the vocal lag range.
            var mean: Float = 0
            for i in start..<(start + window + maxLag) { mean += decimated[i] }
            mean /= Float(window + maxLag)
            var best: Float = 0
            var e1: Float = 0
            for i in 0..<window {
                let v = decimated[start + i] - mean
                e1 += v * v
            }
            guard e1 > 0 else { continue }
            for lag in minLag...maxLag {
                var cross: Float = 0
                var e2: Float = 0
                for i in 0..<window {
                    let a = decimated[start + i] - mean
                    let b = decimated[start + i + lag] - mean
                    cross += a * b
                    e2 += b * b
                }
                guard e2 > 0 else { continue }
                let nac = cross / (e1 * e2).squareRoot()
                if nac > best { best = nac }
            }
            sung[k] = best >= configuration.minimumSalience
        }

        // Windows → merged intervals (same shape as VocalActivityEnvelope's tail).
        func time(_ windowIndex: Int) -> TimeInterval { Double(windowIndex * hop) / rate }
        var intervals: [ClosedRange<TimeInterval>] = []
        var runStart: Int?
        for k in sung.indices {
            if sung[k] {
                if runStart == nil { runStart = k }
            } else if let start = runStart {
                intervals.append(time(start)...time(k))
                runStart = nil
            }
        }
        if let start = runStart { intervals.append(time(start)...time(sung.count)) }
        var merged: [ClosedRange<TimeInterval>] = []
        for interval in intervals {
            if let last = merged.last,
                interval.lowerBound - last.upperBound < configuration.minGapSeconds
            {
                merged[merged.count - 1] = last.lowerBound...interval.upperBound
            } else {
                merged.append(interval)
            }
        }
        return merged.filter {
            $0.upperBound - $0.lowerBound >= configuration.minVoicedSeconds
        }
    }

    /// Loads `url` as mono and returns its sung intervals, or [] on failure.
    static func sungIntervals(
        url: URL, configuration: Configuration = .init()
    ) throws -> [ClosedRange<TimeInterval>] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return []
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else { return [] }
            for frame in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][frame] }
                samples.append(sum / Float(channelCount))
            }
        }
        return sungIntervals(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
    }
}

/// Removes lyric lines that have NO real vocal under them — the words a transcriber (notably
/// Whisper) hallucinates over instrumental sections (intro / breaks / outro). The vocals stem
/// often has instrumental BLEED (e.g. guitar), so the discriminator must be a STRICT vocal-presence
/// set: `voicedIntervals` should be computed with a high relative-energy threshold so bleed doesn't
/// count as singing. A line is kept only when one of its words overlaps such an interval (within
/// `padding`); otherwise it's dropped — absence of vocal signal is definitive.
///
/// No-op when `voicedIntervals` is empty (the detector produced nothing), so a failed VAD never
/// wipes the lyrics. Use only on the pure-ASR path — with reference lyrics the words are
/// user-supplied and must never be dropped on a timing miss. Idempotent.
/// Adjacent lyric lines never overlap. The ±0.15 s onset snap can start a line's first word inside
/// the previous line's last word (40–90 ms, five times on Summertime's corpus run), which the chart
/// then draws as two rows sounding at once. The earlier line's word ends are clipped at the next
/// line's start; no start moves and no word is dropped.
enum LyricLineOverlapClipper {
    static func clipped(_ lines: [TimedLyricSegment]) -> [TimedLyricSegment] {
        var result = lines.sorted { $0.start < $1.start }
        for index in result.indices.dropLast() {
            let nextStart = result[index + 1].start
            guard result[index].end > nextStart else { continue }
            result[index].words = result[index].words.map { word in
                var clipped = word
                clipped.end = max(word.start, min(word.end, nextStart))
                return clipped
            }
            result[index].end = max(result[index].start, nextStart)
        }
        return result
    }
}

enum VocalHallucinationGate {
    /// A tail cutoff moved past the end of the last pitched (sung) interval, so words the energy
    /// detectors put in the instrumental tail but pitch evidence hears sung are not cut. nil stays
    /// nil: no energy cutoff means no tail filtering at all.
    static func pitchExtended(
        _ cutoff: TimeInterval?, sungIntervals: [ClosedRange<TimeInterval>]
    ) -> TimeInterval? {
        guard let cutoff else { return nil }
        return max(cutoff, sungIntervals.map(\.upperBound).max() ?? cutoff)
    }

    static func filtered(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        padding: TimeInterval = 0.15,
        trailingCutoff: TimeInterval? = nil,
        lastVoicedEnd: TimeInterval? = nil,
        lineStartEpsilon: TimeInterval = 0.02,
        sungIntervals: [ClosedRange<TimeInterval>] = []
    ) -> [TimedLyricSegment] {
        guard !voicedIntervals.isEmpty else { return segments }
        // A line survives when EITHER energy or pitch evidence hears singing under a word: soft
        // melodic vocals sit below the energy gate but carry clear pitch (`VocalPitchSalience`),
        // and the wordless-gap rescue recovers exactly those phrases.
        let evidence = voicedIntervals + sungIntervals
        func overlapsVoiced(_ start: TimeInterval, _ end: TimeInterval) -> Bool {
            for interval in evidence
            where end + padding >= interval.lowerBound && start - padding <= interval.upperBound {
                return true
            }
            return false
        }
        func lineStart(_ segment: TimedLyricSegment) -> TimeInterval {
            let words = segment.words.filter { $0.text.contains(where: { !$0.isWhitespace }) }
            return words.map(\.start).min() ?? segment.start
        }
        func startsInInstrumentalTail(_ start: TimeInterval) -> Bool {
            if let cutoff = trailingCutoff, start >= cutoff - lineStartEpsilon { return true }
            if let voicedEnd = lastVoicedEnd, start >= voicedEnd - lineStartEpsilon { return true }
            return false
        }
        return segments.filter { segment in
            let start = lineStart(segment)
            if startsInInstrumentalTail(start) { return false }
            let words = segment.words.filter { $0.text.contains(where: { !$0.isWhitespace }) }
            if words.isEmpty { return overlapsVoiced(segment.start, segment.end) }
            return words.contains { overlapsVoiced($0.start, $0.end) }
        }
    }
}

/// Final pass after grouping, distribution, and the hallucination gate. Drops lyric lines that still
/// sit in the instrumental tail when a vocal offset was detected — e.g. ASR words placed during
/// guitar bleed that overlap a clipped strict-VAD blip, or an isolated cluster after the last real
/// lyric block. No-op without a cutoff. Use only on the pure-ASR path.
enum TrailingLyricTailPruner {
    static func pruned(
        _ segments: [TimedLyricSegment],
        lastVoicedEnd: TimeInterval?,
        vocalOffset: TimeInterval?,
        sourceDuration: TimeInterval? = nil,
        minClusterGap: TimeInterval = 2.0,
        lineStartEpsilon: TimeInterval = 0.02,
        minTrailingInstrumental: TimeInterval = 3.0
    ) -> [TimedLyricSegment] {
        guard !segments.isEmpty,
            let cutoff = resolvedCutoff(
                segments: segments,
                lastVoicedEnd: lastVoicedEnd,
                vocalOffset: vocalOffset,
                sourceDuration: sourceDuration,
                lineStartEpsilon: lineStartEpsilon,
                minTrailingInstrumental: minTrailingInstrumental)
        else { return segments }

        let sorted = segments.sorted { $0.start < $1.start }
        var kept = sorted.filter { segment in
            let start = substantiveLineStart(segment)
            if start >= cutoff - lineStartEpsilon { return false }
            if let voicedEnd = lastVoicedEnd, start >= voicedEnd - lineStartEpsilon { return false }
            return true
        }

        // Peel off trailing islands: consecutive lines separated from the body by a long gap once
        // we're in the tail window (mirrors how TranscriptionSilenceGate fences outro islands).
        while kept.count >= 2 {
            let last = kept[kept.count - 1]
            let previous = kept[kept.count - 2]
            let tailWindow = last.start >= cutoff - minClusterGap
            let isolated = last.start - previous.end >= minClusterGap
            if tailWindow, isolated {
                kept.removeLast()
            } else {
                break
            }
        }
        return kept
    }

    static func substantiveLineStart(_ segment: TimedLyricSegment) -> TimeInterval {
        let words = segment.words.filter { $0.text.contains(where: { !$0.isWhitespace }) }
        return words.map(\.start).min() ?? segment.start
    }

    /// Geometry may TIGHTEN the VAD signal cutoff by at most this much. A lyric-body end far
    /// below the last voiced moment CONTRADICTS the VAD — real vocals continue — so the
    /// geometric heuristic must yield instead of deleting sung outro lines.
    static let maxSignalTightening: TimeInterval = 3.0

    private static func resolvedCutoff(
        segments: [TimedLyricSegment],
        lastVoicedEnd: TimeInterval?,
        vocalOffset: TimeInterval?,
        sourceDuration: TimeInterval?,
        lineStartEpsilon: TimeInterval,
        minTrailingInstrumental: TimeInterval
    ) -> TimeInterval? {
        let signalCutoff: TimeInterval?
        switch (lastVoicedEnd, vocalOffset) {
        case (let voiced?, let offset?):
            signalCutoff = min(voiced, offset)
        case (let voiced?, nil):
            signalCutoff = voiced
        case (nil, let offset?):
            signalCutoff = offset
        case (nil, nil):
            signalCutoff = nil
        }
        guard
            let lyricBodyEnd = lyricBodyEndBeforeInstrumentalTail(
                segments,
                sourceDuration: sourceDuration,
                lineStartEpsilon: lineStartEpsilon,
                minTrailingInstrumental: minTrailingInstrumental)
        else { return signalCutoff }
        guard let signalCutoff else { return lyricBodyEnd }
        guard signalCutoff - lyricBodyEnd <= maxSignalTightening else { return signalCutoff }
        return min(signalCutoff, lyricBodyEnd)
    }

    /// When vocals end early but ASR/VAD still admit bleed blips, the last real lyric line ends well
    /// before `sourceDuration` and every line after it starts at/after that end (Summertime outro).
    ///
    /// Geometry alone is NOT sufficient: nearly every song's final line starts within
    /// `maxTailClusterGap` of the previous line's end with ≥3s of audio left, so a purely
    /// geometric rule deleted the real closing lines of ordinary songs (field-confirmed:
    /// "I never thought I'd want to hang around" conf 0.98 cut from Settle Down). The tail is
    /// only treated as instrumental-bleed junk when every tail line LOOKS degenerate: a blip
    /// of ≤2 substantive words, or a normalized duplicate of an earlier line or another tail
    /// line (Whisper's outro loop signature).
    static func lyricBodyEndBeforeInstrumentalTail(
        _ segments: [TimedLyricSegment],
        sourceDuration: TimeInterval?,
        lineStartEpsilon: TimeInterval = 0.02,
        minTrailingInstrumental: TimeInterval = 3.0,
        maxTailClusterGap: TimeInterval = 2.0
    ) -> TimeInterval? {
        guard let duration = sourceDuration, duration > 0 else { return nil }
        let sorted = segments.sorted { $0.start < $1.start }
        guard sorted.count >= 2 else { return nil }
        for index in (0..<(sorted.count - 1)).reversed() {
            let line = sorted[index]
            guard duration - line.end >= minTrailingInstrumental else { continue }
            let tail = Array(sorted[(index + 1)...])
            guard
                tail.allSatisfy({ substantiveLineStart($0) >= line.end - lineStartEpsilon }),
                substantiveLineStart(tail[0]) <= line.end + maxTailClusterGap,
                tailLooksDegenerate(tail, body: Array(sorted[...index]))
            else { continue }
            return line.end
        }
        return nil
    }

    /// True when EVERY tail line is junk-shaped: ≤2 substantive words, or a normalized
    /// duplicate of a body line or of another tail line. One unique multi-word tail line
    /// (a real closing lyric) vetoes the cut.
    static func tailLooksDegenerate(
        _ tail: [TimedLyricSegment], body: [TimedLyricSegment]
    ) -> Bool {
        guard !tail.isEmpty else { return false }
        let bodyTexts = Set(body.map { normalizedLineText($0.text) })
        var tailCounts: [String: Int] = [:]
        for line in tail { tailCounts[normalizedLineText(line.text), default: 0] += 1 }
        return tail.allSatisfy { line in
            let words = line.words.filter { $0.text.contains(where: { !$0.isWhitespace }) }
            if words.count <= 2 { return true }
            let normalized = normalizedLineText(line.text)
            if normalized.isEmpty { return true }
            if bodyTexts.contains(normalized) { return true }
            return (tailCounts[normalized] ?? 0) >= 2
        }
    }

    static func normalizedLineText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Drops consecutive trailing lyric lines that repeat the same normalized text — common when Whisper
/// tiles an outro hallucination onto the previous line's end time and again after a bleed blip.
enum TrailingDuplicateLineCollapser {
    static func collapsed(
        _ segments: [TimedLyricSegment],
        lastVoicedEnd: TimeInterval?,
        vocalOffset: TimeInterval?,
        lineStartEpsilon: TimeInterval = 0.02
    ) -> [TimedLyricSegment] {
        guard segments.count >= 2 else { return segments }
        let tailAnchor = [lastVoicedEnd, vocalOffset].compactMap { $0 }.min()
        var result = segments
        while result.count >= 2 {
            let last = result[result.count - 1]
            let previous = result[result.count - 2]
            guard normalized(last.text) == normalized(previous.text),
                !normalized(last.text).isEmpty
            else { break }
            let inTail =
                tailAnchor.map { substantiveLineStart(last) >= $0 - lineStartEpsilon } ?? true
            guard inTail else { break }
            result.removeLast()
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
    }

    private static func substantiveLineStart(_ segment: TimedLyricSegment) -> TimeInterval {
        let words = segment.words.filter { $0.text.contains(where: { !$0.isWhitespace }) }
        return words.map(\.start).min() ?? segment.start
    }
}

/// Drops tail-window lyric lines whose normalized text matches an earlier line in the song — ASR
/// often repeats a chorus phrase during instrumental bleed after real vocals end (Summertime outro).
/// Only acts at/after the vocal tail anchor so intentional double choruses before the cutoff are kept.
enum TrailingEarlierLyricRepeater {
    static func filtered(
        _ segments: [TimedLyricSegment],
        lastVoicedEnd: TimeInterval?,
        vocalOffset: TimeInterval?,
        sourceDuration: TimeInterval? = nil,
        lineStartEpsilon: TimeInterval = 0.02,
        minTrailingInstrumental: TimeInterval = 3.0
    ) -> [TimedLyricSegment] {
        guard segments.count >= 2 else { return segments }
        let sorted = segments.sorted { $0.start < $1.start }
        let signalAnchor = [lastVoicedEnd, vocalOffset].compactMap { $0 }.min()
        let bodyEnd = TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail(
            sorted,
            sourceDuration: sourceDuration,
            lineStartEpsilon: lineStartEpsilon,
            minTrailingInstrumental: minTrailingInstrumental)
        let tailAnchor: TimeInterval?
        switch (signalAnchor, bodyEnd) {
        case (let signal?, let body?):
            tailAnchor = min(signal, body)
        case (let signal?, nil):
            tailAnchor = signal
        case (nil, let body?):
            tailAnchor = body
        case (nil, nil):
            tailAnchor = nil
        }
        guard let tailAnchor else { return segments }

        var earlierTexts = Set<String>()
        var result: [TimedLyricSegment] = []
        for segment in sorted {
            let start = TrailingLyricTailPruner.substantiveLineStart(segment)
            let norm = normalized(segment.text)
            if start >= tailAnchor - lineStartEpsilon, !norm.isEmpty, earlierTexts.contains(norm) {
                continue
            }
            if !norm.isEmpty { earlierTexts.insert(norm) }
            result.append(segment)
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
    }
}

/// Collapses Whisper "repetition hallucinations" WITHIN a single lyric line — where a model loops a
/// phrase so the line becomes e.g. "tried to fake it tried to fake it tried to fake it". Only acts
/// when the ENTIRE line is one multi-word phrase tiled ≥ `minCycles` times (and the phrase has ≥2
/// distinct words), so it never touches legitimate cross-line chorus repeats or single-word "na na
/// na" stutters. Keeps one copy of the phrase; the document's line count is unchanged.
enum RepeatedPhraseCollapser {
    static func collapse(
        _ segments: [TimedLyricSegment], minCycles: Int = 2, minPeriodWords: Int = 2
    ) -> [TimedLyricSegment] {
        segments.map { collapse($0, minCycles: minCycles, minPeriodWords: minPeriodWords) }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
    }

    private static func collapse(
        _ segment: TimedLyricSegment, minCycles: Int, minPeriodWords: Int
    ) -> TimedLyricSegment {
        let words = segment.words
        guard words.count >= minPeriodWords * minCycles else { return segment }
        let norm = words.map { normalized($0.text) }
        // Smallest period (in words) that tiles the WHOLE line ≥ minCycles times and is a real
        // multi-word phrase (≥2 distinct words).
        for period in minPeriodWords...(words.count / minCycles) {
            guard words.count % period == 0 else { continue }
            guard Set(norm[0..<period]).count >= 2 else { continue }
            var isPeriodic = true
            for index in period..<words.count where norm[index] != norm[index % period] {
                isPeriodic = false
                break
            }
            guard isPeriodic else { continue }
            return rebuilt(segment, keepingFirst: period)
        }
        return segment
    }

    /// Rebuilds a segment from its first `count` words (the one kept phrase cycle), recomputing the
    /// text and each word's character range so highlighting stays consistent.
    private static func rebuilt(_ segment: TimedLyricSegment, keepingFirst count: Int)
        -> TimedLyricSegment
    {
        let kept = Array(segment.words.prefix(count))
        guard let first = kept.first, let last = kept.last else { return segment }
        var text = ""
        var newWords: [TimedLyricWord] = []
        for (index, word) in kept.enumerated() {
            let lower = text.count
            text += word.text
            var updated = word
            updated.characterRange = lower..<text.count
            newWords.append(updated)
            if index < kept.count - 1 { text += " " }
        }
        var result = segment
        result.text = text
        result.words = newWords
        result.start = first.start
        result.end = last.end
        return result
    }
}
