import AVFoundation
import Accelerate
import Foundation

/// One analysis frame's pitch verdict from a monophonic detector, stamped at the frame's centre
/// so bucket assignment is by where the frame's energy actually sits. `midiNote == nil` is an
/// unvoiced/silent frame.
struct PitchFrameEstimate: Equatable, Sendable {
    let time: TimeInterval
    let midiNote: Int?
    let confidence: Float
}

/// Identifies the metronome grid a bucket timeline was cut on. Buckets are only meaningful
/// against the exact grid that made them; when the document's timing moves (a metrical-level
/// retune, a re-anchored downbeat) the timeline is stale and must be recut, not reinterpreted.
struct BucketGridKey: Codable, Equatable, Sendable {
    var bpm: Double
    var anchor: TimeInterval
    var duration: TimeInterval

    /// The key the current document timing would produce, or nil when there is no usable grid.
    static func current(
        beatTimes: [TimeInterval], bpm: Double?, barGrid: SongBarGrid?, duration: TimeInterval
    ) -> BucketGridKey? {
        guard let bpm, bpm.isFinite, bpm > 0, duration > 0,
            let anchor = MetronomeGrid.anchorTime(beatTimes: beatTimes, barGrid: barGrid)
        else { return nil }
        return BucketGridKey(bpm: bpm, anchor: anchor, duration: duration)
    }

    /// Equality with the tolerance persisted doubles deserve: a 1e-6 s anchor wobble from a
    /// JSON round-trip is not a retune.
    func matches(_ other: BucketGridKey) -> Bool {
        abs(bpm - other.bpm) < 1e-6 && abs(anchor - other.anchor) < 1e-6
            && abs(duration - other.duration) < 1e-3
    }
}

/// What one stem sounded like inside one metronome bucket `[click_k, click_{k+1})`.
/// Monophonic stems (bass, voices) fill `midiNote`; polyphonic stems (guitar, piano, other)
/// fill `pitchClasses` (0 = C … 11 = B, strongest first, at most three). A bucket with no
/// entry is a rest.
struct StemBucketNote: Codable, Equatable, Sendable {
    var bucketIndex: Int
    var midiNote: Int?
    var pitchClasses: [Int]
    /// 0…1: how decisively the winning note/classes dominated the bucket's voiced frames.
    var confidence: Float
    /// 0…1: the share of the bucket's frames that were voiced at all.
    var coverage: Float
}

struct StemBucketNotes: Codable, Equatable, Sendable {
    var stemID: StemID
    var notes: [StemBucketNote]
}

/// The per-stem, per-bucket note timeline for a song. `clickTimes` are the bucket edges — the
/// metronome grid at compute time — so bucket k spans `clickTimes[k]..<clickTimes[k+1]`.
struct BucketNoteTimeline: Codable, Equatable, Sendable {
    /// Bump when detection or aggregation semantics change so stored timelines recompute.
    static let currentVersionTag = "buckets-1"

    var versionTag: String
    var gridKey: BucketGridKey
    var clickTimes: [TimeInterval]
    var stems: [StemBucketNotes]

    init(gridKey: BucketGridKey, clickTimes: [TimeInterval], stems: [StemBucketNotes]) {
        self.versionTag = Self.currentVersionTag
        self.gridKey = gridKey
        self.clickTimes = clickTimes
        self.stems = stems
    }

    /// True when this timeline was cut on `key` by the current detector — i.e. it may be shown.
    func isCurrent(for key: BucketGridKey?) -> Bool {
        guard let key else { return false }
        return versionTag == Self.currentVersionTag && gridKey.matches(key)
    }

    func notes(for stemID: StemID) -> [StemBucketNote]? {
        stems.first { $0.stemID == stemID }?.notes
    }
}

/// Cuts each pitched stem into metronome buckets and names what sounds in each. Pure over
/// `[Float]` samples (the aggregators are static and take frame streams) so the contract is
/// testable without audio files; `analyze(url:)` is the thin file-backed entry the pipeline uses.
struct BucketNoteAnalyzer: Sendable {
    /// How a stem is listened to. Drums (and anything unpitched) have no role and are skipped.
    enum StemRole: Equatable, Sendable {
        /// Autocorrelation bass tracker: one note per bucket.
        case bass
        /// Vocal candidate detector: the strongest note per bucket.
        case voice
        /// Chroma: up to three pitch classes per bucket.
        case polyphonic
    }

    /// Buckets with fewer voiced frames than this share are rests (no entry stored).
    static let minimumCoverage: Float = 0.2
    /// Polyphonic: a pitch class needs this share of the bucket's chroma mass to be listed.
    static let minimumPitchClassShare: Float = 0.18
    static let maximumPitchClasses = 3
    /// Polyphonic: frames below this RMS (peak-normalised) are silence.
    static let silenceThreshold: Float = 0.003
    private static let chromaFrameLength = 4_096
    private static let chromaHopLength = 2_048

    static func role(for stemID: StemID) -> StemRole? {
        let root = stemID.rawValue.split(separator: ".").first.map(String.init) ?? ""
        switch StemKind(rawValue: root) {
        case .bass: return .bass
        case .vocals: return .voice
        case .guitar, .piano, .other: return .polyphonic
        case .drums, .none:
            // Legacy 4-stem sets carry an "accompaniment" residual: pitched, polyphonic.
            return root == "accompaniment" ? .polyphonic : nil
        }
    }

    // MARK: - Entry points

    func analyze(url: URL, role: StemRole, clickTimes: [TimeInterval]) throws
        -> [StemBucketNote]
    {
        let (samples, sampleRate) = try MonoSampleLoader.load(url: url)
        try Task.checkCancellation()
        return notes(role: role, samples: samples, sampleRate: sampleRate, clickTimes: clickTimes)
    }

    func notes(
        role: StemRole, samples: [Float], sampleRate: Double, clickTimes: [TimeInterval]
    ) -> [StemBucketNote] {
        guard clickTimes.count >= 2, sampleRate > 0, !samples.isEmpty else { return [] }
        switch role {
        case .bass:
            return Self.aggregateMonophonic(
                frames: BassLineAnalyzer().frameEstimates(samples: samples, sampleRate: sampleRate),
                clickTimes: clickTimes)
        case .voice:
            return Self.aggregateMonophonic(
                frames: VocalHarmonyAnalyzer(maximumNotesPerFrame: 1)
                    .frameEstimates(samples: samples, sampleRate: sampleRate),
                clickTimes: clickTimes)
        case .polyphonic:
            return Self.aggregatePolyphonic(
                frames: Self.chromaFrames(samples: samples, sampleRate: sampleRate),
                clickTimes: clickTimes)
        }
    }

    // MARK: - Aggregation (pure)

    /// One weighted vote per voiced frame; the bucket's note is the confidence-weighted mode.
    static func aggregateMonophonic(
        frames: [PitchFrameEstimate], clickTimes: [TimeInterval]
    ) -> [StemBucketNote] {
        let bucketCount = clickTimes.count - 1
        guard bucketCount > 0 else { return [] }
        var total = [Int](repeating: 0, count: bucketCount)
        var voiced = [Int](repeating: 0, count: bucketCount)
        var votes = [[Int: Float]](repeating: [:], count: bucketCount)
        for frame in frames {
            guard let bucket = bucketIndex(for: frame.time, clickTimes: clickTimes) else {
                continue
            }
            total[bucket] += 1
            guard let midi = frame.midiNote, frame.confidence > 0 else { continue }
            voiced[bucket] += 1
            votes[bucket][midi, default: 0] += frame.confidence
        }
        var notes: [StemBucketNote] = []
        for bucket in 0..<bucketCount where total[bucket] > 0 {
            let coverage = Float(voiced[bucket]) / Float(total[bucket])
            guard coverage >= minimumCoverage,
                let winner = votes[bucket].max(by: { $0.value < $1.value })
            else { continue }
            let mass = votes[bucket].values.reduce(0, +)
            notes.append(
                StemBucketNote(
                    bucketIndex: bucket,
                    midiNote: winner.key,
                    pitchClasses: [((winner.key % 12) + 12) % 12],
                    confidence: mass > 0 ? winner.value / mass : 0,
                    coverage: coverage))
        }
        return notes
    }

    /// A chroma frame: 12 pitch-class energies (any scale) and the frame's weight (its RMS), so
    /// loud frames say more than quiet ones and silent frames (weight 0) say nothing.
    struct ChromaFrame: Equatable, Sendable {
        let time: TimeInterval
        let chroma: [Float]
        let weight: Float
    }

    /// Sums weighted chroma over each bucket and lists the classes that carry a real share.
    static func aggregatePolyphonic(
        frames: [ChromaFrame], clickTimes: [TimeInterval]
    ) -> [StemBucketNote] {
        let bucketCount = clickTimes.count - 1
        guard bucketCount > 0 else { return [] }
        var total = [Int](repeating: 0, count: bucketCount)
        var voiced = [Int](repeating: 0, count: bucketCount)
        var mass = [[Float]](repeating: [Float](repeating: 0, count: 12), count: bucketCount)
        for frame in frames {
            guard frame.chroma.count == 12,
                let bucket = bucketIndex(for: frame.time, clickTimes: clickTimes)
            else { continue }
            total[bucket] += 1
            guard frame.weight > 0 else { continue }
            voiced[bucket] += 1
            for pitchClass in 0..<12 {
                mass[bucket][pitchClass] += frame.chroma[pitchClass] * frame.weight
            }
        }
        var notes: [StemBucketNote] = []
        for bucket in 0..<bucketCount where total[bucket] > 0 {
            let coverage = Float(voiced[bucket]) / Float(total[bucket])
            let sum = mass[bucket].reduce(0, +)
            guard coverage >= minimumCoverage, sum > 0 else { continue }
            let shares = mass[bucket].map { $0 / sum }
            let ranked = shares.enumerated()
                .filter { $0.element >= minimumPitchClassShare }
                .sorted { $0.element > $1.element }
                .prefix(maximumPitchClasses)
            guard let top = ranked.first else { continue }
            notes.append(
                StemBucketNote(
                    bucketIndex: bucket,
                    midiNote: nil,
                    pitchClasses: ranked.map(\.offset),
                    confidence: top.element,
                    coverage: coverage))
        }
        return notes
    }

    /// Index k with `clickTimes[k] <= time < clickTimes[k+1]`; nil outside the grid.
    static func bucketIndex(for time: TimeInterval, clickTimes: [TimeInterval]) -> Int? {
        guard let first = clickTimes.first, let last = clickTimes.last, time >= first, time < last
        else { return nil }
        var low = 0
        var high = clickTimes.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if clickTimes[mid] <= time { low = mid } else { high = mid }
        }
        return low
    }

    // MARK: - Chroma front end

    static func chromaFrames(samples: [Float], sampleRate: Double) -> [ChromaFrame] {
        guard samples.count >= chromaFrameLength,
            let framer = try? MonoSampleFramer(
                frameLength: chromaFrameLength, hopLength: chromaHopLength,
                sampleRate: sampleRate),
            let transform = try? MagnitudeSpectrumAnalyzer.makeTransform(
                frameLength: chromaFrameLength)
        else { return [] }
        let peak = vDSP.maximumMagnitude(samples)
        let leveled = peak > 0 ? vDSP.divide(samples, peak) : samples
        let spectrumAnalyzer = MagnitudeSpectrumAnalyzer()
        let chromaAnalyzer = ChromaAnalyzer()
        let halfFrame = Double(chromaFrameLength) / sampleRate / 2
        var frames: [ChromaFrame] = []
        for start in framer.frameStartIndices(forSampleCount: leveled.count) {
            let frame = framer.frame(from: leveled, startIndex: start)
            let rms = vDSP.rootMeanSquare(frame.samples)
            let time = frame.timestamp + halfFrame
            guard rms >= silenceThreshold,
                let spectrum = try? spectrumAnalyzer.analyze(
                    frame, sampleRate: sampleRate, transform: transform)
            else {
                frames.append(
                    ChromaFrame(
                        time: time, chroma: [Float](repeating: 0, count: 12),
                        weight: 0))
                continue
            }
            frames.append(
                ChromaFrame(
                    time: time, chroma: chromaAnalyzer.analyze(spectrum).values,
                    weight: rms))
        }
        return frames
    }
}

/// Reads an audio file as mono float samples (channels averaged) at its native rate, under
/// security-scoped access. The bass and vocal analyzers each carry a private copy of this;
/// new code should use this one.
enum MonoSampleLoader {
    static func load(url: URL) throws -> ([Float], Double) {
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
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else {
                throw WaveformAnalyzerError.unsupportedAudioFormat
            }
            for frame in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][frame] }
                samples.append(value / Float(channelCount))
            }
        }
        return (samples, format.sampleRate)
    }
}
