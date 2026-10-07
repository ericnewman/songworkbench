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
    // buckets-3: a bass stem that is only a shadow of the singing is left out (`VocalShadowGate`),
    // and so is an instrument stem that is only separation residue (`withoutPhantomInstruments`).
    // buckets-4: no row for the separator's `other` stem when a guitar or piano stem exists.
    // buckets-5: no stem is filtered against the vocals; each is its own source (2026-10-07).
    // buckets-6: half-beat buckets.
    static let currentVersionTag = "buckets-6"

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
    /// Polyphonic: the strongest pitch class must carry at least this share of the bucket's
    /// chroma mass (1.5× a flat 1/12) or the bucket is noise, not a chord. Measured 2026-09-08 on
    /// real stems: the guitar's MEDIAN top share was 0.175 and the piano's 0.159, so the earlier
    /// absolute 0.18 gate silenced most of both.
    static let minimumTopShare: Float = 1.5 / 12
    /// Polyphonic: further classes are listed while they hold at least this fraction of the top
    /// class's share — relative, because harmonics spread a real instrument's chroma so that a
    /// triad's tones each sit around 0.15–0.25 rather than clearing a fixed bar.
    static let relativePitchClassShare: Float = 0.6
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
            guard let topShare = shares.max(), topShare >= minimumTopShare else { continue }
            let ranked = shares.enumerated()
                .filter { $0.element >= topShare * relativePitchClassShare }
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

/// The pipeline/app step that turns a document's stems and timing into its bucket timeline.
/// Runs AFTER `AnalysisTimingPostPasses` (the grid it cuts on is the reconciled one the chart
/// shows) and is best-effort: nothing here can fail a stage. It is also what the app's
/// "Compute Bucket Notes" action calls, so a stale timeline is refreshed by the same code that
/// made it.
enum BucketNotePass {
    /// The grid key the document's CURRENT timing produces, or nil when it has no usable grid.
    static func gridKey(for document: SongAnalysisDocument) -> BucketGridKey? {
        BucketGridKey.current(
            beatTimes: document.beatTimes, bpm: document.estimatedBPM, barGrid: document.barGrid,
            duration: duration(for: document))
    }

    /// The audio to listen to: the playable leaves of the stem set (a kept lead/backing split
    /// replaces its parent vocals), else the legacy flat stem files. Drums are excluded here so
    /// the analyzer never even opens them.
    ///
    /// `gated: false` skips the two gates that decode audio (vocal shadow, phantom instrument) and
    /// the bookmark resolution: the menus' enable checks run on every playback tick and must only
    /// ask whether stems exist.
    static func stemAudio(for document: SongAnalysisDocument, gated: Bool = true)
        -> [(id: StemID, url: URL)]
    {
        var entries: [(id: StemID, url: URL)] = []
        if let manifest = document.stemSet?.resolved(followingBookmarks: gated) {
            entries = StemMixGraph(manifest: manifest).activeNodes.map { ($0.id, $0.audioURL) }
        } else if let files = document.stems?.resolved(followingBookmarks: gated) {
            entries = [
                (StemID(.vocals), files.vocals), (StemID(.bass), files.bass),
                (StemID(.other), files.other),
            ]
            if let guitar = files.guitar { entries.append((StemID(.guitar), guitar)) }
            if let piano = files.piano { entries.append((StemID(.piano), piano)) }
            if let accompaniment = files.accompaniment {
                entries.append((StemID(rawValue: "accompaniment"), accompaniment))
            }
        }
        // Every stem is its own source (Eric, 2026-10-07): none is filtered against the vocals.
        let pitched = withoutOtherMusicians(entries).filter {
            BucketNoteAnalyzer.role(for: $0.id) != nil
        }
        return (gated ? withoutPhantomInstruments(pitched) : pitched).sorted { $0.id < $1.id }
    }

    /// Drops the separator's `other` stem (and any refined child of it).
    ///
    /// The timeline answers "what did the guitarist, bassist and pianist play?" (CONTEXT.md, Design
    /// objective); `other` is nobody's chair, so it gets no row — and, since the solo pass reads
    /// this list, no solo tab either. A legacy stem set with neither a guitar nor a piano stem
    /// keeps it: there `other` is the only instrument stem the song has.
    static func withoutOtherMusicians(_ entries: [(id: StemID, url: URL)])
        -> [(id: StemID, url: URL)]
    {
        func root(_ id: StemID) -> StemKind? {
            StemKind(rawValue: id.rawValue.split(separator: ".").first.map(String.init) ?? "")
        }
        guard entries.contains(where: { root($0.id) == .guitar || root($0.id) == .piano }) else {
            return entries
        }
        return entries.filter { root($0.id) != .other }
    }

    /// Drops an instrument stem that is only separation residue.
    ///
    /// The analyzer peak-normalises each stem to ITSELF before its silence threshold, so a stem
    /// holding nothing but bleed is amplified to full scale and reports a part: 40 notes on Seven
    /// Bridges Road's piano stem, which sits at -85 dB on a recording with no piano. This is the
    /// pairing `HarmonyStemMix` documents — normalisation is only safe behind the leakage gate —
    /// and the same gate, `HarmonyStemMix.keptAfterLeakageGate`, that `InstrumentChordPass` uses.
    ///
    /// Compared among the separate instrument stems only. The summed `accompaniment` is left out
    /// of the comparison (as the loudest it would set the bar for the stems it is made of), and
    /// so are voice and bass, which answer to their own tests.
    static func withoutPhantomInstruments(_ entries: [(id: StemID, url: URL)])
        -> [(id: StemID, url: URL)]
    {
        let instruments = entries.indices.filter {
            BucketNoteAnalyzer.role(for: entries[$0].id) == .polyphonic
                && !entries[$0].id.rawValue.hasPrefix("accompaniment")
        }
        guard instruments.count > 1 else { return entries }
        // An unreadable stem measures 0 and drops out, exactly as the analyzer would skip it.
        let levels = instruments.map { index -> Float in
            guard let audio = try? MonoAudioFile.samples(url: entries[index].url) else { return 0 }
            return HarmonyStemMix.rootMeanSquare(audio.samples)
        }
        let kept = HarmonyStemMix.keptAfterLeakageGate(levels)
        let dropped = Set(instruments.indices.filter { !kept.contains($0) }.map { instruments[$0] })
        return entries.indices.filter { !dropped.contains($0) }.map { entries[$0] }
    }

    /// Cuts every pitched stem on the document's current metronome grid. `nil` when there is
    /// no grid or no stems; a stem whose file cannot be read is simply absent from the result.
    static func timeline(for document: SongAnalysisDocument) -> BucketNoteTimeline? {
        guard let key = gridKey(for: document) else { return nil }
        // Half-beat buckets (Eric, 2026-10-07: changes snap to the half-beat), so a pushed
        // eighth-note change lands where it was played.
        let clicks = halfBeats(
            MetronomeGrid.clickTimes(
                beatTimes: document.beatTimes, bpm: document.estimatedBPM,
                barGrid: document.barGrid, duration: key.duration))
        guard clicks.count >= 2 else { return nil }
        let audio = stemAudio(for: document)
        guard !audio.isEmpty else { return nil }
        let analyzer = BucketNoteAnalyzer()
        var stems: [StemBucketNotes] = []
        for entry in audio {
            guard let role = BucketNoteAnalyzer.role(for: entry.id),
                let notes = try? analyzer.analyze(url: entry.url, role: role, clickTimes: clicks)
            else { continue }
            stems.append(StemBucketNotes(stemID: entry.id, notes: notes))
        }
        guard !stems.isEmpty else { return nil }
        return BucketNoteTimeline(gridKey: key, clickTimes: clicks, stems: stems)
    }

    /// Every beat and the midpoint after it.
    static func halfBeats(_ beats: [TimeInterval]) -> [TimeInterval] {
        zip(beats, beats.dropFirst()).flatMap { [$0, ($0 + $1) / 2] } + beats.suffix(1)
    }

    /// Recomputes the timeline when the stored one is missing or stale for the document's
    /// current grid — or always when `force` is set, which is what a fresh harmony run does,
    /// since the stems it listened to may themselves be new even if the grid is not.
    static func apply(to document: inout SongAnalysisDocument, force: Bool = false) {
        if !force, let existing = document.bucketNotes,
            existing.isCurrent(for: gridKey(for: document))
        {
            return
        }
        if let fresh = timeline(for: document) {
            document.bucketNotes = fresh
        }
    }

    private static func duration(for document: SongAnalysisDocument) -> TimeInterval {
        if let source = document.sourceDuration, source > 0 { return source }
        return document.beatTimes.max() ?? 0
    }
}
