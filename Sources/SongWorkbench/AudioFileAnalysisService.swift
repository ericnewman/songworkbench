import AVFoundation
import Foundation

struct SongAudioAnalysis: Codable, Equatable, Sendable {
    let beat: BeatEstimate?
    let chords: [ChordObservation]
    let estimatedKey: MusicalKey?

    init(beat: BeatEstimate?, chords: [ChordObservation], estimatedKey: MusicalKey? = nil) {
        self.beat = beat
        self.chords = chords
        self.estimatedKey = estimatedKey
    }
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
        let chords = try ChordAnalysisPipeline(configuration: configuration).analyze(
            samples: samples)
        return SongAudioAnalysis(
            beat: BeatTracker().analyze(samples: samples, sampleRate: sampleRate),
            chords: chords,
            estimatedKey: MusicalKeyEstimator().estimate(from: chords)
        )
    }

    /// Vocal-activity intervals (singing regions) for a vocals-stem file, used to evaluate and
    /// later correct lyric timing against where the voice is actually present.
    func vocalActivityIntervals(url: URL) throws -> [ClosedRange<TimeInterval>] {
        let (samples, sampleRate) = try loadMonoSamples(url: url)
        try Task.checkCancellation()
        return VocalActivityEnvelope.voicedIntervals(samples: samples, sampleRate: sampleRate)
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
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                samples.append(value / Float(max(channelCount, 1)))
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
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                samples.append(value / Float(max(channelCount, 1)))
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
        /// Fraction of the peak flux used for the threshold (combined with the noise floor).
        var peakFraction: Float = 0.1
        /// Multiple of the noise-floor flux the signal must exceed to count as an onset.
        var noiseFloorMultiple: Float = 3
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

        // Noise floor: a low percentile of the flux (steady regions and silence).
        let sorted = flux.sorted()
        let floorIndex = max(0, min(sorted.count - 1, Int(Double(sorted.count) * 0.05)))
        let noiseFloor = sorted[floorIndex]
        let threshold = max(
            noiseFloor * configuration.noiseFloorMultiple, peak * configuration.peakFraction)

        // Peak-pick: local maxima above threshold, spaced at least `minSpacingSeconds` apart.
        let minSpacingHops = max(1, Int(configuration.minSpacingSeconds / configuration.hopSeconds))
        var onsets: [TimeInterval] = []
        var lastOnsetHop = -minSpacingHops - 1
        for k in flux.indices where flux[k] >= threshold {
            let prev = k > 0 ? flux[k - 1] : -Float.infinity
            let next = k + 1 < flux.count ? flux[k + 1] : -Float.infinity
            guard flux[k] >= prev, flux[k] >= next else { continue }  // local maximum
            guard k - lastOnsetHop >= minSpacingHops else { continue }
            onsets.append(Double(k * hop) / sampleRate)
            lastOnsetHop = k
        }
        return onsets
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
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                samples.append(value / Float(max(channelCount, 1)))
            }
        }
        return onsets(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
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

/// Repairs line-LEADING words stranded on a weak energy blip well before the rest of their line.
/// ASR pads a line's first word early after an instrumental break, and the distribution pass can
/// then anchor it onto a brief bleed/breath blip (e.g. "Oceans" pinned 2.4s before "moving…" on a
/// blip at half body level) — the rendered line then shows a multi-beat gap where the music has
/// none. When a small leading cluster is separated from the line's main body by a mostly-UNVOICED
/// gap, the cluster is translated forward to abut the body. A mostly-voiced gap is left alone —
/// that's a genuinely held note, not a timing error. Word/segment count, order, text preserved.
enum StrandedLeadingWordRepairer {
    static func repaired(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        minimumGap: TimeInterval = 1.0,
        maximumLeadingWords: Int = 2,
        maximumVoicedFraction: Double = 0.3,
        abutGap: TimeInterval = 0.08
    ) -> [TimedLyricSegment] {
        guard !segments.isEmpty, !voicedIntervals.isEmpty else { return segments }
        var result = segments
        for index in result.indices {
            var words = result[index].words
            guard words.count >= 2 else { continue }
            // Find the largest leading gap within the allowed cluster size.
            var clusterEnd: Int?
            var gap: TimeInterval = 0
            for wordIndex in 0..<min(maximumLeadingWords, words.count - 1) {
                let g = words[wordIndex + 1].start - words[wordIndex].end
                if g >= minimumGap {
                    clusterEnd = wordIndex
                    gap = g
                    break
                }
            }
            guard let clusterEnd, gap > 0 else { continue }
            let gapStart = words[clusterEnd].end
            let gapEnd = words[clusterEnd + 1].start
            let voiced = voicedCoverage(from: gapStart, to: gapEnd, in: voicedIntervals)
            guard voiced / gap <= maximumVoicedFraction else { continue }
            // Translate the leading cluster forward so it ends just before the body begins.
            let shift = gapEnd - abutGap - words[clusterEnd].end
            guard shift > 0 else { continue }
            for wordIndex in 0...clusterEnd {
                words[wordIndex].start += shift
                words[wordIndex].end += shift
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
        guard !voicedIntervals.isEmpty else { return [] }
        // Padded, merged word coverage — every span the transcription accounts for.
        let covered: [ClosedRange<TimeInterval>] = merged(
            lyrics.flatMap(\.words).map {
                (max($0.start - wordPadding, 0))...($0.end + wordPadding)
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
/// never stops. Two conservative, non-destructive rules against the strict-VAD voiced intervals:
///
/// - Melisma bridge: a ≥ `minimumGap` inter-word gap that is CONTINUOUSLY voiced
///   (≥ `melismaVoicedFraction`) is a held word, not a pause → extend `word.end` to the next
///   word's onset.
/// - Late-onset pullback: a mostly-unvoiced gap (≤ `pullbackUnvoicedFraction` voiced) where the
///   voice audibly re-enters more than `onsetSlack` BEFORE the ASR's next onset → pull the next
///   word's start back to the voiced re-entry edge.
///
/// Never deletes or reorders tokens (see tasks/lessons.md 2026-06-25); only re-times. Segment
/// `start`/`end` are re-derived from the adjusted words. No-op without voiced intervals.
enum VocalWordSpanNormalizer {
    static func normalized(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        minimumGap: TimeInterval = 0.4,
        melismaVoicedFraction: Double = 0.8,
        pullbackUnvoicedFraction: Double = 0.5,
        onsetSlack: TimeInterval = 0.25
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
                } else if voicedFraction <= pullbackUnvoicedFraction {
                    // Real pause, but the ASR onset trails the audible re-entry.
                    guard
                        let edge =
                            sortedIntervals
                            .map(\.lowerBound)
                            .first(where: { $0 > gapStart && $0 < gapEnd })
                    else { continue }
                    guard gapEnd - edge > onsetSlack else { continue }
                    let newStart = max(edge, gapStart + 0.01)
                    if newStart < words[wordIndex + 1].end - 0.01 {
                        words[wordIndex + 1].start = newStart
                    }
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

/// Snaps each sung word's onset to the nearest vocal-stem onset (from `InstrumentOnsetDetector`
/// run on the vocals stem), so words — and everything anchored to them (the ChordPro word layout,
/// the per-line waveform strip, the bouncing ball, and chords placed over words) — sit on the
/// actual vocal energy instead of the ASR's approximate onset. Non-destructive: word/segment count,
/// order, and text are preserved; only onset times move, never before the previous word (times stay
/// nondecreasing), and never past a word's own end. Each segment's `start`/`end` are re-derived from
/// its snapped words. Returns the input unchanged when `onsets` is empty.
enum VocalWordOnsetAligner {
    static func snapped(
        _ segments: [TimedLyricSegment],
        toOnsets onsets: [TimeInterval],
        tolerance: TimeInterval = 0.15
    ) -> [TimedLyricSegment] {
        guard !onsets.isEmpty, !segments.isEmpty else { return segments }
        let sortedOnsets = onsets.sorted()
        var floor = -TimeInterval.infinity
        var result = segments
        for segmentIndex in result.indices {
            guard !result[segmentIndex].words.isEmpty else { continue }
            var words = result[segmentIndex].words
            for wordIndex in words.indices {
                let time = words[wordIndex].start
                var nearest = sortedOnsets[0]
                for onset in sortedOnsets where abs(onset - time) < abs(nearest - time) {
                    nearest = onset
                }
                var newStart = abs(nearest - time) <= tolerance ? nearest : time
                // Keep word order (nondecreasing) and a positive duration.
                newStart = max(newStart, floor)
                if words[wordIndex].end > words[wordIndex].start {
                    newStart = min(newStart, words[wordIndex].end - 0.01)
                }
                words[wordIndex].start = newStart
                floor = newStart
            }
            result[segmentIndex].words = words
            result[segmentIndex].start = words.first!.start
            result[segmentIndex].end = max(words.last!.end, words.first!.start + 0.01)
        }
        return result
    }
}

/// Non-destructive companion to `VocalOnsetDetector`: ASR engines (Whisper) mis-time the real
/// first line's words DOWN into a silent instrumental intro, so the first line shows at ~0:00.
/// Rather than dropping those words (which loses real lyrics — see the project rule), this RE-TIMES
/// the leading lines that start before the detected vocal onset so they begin at the onset,
/// preserving every line and word. The number of segments is never changed.
enum VocalOnsetReanchor {
    /// Re-times leading lines that the ASR placed before the true vocal `onset`.
    /// - A line straddling the onset is compressed into `[onset, originalEnd]` (the END is the
    ///   reliable anchor, same assumption as de-padding).
    /// - A line entirely before the onset is translated forward to begin at the onset.
    /// - Lines starting at/after the onset, or only slightly before it (`< minLeadToReanchor`),
    ///   are left untouched. Lines never overlap and never reorder; the count is preserved.
    static func reanchor(
        _ segments: [TimedLyricSegment],
        onset: TimeInterval,
        minLeadToReanchor: TimeInterval = 2,
        minLineDuration: TimeInterval = 0.3
    ) -> [TimedLyricSegment] {
        guard onset > 0, let first = segments.first, first.start < onset else { return segments }
        var result = segments
        var floor = onset
        for index in result.indices {
            let seg = result[index]
            guard seg.start < onset else { break }  // reached lines already at/after the onset
            guard onset - seg.start >= minLeadToReanchor else {
                floor = max(floor, seg.end)  // basically correct already; just advance the floor
                continue
            }
            let nextStart =
                index + 1 < result.count ? result[index + 1].start : TimeInterval.infinity
            let newStart = floor
            // Keep the (reliable) end if it's still after the new start, else translate the span.
            var newEnd =
                seg.end > newStart
                ? seg.end : newStart + max(seg.end - seg.start, minLineDuration)
            newEnd = max(newEnd, newStart + minLineDuration)
            if nextStart.isFinite {
                newEnd = min(newEnd, max(nextStart, newStart + minLineDuration))
            }
            result[index] = remap(seg, toStart: newStart, end: newEnd)
            floor = result[index].end
        }
        return result
    }

    /// Linearly remaps a segment's word timings from its old span onto `[newStart, newEnd]`,
    /// preserving id/text and relative word spacing (mutates copies so the Codable id is kept).
    private static func remap(
        _ segment: TimedLyricSegment, toStart newStart: TimeInterval, end newEnd: TimeInterval
    ) -> TimedLyricSegment {
        let oldSpan = max(segment.end - segment.start, 0.000_001)
        let newSpan = max(newEnd - newStart, 0.000_001)
        func mapped(_ time: TimeInterval) -> TimeInterval {
            newStart + (time - segment.start) / oldSpan * newSpan
        }
        var updated = segment
        updated.start = newStart
        updated.end = newEnd
        updated.words = segment.words.map { word in
            var w = word
            w.start = mapped(word.start)
            w.end = mapped(word.end)
            return w
        }
        return updated
    }
}

/// Prepares ASR segments for lyric grouping after a detected vocal onset: re-anchors lines that
/// Whisper mis-timed into a silent intro (preserving every word) and drops tokens entirely before
/// the onset (intro hallucinations). No-op when `onset` is nil.
enum TranscriptionOnsetCorrection {
    static func preparedSegments(
        _ segments: [TimedTranscriptionSegment],
        onset: TimeInterval
    ) -> [TimedTranscriptionSegment] {
        let lyricSegments = segments.compactMap(lyricSegment(from:))
        guard !lyricSegments.isEmpty else { return segments }
        let reanchored = VocalOnsetReanchor.reanchor(lyricSegments, onset: onset)
        return reanchored.compactMap { transcriptionSegment(from: $0, droppingBefore: onset) }
    }

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

    private static func lyricSegment(from segment: TimedTranscriptionSegment) -> TimedLyricSegment?
    {
        guard !segment.tokens.isEmpty else { return nil }
        var text = ""
        var words: [TimedLyricWord] = []
        for token in segment.tokens {
            let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            let lower = text.count
            text += trimmed
            words.append(
                TimedLyricWord(
                    text: trimmed,
                    start: token.startTime,
                    end: token.endTime,
                    characterRange: lower..<text.count
                ))
        }
        guard !words.isEmpty else { return nil }
        return TimedLyricSegment(
            start: segment.startTime,
            end: segment.endTime,
            text: text,
            words: words
        )
    }

    private static func transcriptionSegment(
        from segment: TimedLyricSegment,
        droppingBefore onset: TimeInterval
    ) -> TimedTranscriptionSegment? {
        let keptWords = segment.words.filter { $0.end > onset }
        guard !keptWords.isEmpty else { return nil }
        let tokens = keptWords.map { word in
            TimedTranscriptionToken(
                text: word.text,
                startTime: word.start,
                endTime: word.end,
                confidence: nil
            )
        }
        return TimedTranscriptionSegment(
            text: keptWords.map(\.text).joined(separator: " "),
            startTime: keptWords.first?.start ?? segment.start,
            endTime: keptWords.last?.end ?? segment.end,
            tokens: tokens,
            confidence: nil
        )
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
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                samples.append(value / Float(max(channelCount, 1)))
            }
        }
        return voicedIntervals(
            samples: samples, sampleRate: format.sampleRate, configuration: configuration)
    }
}

/// Corrects the systematic "words precede the singing" lead by shifting each lyric LINE to the
/// vocal onset detected near its ASR start (from the vocals-stem voiced intervals). Lines are only
/// ever moved in time — never dropped, never reordered — so it cannot lose or scramble lyrics. Also
/// fixes the intro (no voiced region at 0 ⇒ the first line snaps to the first real onset).
enum VocalAlignmentCorrector {
    static func align(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        searchBack: TimeInterval = 0.4,
        searchForward: TimeInterval = 2.5,
        minShift: TimeInterval = 0.15,
        minLineDuration: TimeInterval = 0.3
    ) -> [TimedLyricSegment] {
        guard !segments.isEmpty, !voicedIntervals.isEmpty else { return segments }
        let onsets = voicedIntervals.map(\.lowerBound).sorted()
        var result = segments
        // Nothing can be sung before the first voiced onset, so no line may start before it. This
        // also fixes a far intro (first line at ~0) that's beyond the per-line forward search.
        var floor = onsets.first ?? 0
        for index in result.indices {
            let seg = result[index]
            let nextStart =
                index + 1 < result.count ? result[index + 1].start : Double.infinity
            // The line's true onset is the first voiced region near its ASR start (words lead the
            // singing, so look mostly forward with a small backward tolerance).
            let candidate = onsets.first {
                $0 >= seg.start - searchBack && $0 <= seg.start + searchForward
            }
            var newStart = seg.start
            if let candidate, abs(candidate - seg.start) >= minShift {
                newStart = candidate
            }
            // never start before the previous line ends (keep order)
            newStart = max(newStart, floor)
            let delta = newStart - seg.start
            var newEnd = seg.end + delta
            newEnd = max(newEnd, newStart + minLineDuration)
            if nextStart.isFinite {
                newEnd = min(newEnd, max(nextStart, newStart + minLineDuration))
            }
            result[index] = shifted(seg, by: delta, newEnd: newEnd)
            floor = newEnd
        }
        return result
    }

    /// Audio-as-reference word placement: the vocals stem's voiced regions are the ground truth.
    /// Each LINE's words are distributed across the voiced regions NEAR that line (its ASR time
    /// window, padded and clipped to its neighbours), weighted by word length, so words land only on
    /// signal and silent gaps stay wordless. Distributing PER LINE (not globally) keeps every line
    /// anchored to its own time: if the detector misses singing somewhere, only that line is
    /// affected — lyrics can't pile into early regions and drift the whole song ahead. A line with no
    /// nearby signal keeps its ASR timing. Line/word count is never changed.
    static func distributeAcrossSignal(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        windowPadding: TimeInterval = 0.5
    ) -> [TimedLyricSegment] {
        let allRegions =
            voicedIntervals
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !segments.isEmpty, !allRegions.isEmpty else { return segments }

        var result = segments
        for index in segments.indices {
            let segment = segments[index]
            guard !segment.words.isEmpty else { continue }
            // This line's neighbourhood: its ASR window padded, but never past the previous line's
            // end or the next line's start (so lines don't steal each other's regions / overlap).
            let previousEnd = index > 0 ? segments[index - 1].end : -.greatestFiniteMagnitude
            let nextStart =
                index + 1 < segments.count ? segments[index + 1].start : .greatestFiniteMagnitude
            let lo = max(min(segment.start, segment.end) - windowPadding, previousEnd)
            let hi = min(max(segment.start, segment.end) + windowPadding, nextStart)
            guard hi > lo else { continue }
            let regions: [ClosedRange<TimeInterval>] = allRegions.compactMap { region in
                let start = max(region.lowerBound, lo)
                let end = min(region.upperBound, hi)
                return end > start ? start...end : nil
            }
            guard !regions.isEmpty else { continue }  // no nearby signal → keep the ASR timing
            result[index] = distribute(segment, across: regions)
        }
        return result
    }

    /// Spreads one line's words across the given voiced regions (weighted by word length), skipping
    /// the silent gaps between them; word starts snap onto signal and word ends never cross a gap.
    private static func distribute(
        _ segment: TimedLyricSegment, across regions: [ClosedRange<TimeInterval>]
    ) -> TimedLyricSegment {
        let totalVoiced = regions.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let totalWeight = segment.words.reduce(0.0) { $0 + Double(max($1.text.count, 1)) }
        guard totalVoiced > 0, totalWeight > 0 else { return segment }

        func realTime(atVoicedOffset offset: Double) -> TimeInterval {
            var remaining = min(max(offset, 0), totalVoiced)
            for region in regions {
                let length = region.upperBound - region.lowerBound
                if remaining <= length { return region.lowerBound + remaining }
                remaining -= length
            }
            return regions.last?.upperBound ?? 0
        }
        func snapToSignalStart(_ time: TimeInterval) -> TimeInterval {
            for region in regions {
                if time < region.lowerBound { return region.lowerBound }
                if time < region.upperBound { return time }
            }
            return regions.last?.upperBound ?? time
        }
        func regionEnd(for time: TimeInterval) -> TimeInterval {
            for region in regions where time < region.upperBound { return region.upperBound }
            return regions.last?.upperBound ?? time
        }

        var newWords: [TimedLyricWord] = []
        var cumulative = 0.0
        for word in segment.words {
            let startOffset = cumulative / totalWeight * totalVoiced
            cumulative += Double(max(word.text.count, 1))
            let endOffset = cumulative / totalWeight * totalVoiced
            var updated = word
            let start = snapToSignalStart(realTime(atVoicedOffset: startOffset))
            updated.start = start
            updated.end = max(
                min(realTime(atVoicedOffset: endOffset), regionEnd(for: start)), start + 0.05)
            newWords.append(updated)
        }
        guard let first = newWords.first, let last = newWords.last else { return segment }
        var result = segment
        result.words = newWords
        result.start = first.start
        result.end = max(last.end, first.start + 0.1)
        return result
    }

    private static func shifted(
        _ segment: TimedLyricSegment, by delta: TimeInterval, newEnd: TimeInterval
    ) -> TimedLyricSegment {
        var updated = segment
        updated.start = segment.start + delta
        updated.end = newEnd
        updated.words = segment.words.map { word in
            var w = word
            w.start = word.start + delta
            w.end = word.end + delta
            return w
        }
        return updated
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
enum VocalHallucinationGate {
    static func filtered(
        _ segments: [TimedLyricSegment],
        voicedIntervals: [ClosedRange<TimeInterval>],
        padding: TimeInterval = 0.15,
        trailingCutoff: TimeInterval? = nil,
        lastVoicedEnd: TimeInterval? = nil,
        lineStartEpsilon: TimeInterval = 0.02
    ) -> [TimedLyricSegment] {
        guard !voicedIntervals.isEmpty else { return segments }
        func overlapsVoiced(_ start: TimeInterval, _ end: TimeInterval) -> Bool {
            for interval in voicedIntervals
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
