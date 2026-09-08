import Foundation

/// A run of metronome buckets on one stem where it plays a single melodic line — a solo, a riff,
/// a fill — as opposed to chords or nothing. Bucket indices are inclusive and refer to the
/// timeline's `clickTimes`; the times are the run's first click and the click after its last.
struct SoloPassage: Codable, Equatable, Sendable {
    var stemID: StemID
    var startBucket: Int
    var endBucket: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// 0…1: the mean share of lead-like frames over the run's lead buckets.
    var confidence: Float
}

/// One note of a transcribed passage, on a 16th-note grid counted from the passage's first
/// click. `string` indexes `GuitarTabAssigner.standardTuning` (0 = low E … 5 = high e). Gaps
/// between notes are rests.
struct SoloNote: Codable, Equatable, Sendable {
    var startSixteenth: Int
    var lengthSixteenths: Int
    var midiNote: Int
    var confidence: Float
    var string: Int
    var fret: Int
}

/// A passage and its notes, laid on a guitar fretboard. Piano and "other" stems get guitar tab
/// too: Eric's decision — tab is the display he reads, whatever instrument the model split the
/// line onto, and a keyboard line rendered as frets is still a playable transcription.
struct SoloTranscription: Codable, Equatable, Sendable {
    var stemID: StemID
    var passage: SoloPassage
    var notes: [SoloNote]
}

/// All solo transcriptions for a song on one metronome grid. Same staleness contract as
/// `BucketNoteTimeline`: the grid key and version tag say whether it may be shown.
struct SoloTranscriptionTimeline: Codable, Equatable, Sendable {
    /// Bump when classification, transcription or tab assignment semantics change.
    static let currentVersionTag = "solos-1"

    var versionTag: String
    var gridKey: BucketGridKey
    var clickTimes: [TimeInterval]
    var transcriptions: [SoloTranscription]

    init(gridKey: BucketGridKey, clickTimes: [TimeInterval], transcriptions: [SoloTranscription]) {
        self.versionTag = Self.currentVersionTag
        self.gridKey = gridKey
        self.clickTimes = clickTimes
        self.transcriptions = transcriptions
    }

    func isCurrent(for key: BucketGridKey?) -> Bool {
        guard let key else { return false }
        return versionTag == Self.currentVersionTag && gridKey.matches(key)
    }

    /// Song time of `sixteenth` (counted from the passage's first click) on this grid: the
    /// bucket's click plus a quarter of that bucket's own span per 16th, so the columns stay on
    /// the beat even where the grid was fitted rather than periodic. `nil` past the grid's end.
    func time(ofSixteenth sixteenth: Int, in passage: SoloPassage) -> TimeInterval? {
        let bucket = passage.startBucket + sixteenth / 4
        guard bucket >= 0, bucket + 1 < clickTimes.count else { return nil }
        let span = clickTimes[bucket + 1] - clickTimes[bucket]
        return clickTimes[bucket] + span * Double(sixteenth % 4) / 4
    }
}

/// Finds lead-line passages on a melodic stem and transcribes them at 16th-note resolution.
/// The classifier and grouper are pure static functions over frame streams so the contract is
/// testable on synthetic audio; `analyze(url:)` is the file-backed entry the pass uses.
struct SoloTranscriptionAnalyzer: Sendable {
    enum BucketClass: Equatable, Sendable {
        case silent
        case lead
        case chordal
    }

    struct BucketVerdict: Equatable, Sendable {
        let bucketIndex: Int
        let kind: BucketClass
        /// For `lead`: the share of the bucket's voiced frames that were lead-like.
        let confidence: Float
    }

    /// A frame is lead-like when at most this many pitch classes carry at least half the top
    /// class's chroma share. A single plucked note puts its fundamental and even harmonics in one
    /// class and only a weaker fifth (3rd/6th harmonics) elsewhere; a triad spreads three classes
    /// nearly evenly. Two is allowed so a note's strong fifth partial does not read as a chord —
    /// which also means a bare power chord reads as lead (known limit, see tasks/spec-solo-tab.md).
    static let maximumLeadClasses = 2
    static let dominantClassShare: Float = 0.5
    /// A bucket needs this share of voiced frames to be heard at all (same gate as bucket notes).
    static let minimumCoverage: Float = BucketNoteAnalyzer.minimumCoverage
    /// Lead needs this share of the bucket's voiced chroma frames to be lead-like…
    static let minimumLeadShare: Float = 0.6
    /// …and the pitch tracker to have found a note in this share of them, so a noisy but sparse
    /// frame (a scrape, a muted pluck) is not a lead.
    static let minimumPitchCoverage: Float = 0.4
    /// A passage is at least this many bars of lead buckets.
    static let minimumPassageBars = 2
    /// A single non-lead bucket inside a run (a breath, a chord stab) does not end it.
    static let maximumGapBuckets = 1

    /// Melodic stems the solo pass listens to: everything pitched that is neither bass nor voice.
    static func isMelodicStem(_ stemID: StemID) -> Bool {
        BucketNoteAnalyzer.role(for: stemID) == .polyphonic
    }

    // MARK: - Entry points

    func analyze(url: URL, clickTimes: [TimeInterval], beatsPerBar: Int, stemID: StemID) throws
        -> [SoloTranscription]
    {
        let (samples, sampleRate) = try MonoSampleLoader.load(url: url)
        try Task.checkCancellation()
        return transcriptions(
            samples: samples, sampleRate: sampleRate, clickTimes: clickTimes,
            beatsPerBar: beatsPerBar, stemID: stemID)
    }

    func transcriptions(
        samples: [Float], sampleRate: Double, clickTimes: [TimeInterval], beatsPerBar: Int,
        stemID: StemID
    ) -> [SoloTranscription] {
        guard clickTimes.count >= 2, sampleRate > 0, !samples.isEmpty else { return [] }
        let chroma = BucketNoteAnalyzer.chromaFrames(samples: samples, sampleRate: sampleRate)
        let pitch = VocalHarmonyAnalyzer(
            maximumNotesPerFrame: 1, midiRange: VocalHarmonyAnalyzer.guitarMidiRange
        ).frameEstimates(samples: samples, sampleRate: sampleRate)
        let verdicts = Self.classifyBuckets(
            chromaFrames: chroma, pitchFrames: pitch, clickTimes: clickTimes)
        return Self.passages(
            verdicts: verdicts, clickTimes: clickTimes, beatsPerBar: beatsPerBar, stemID: stemID
        ).map { passage in
            SoloTranscription(
                stemID: stemID, passage: passage,
                notes: Self.transcribe(
                    passage: passage, pitchFrames: pitch, clickTimes: clickTimes))
        }
    }

    // MARK: - Classification (pure)

    /// True when the frame's chroma has at most `maximumLeadClasses` dominant pitch classes.
    static func isLeadLike(chroma: [Float]) -> Bool {
        guard chroma.count == 12, let top = chroma.max(), top > 0 else { return false }
        let dominant = chroma.filter { $0 >= top * dominantClassShare }.count
        return dominant <= maximumLeadClasses
    }

    /// One verdict per bucket of `clickTimes`. Chroma frames decide silent/lead/chordal by
    /// majority of voiced frames; the pitch tracker must also have been able to name a note in
    /// enough of them for the bucket to count as lead.
    static func classifyBuckets(
        chromaFrames: [BucketNoteAnalyzer.ChromaFrame], pitchFrames: [PitchFrameEstimate],
        clickTimes: [TimeInterval]
    ) -> [BucketVerdict] {
        let bucketCount = clickTimes.count - 1
        guard bucketCount > 0 else { return [] }
        var total = [Int](repeating: 0, count: bucketCount)
        var voiced = [Int](repeating: 0, count: bucketCount)
        var lead = [Int](repeating: 0, count: bucketCount)
        for frame in chromaFrames {
            guard
                let bucket = BucketNoteAnalyzer.bucketIndex(for: frame.time, clickTimes: clickTimes)
            else { continue }
            total[bucket] += 1
            guard frame.weight > 0 else { continue }
            voiced[bucket] += 1
            if isLeadLike(chroma: frame.chroma) { lead[bucket] += 1 }
        }
        var pitchTotal = [Int](repeating: 0, count: bucketCount)
        var pitched = [Int](repeating: 0, count: bucketCount)
        for frame in pitchFrames {
            guard
                let bucket = BucketNoteAnalyzer.bucketIndex(for: frame.time, clickTimes: clickTimes)
            else { continue }
            pitchTotal[bucket] += 1
            if frame.midiNote != nil, frame.confidence > 0 { pitched[bucket] += 1 }
        }
        return (0..<bucketCount).map { bucket in
            guard total[bucket] > 0,
                Float(voiced[bucket]) / Float(total[bucket]) >= minimumCoverage
            else { return BucketVerdict(bucketIndex: bucket, kind: .silent, confidence: 0) }
            let leadShare = Float(lead[bucket]) / Float(voiced[bucket])
            let pitchCoverage =
                pitchTotal[bucket] > 0 ? Float(pitched[bucket]) / Float(pitchTotal[bucket]) : 0
            if leadShare >= minimumLeadShare, pitchCoverage >= minimumPitchCoverage {
                return BucketVerdict(bucketIndex: bucket, kind: .lead, confidence: leadShare)
            }
            return BucketVerdict(bucketIndex: bucket, kind: .chordal, confidence: leadShare)
        }
    }

    /// Groups lead buckets into passages: runs of lead verdicts, tolerating up to
    /// `maximumGapBuckets` consecutive non-lead buckets inside a run, kept when the run spans
    /// at least `minimumPassageBars` bars. A run's edges are always lead buckets.
    static func passages(
        verdicts: [BucketVerdict], clickTimes: [TimeInterval], beatsPerBar: Int, stemID: StemID
    ) -> [SoloPassage] {
        let minimumBuckets = max(beatsPerBar, 1) * minimumPassageBars
        var passages: [SoloPassage] = []
        var runStart: Int?
        var runEnd = 0
        var gap = 0
        var confidences: [Float] = []

        func close() {
            if let start = runStart, runEnd - start + 1 >= minimumBuckets,
                runEnd + 1 < clickTimes.count
            {
                passages.append(
                    SoloPassage(
                        stemID: stemID, startBucket: start, endBucket: runEnd,
                        startTime: clickTimes[start], endTime: clickTimes[runEnd + 1],
                        confidence: confidences.reduce(0, +) / Float(max(confidences.count, 1))))
            }
            runStart = nil
            gap = 0
            confidences = []
        }

        for verdict in verdicts.sorted(by: { $0.bucketIndex < $1.bucketIndex }) {
            if verdict.kind == .lead {
                if runStart == nil { runStart = verdict.bucketIndex }
                runEnd = verdict.bucketIndex
                gap = 0
                confidences.append(verdict.confidence)
            } else if runStart != nil {
                gap += 1
                if gap > maximumGapBuckets { close() }
            }
        }
        close()
        return passages
    }

    // MARK: - Transcription (pure)

    /// One note or rest per 16th of the passage — each bucket split four ways on its own span —
    /// then consecutive equal notes merged into one with a length, so a held note renders as a
    /// fret followed by dashes. A 16th with no pitch frame at all (fast tempo, 46 ms hop) holds
    /// the previous note rather than breaking it; one with frames but no voiced one is a rest.
    static func transcribe(
        passage: SoloPassage, pitchFrames: [PitchFrameEstimate], clickTimes: [TimeInterval]
    ) -> [SoloNote] {
        guard passage.startBucket >= 0, passage.endBucket + 1 < clickTimes.count else { return [] }
        var edges: [TimeInterval] = []
        for bucket in passage.startBucket...passage.endBucket {
            let start = clickTimes[bucket]
            let span = clickTimes[bucket + 1] - start
            for sub in 0..<4 { edges.append(start + span * Double(sub) / 4) }
        }
        edges.append(clickTimes[passage.endBucket + 1])
        let count = edges.count - 1
        var votes = [[Int: Float]](repeating: [:], count: count)
        var seen = [Bool](repeating: false, count: count)
        for frame in pitchFrames {
            guard let index = BucketNoteAnalyzer.bucketIndex(for: frame.time, clickTimes: edges)
            else { continue }
            seen[index] = true
            if let midi = frame.midiNote, frame.confidence > 0 {
                votes[index][midi, default: 0] += frame.confidence
            }
        }
        var perSixteenth: [(midi: Int, confidence: Float)?] = []
        for index in 0..<count {
            if let winner = votes[index].max(by: { $0.value < $1.value }) {
                let mass = votes[index].values.reduce(0, +)
                perSixteenth.append((winner.key, mass > 0 ? winner.value / mass : 0))
            } else if !seen[index], index > 0 {
                perSixteenth.append(perSixteenth[index - 1])
            } else {
                perSixteenth.append(nil)
            }
        }
        var notes: [SoloNote] = []
        for (index, entry) in perSixteenth.enumerated() {
            guard let entry else { continue }
            if let last = notes.last, last.midiNote == entry.midi,
                last.startSixteenth + last.lengthSixteenths == index
            {
                notes[notes.count - 1].lengthSixteenths += 1
                notes[notes.count - 1].confidence = min(last.confidence, entry.confidence)
            } else {
                notes.append(
                    SoloNote(
                        startSixteenth: index, lengthSixteenths: 1, midiNote: entry.midi,
                        confidence: entry.confidence, string: 0, fret: 0))
            }
        }
        let positions = GuitarTabAssigner.assign(midiNotes: notes.map(\.midiNote))
        for index in notes.indices {
            notes[index].string = positions[index].string
            notes[index].fret = positions[index].fret
        }
        return notes
    }
}

/// Lays a note sequence on a standard-tuned fretboard so runs stay in one hand position.
/// Dynamic programming over hand positions (the index finger's fret; a position covers four
/// frets plus open strings) with cost = position movement, a small penalty for open strings
/// mid-run and for playing above the 15th fret. Notes outside the fretboard are clamped to its
/// nearest edge — never dropped, so the tab keeps the rhythm even when the pitch is wrong.
enum GuitarTabAssigner {
    /// E2 A2 D3 G3 B3 E4, low to high.
    static let standardTuning = [40, 45, 50, 55, 59, 64]
    static let maximumFret = 22
    static let positionSpan = 4
    static let openStringPenalty: Float = 0.5
    static let highFretPenalty: Float = 1
    static let highFretThreshold = 15

    static func assign(midiNotes: [Int]) -> [(string: Int, fret: Int)] {
        guard !midiNotes.isEmpty else { return [] }
        let lowest = standardTuning[0]
        let highest = standardTuning[standardTuning.count - 1] + maximumFret
        let clamped = midiNotes.map { min(max($0, lowest), highest) }
        let positions = Array(0...(maximumFret - positionSpan))
        // options[i][p]: the (string, fret) to play note i in position p, nil if unreachable.
        let options: [[(string: Int, fret: Int)?]] = clamped.map { midi in
            positions.map { placement(for: midi, position: $0) }
        }
        var cost = [[Float]](
            repeating: [Float](repeating: .infinity, count: positions.count), count: clamped.count)
        var back = [[Int]](
            repeating: [Int](repeating: 0, count: positions.count), count: clamped.count)
        for (p, option) in options[0].enumerated() {
            guard let option else { continue }
            cost[0][p] = emission(option, isFirst: true)
        }
        for i in 1..<clamped.count {
            for (p, option) in options[i].enumerated() {
                guard let option else { continue }
                var best: Float = .infinity
                var bestPrevious = 0
                for q in positions.indices where cost[i - 1][q] < .infinity {
                    let candidate = cost[i - 1][q] + Float(abs(p - q))
                    if candidate < best {
                        best = candidate
                        bestPrevious = q
                    }
                }
                cost[i][p] = best + emission(option, isFirst: false)
                back[i][p] = bestPrevious
            }
        }
        var p =
            cost[clamped.count - 1].indices.min {
                cost[clamped.count - 1][$0] < cost[clamped.count - 1][$1]
            } ?? 0
        var result: [(string: Int, fret: Int)] = []
        for i in stride(from: clamped.count - 1, through: 0, by: -1) {
            result.append(options[i][p] ?? (string: 0, fret: 0))
            p = back[i][p]
        }
        return result.reversed()
    }

    /// The string to play `midi` on in `position`: fretted within the span first (lowest fret
    /// wins), else an open string.
    static func placement(for midi: Int, position: Int) -> (string: Int, fret: Int)? {
        var open: (string: Int, fret: Int)?
        var fretted: (string: Int, fret: Int)?
        for (string, tuning) in standardTuning.enumerated() {
            let fret = midi - tuning
            guard fret >= 0, fret <= maximumFret else { continue }
            if fret == 0 {
                open = (string, 0)
            } else if fret >= position, fret <= position + positionSpan,
                fretted == nil || fret < fretted!.fret
            {
                fretted = (string, fret)
            }
        }
        return fretted ?? open
    }

    private static func emission(_ option: (string: Int, fret: Int), isFirst: Bool) -> Float {
        var cost: Float = 0
        if option.fret == 0, !isFirst { cost += openStringPenalty }
        if option.fret > highFretThreshold { cost += highFretPenalty }
        return cost
    }
}

/// The pipeline/app step that turns a document's melodic stems and timing into its solo
/// transcriptions. Runs right after `BucketNotePass` on the same grid and is best-effort.
enum SoloTranscriptionPass {
    static func gridKey(for document: SongAnalysisDocument) -> BucketGridKey? {
        BucketNotePass.gridKey(for: document)
    }

    /// The melodic stems (guitars, piano, other, accompaniment) among the document's playable
    /// stem leaves.
    static func stemAudio(for document: SongAnalysisDocument) -> [(id: StemID, url: URL)] {
        BucketNotePass.stemAudio(for: document).filter {
            SoloTranscriptionAnalyzer.isMelodicStem($0.id)
        }
    }

    static func timeline(for document: SongAnalysisDocument) -> SoloTranscriptionTimeline? {
        guard let key = gridKey(for: document) else { return nil }
        let clicks = MetronomeGrid.clickTimes(
            beatTimes: document.beatTimes, bpm: document.estimatedBPM, barGrid: document.barGrid,
            duration: key.duration)
        guard clicks.count >= 2 else { return nil }
        let audio = stemAudio(for: document)
        guard !audio.isEmpty else { return nil }
        let beatsPerBar = document.barGrid?.beatsPerBar ?? SongBarGrid.unknown.beatsPerBar
        let analyzer = SoloTranscriptionAnalyzer()
        var transcriptions: [SoloTranscription] = []
        for entry in audio {
            guard
                let found = try? analyzer.analyze(
                    url: entry.url, clickTimes: clicks, beatsPerBar: beatsPerBar, stemID: entry.id)
            else { continue }
            transcriptions.append(contentsOf: found)
        }
        return SoloTranscriptionTimeline(
            gridKey: key, clickTimes: clicks, transcriptions: transcriptions)
    }

    /// Recomputes when the stored timeline is missing or stale for the current grid, or always
    /// when `force` is set (a fresh harmony run may have new stems on the same grid).
    static func apply(to document: inout SongAnalysisDocument, force: Bool = false) {
        if !force, let existing = document.soloTranscriptions,
            existing.isCurrent(for: gridKey(for: document))
        {
            return
        }
        if let fresh = timeline(for: document) {
            document.soloTranscriptions = fresh
        }
    }
}
