import AVFoundation
import XCTest

@testable import SongWorkbench

final class BucketNoteAnalyzerTests: XCTestCase {
    private let sampleRate = 44_100.0

    // MARK: - Pure aggregation

    func testMonophonicBucketTakesConfidenceWeightedModeAndSkipsRests() {
        let clicks: [TimeInterval] = [0, 1, 2, 3]
        // Bucket 0: A2 (45) dominates by weight though E2 (40) has more frames.
        // Bucket 1: silent. Bucket 2: one voiced frame of six → below the 20% coverage gate → rest.
        let frames: [PitchFrameEstimate] = [
            .init(time: 0.1, midiNote: 40, confidence: 0.3),
            .init(time: 0.3, midiNote: 40, confidence: 0.3),
            .init(time: 0.5, midiNote: 45, confidence: 0.9),
            .init(time: 0.7, midiNote: 45, confidence: 0.9),
            .init(time: 0.9, midiNote: 40, confidence: 0.3),
            .init(time: 1.2, midiNote: nil, confidence: 0),
            .init(time: 1.6, midiNote: nil, confidence: 0),
            .init(time: 2.1, midiNote: 47, confidence: 0.9),
            .init(time: 2.3, midiNote: nil, confidence: 0),
            .init(time: 2.5, midiNote: nil, confidence: 0),
            .init(time: 2.7, midiNote: nil, confidence: 0),
            .init(time: 2.8, midiNote: nil, confidence: 0),
            .init(time: 2.9, midiNote: nil, confidence: 0),
        ]
        let notes = BucketNoteAnalyzer.aggregateMonophonic(frames: frames, clickTimes: clicks)

        XCTAssertEqual(notes.map(\.bucketIndex), [0])
        XCTAssertEqual(notes[0].midiNote, 45)
        XCTAssertEqual(notes[0].pitchClasses, [9])
        XCTAssertEqual(notes[0].confidence, 1.8 / 2.7, accuracy: 1e-5)
        XCTAssertEqual(notes[0].coverage, 1)
    }

    func testMonophonicTiesAreReproducibleAndGoToTheLowerNote() {
        // Voice frames saturate at confidence 1, so equal votes are common. `Dictionary` order is
        // randomly seeded: the verdict must not depend on it.
        let clicks = (0...40).map(TimeInterval.init)
        var frames: [PitchFrameEstimate] = []
        for bucket in 0..<40 {
            let notes = [60 + bucket % 7, 48 + bucket % 5, 70 - bucket % 3, 55]
            for (offset, note) in notes.enumerated() {
                frames.append(
                    .init(
                        time: Double(bucket) + 0.1 + 0.2 * Double(offset), midiNote: note,
                        confidence: 1))
            }
        }
        let first = BucketNoteAnalyzer.aggregateMonophonic(frames: frames, clickTimes: clicks)
        XCTAssertEqual(first.map(\.midiNote), (0..<40).map { 48 + $0 % 5 })
        XCTAssertEqual(
            first, BucketNoteAnalyzer.aggregateMonophonic(frames: frames, clickTimes: clicks))
    }

    func testVoiceBucketNotesAreIdenticalRunToRun() {
        // A sung line with a held two-note interval: equal-strength partials make tied votes.
        let clicks = stride(from: 0.0, through: 4.0, by: 0.25).map { $0 }
        let samples = (0..<Int(4 * sampleRate)).map { index -> Float in
            let time = Double(index) / sampleRate
            let segment = Int(time / 0.5)
            let low = 220 * pow(2, Double(segment % 4) / 12)
            return Float(0.4 * sin(2 * .pi * low * time) + 0.4 * sin(2 * .pi * low * 1.5 * time))
        }
        let analyzer = BucketNoteAnalyzer()
        let first = analyzer.notes(
            role: .voice, samples: samples, sampleRate: sampleRate, clickTimes: clicks)
        let second = analyzer.notes(
            role: .voice, samples: samples, sampleRate: sampleRate, clickTimes: clicks)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func testFramesOutsideTheGridAreIgnoredAndEdgesBelongToTheLaterBucket() {
        let clicks: [TimeInterval] = [1, 2]
        let frames: [PitchFrameEstimate] = [
            .init(time: 0.5, midiNote: 40, confidence: 1),  // before the first click
            .init(time: 1.0, midiNote: 41, confidence: 1),  // exactly on the edge → bucket 0
            .init(time: 2.0, midiNote: 42, confidence: 1),  // on the last click → outside
        ]
        let notes = BucketNoteAnalyzer.aggregateMonophonic(frames: frames, clickTimes: clicks)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].midiNote, 41)
        XCTAssertNil(BucketNoteAnalyzer.bucketIndex(for: 0.99, clickTimes: clicks))
        XCTAssertEqual(BucketNoteAnalyzer.bucketIndex(for: 1.5, clickTimes: [0, 1, 2, 3]), 1)
    }

    func testPolyphonicBucketListsSharesAboveThresholdStrongestFirst() {
        let clicks: [TimeInterval] = [0, 1]
        var triad = [Float](repeating: 0, count: 12)
        triad[0] = 0.5  // C
        triad[4] = 0.3  // E
        triad[7] = 0.15  // G — under 60% of the top class (0.5), so not listed
        triad[9] = 0.05
        let frames = [
            BucketNoteAnalyzer.ChromaFrame(time: 0.25, chroma: triad, weight: 1),
            BucketNoteAnalyzer.ChromaFrame(time: 0.75, chroma: triad, weight: 1),
        ]
        let notes = BucketNoteAnalyzer.aggregatePolyphonic(frames: frames, clickTimes: clicks)
        XCTAssertEqual(notes.count, 1)
        XCTAssertNil(notes[0].midiNote)
        XCTAssertEqual(notes[0].pitchClasses, [0, 4])
        XCTAssertEqual(notes[0].confidence, 0.5, accuracy: 1e-5)
    }

    func testPolyphonicWeightsLoudFramesMore() {
        let clicks: [TimeInterval] = [0, 1]
        var c = [Float](repeating: 0, count: 12)
        c[0] = 1
        var g = [Float](repeating: 0, count: 12)
        g[7] = 1
        let frames = [
            BucketNoteAnalyzer.ChromaFrame(time: 0.2, chroma: c, weight: 0.1),
            BucketNoteAnalyzer.ChromaFrame(time: 0.5, chroma: g, weight: 0.9),
            BucketNoteAnalyzer.ChromaFrame(time: 0.8, chroma: c, weight: 0),  // silent
        ]
        let notes = BucketNoteAnalyzer.aggregatePolyphonic(frames: frames, clickTimes: clicks)
        XCTAssertEqual(notes[0].pitchClasses.first, 7)
        XCTAssertEqual(notes[0].coverage, 2.0 / 3.0, accuracy: 1e-5)
    }

    // MARK: - End to end on synthetic audio

    func testBassToneChangingAtBucketEdgesYieldsOneNotePerBucket() {
        // 4 s at 120 BPM (clicks every 0.5 s): E2 for 2 s, then A2 for 2 s.
        let e2 = 82.41
        let a2 = 110.0
        let samples = tone(frequency: e2, duration: 2) + tone(frequency: a2, duration: 2)
        let clicks = MetronomeGrid.periodicGrid(period: 0.5, anchor: 0, duration: 4)
        let notes = BucketNoteAnalyzer().notes(
            role: .bass, samples: samples, sampleRate: sampleRate, clickTimes: clicks)

        XCTAssertEqual(notes.map(\.bucketIndex), Array(0..<8))
        XCTAssertEqual(notes.prefix(4).map(\.midiNote), [40, 40, 40, 40])
        XCTAssertEqual(notes.suffix(4).map(\.midiNote), [45, 45, 45, 45])
        for note in notes { XCTAssertGreaterThan(note.confidence, 0.6) }
    }

    func testSilentStemProducesNoBucketNotes() {
        let silence = [Float](repeating: 0, count: Int(sampleRate * 3))
        let clicks = MetronomeGrid.periodicGrid(period: 0.5, anchor: 0, duration: 3)
        for role in [BucketNoteAnalyzer.StemRole.bass, .voice, .polyphonic] {
            XCTAssertTrue(
                BucketNoteAnalyzer().notes(
                    role: role, samples: silence, sampleRate: sampleRate, clickTimes: clicks
                ).isEmpty, "\(role)")
        }
    }

    func testPolyphonicTriadOnRealChromaNamesItsPitchClasses() {
        // C major triad (C4 E4 G4) for 2 s: the bucket lists C, E, G in some order.
        let chord = mix(
            tone(frequency: 261.63, duration: 2), tone(frequency: 329.63, duration: 2),
            tone(frequency: 392.0, duration: 2))
        let clicks: [TimeInterval] = [0, 1, 2]
        let notes = BucketNoteAnalyzer().notes(
            role: .polyphonic, samples: chord, sampleRate: sampleRate, clickTimes: clicks)
        XCTAssertEqual(notes.count, 2)
        for note in notes {
            XCTAssertEqual(
                Set(note.pitchClasses).intersection([0, 4, 7]).count, note.pitchClasses.count)
            XCTAssertTrue(note.pitchClasses.contains(0))
        }
    }

    // MARK: - Roles, keys, persistence

    func testRolesByStemID() {
        XCTAssertEqual(BucketNoteAnalyzer.role(for: StemID(.bass)), .bass)
        XCTAssertEqual(BucketNoteAnalyzer.role(for: StemID(.vocals)), .voice)
        XCTAssertEqual(BucketNoteAnalyzer.role(for: .vocalLead), .voice)
        XCTAssertEqual(BucketNoteAnalyzer.role(for: .guitarRhythm), .polyphonic)
        XCTAssertEqual(BucketNoteAnalyzer.role(for: StemID(.piano)), .polyphonic)
        XCTAssertEqual(BucketNoteAnalyzer.role(for: "accompaniment"), .polyphonic)
        XCTAssertNil(BucketNoteAnalyzer.role(for: StemID(.drums)))
        XCTAssertNil(BucketNoteAnalyzer.role(for: .drumKick))
    }

    func testGridKeyTracksTheDocumentTimingAndTimelineStaleness() throws {
        let grid = SongBarGrid(
            beatsPerBar: 4, barPhase: 1, confidence: 0.5, phaseSource: .drumAccents)
        let key = try XCTUnwrap(
            BucketGridKey.current(
                beatTimes: [0.5, 1.0, 1.5], bpm: 120, barGrid: grid, duration: 10))
        XCTAssertEqual(key.anchor, 1.0)
        XCTAssertNil(BucketGridKey.current(beatTimes: [0.5], bpm: nil, barGrid: grid, duration: 10))
        XCTAssertNil(BucketGridKey.current(beatTimes: [], bpm: 120, barGrid: grid, duration: 10))

        let timeline = BucketNoteTimeline(gridKey: key, clickTimes: [0, 0.5, 1], stems: [])
        XCTAssertTrue(timeline.isCurrent(for: key))
        XCTAssertFalse(timeline.isCurrent(for: nil))
        XCTAssertFalse(
            timeline.isCurrent(for: BucketGridKey(bpm: 60, anchor: 1.0, duration: 10)))  // retuned
        XCTAssertTrue(
            timeline.isCurrent(for: BucketGridKey(bpm: 120, anchor: 1.0 + 1e-9, duration: 10)))

        var stale = timeline
        stale.versionTag = "buckets-1"
        XCTAssertFalse(stale.isCurrent(for: key))

        let data = try JSONEncoder().encode(timeline)
        XCTAssertEqual(try JSONDecoder().decode(BucketNoteTimeline.self, from: data), timeline)
    }

    func testDocumentRoundTripsBucketNotesAndOlderDocumentsDecodeNil() throws {
        let key = BucketGridKey(bpm: 100, anchor: 0.25, duration: 30)
        let timeline = BucketNoteTimeline(
            gridKey: key, clickTimes: [0.25, 0.85],
            stems: [
                StemBucketNotes(
                    stemID: StemID(.bass),
                    notes: [
                        StemBucketNote(
                            bucketIndex: 0, midiNote: 40, pitchClasses: [4], confidence: 0.9,
                            coverage: 1)
                    ])
            ])
        let document = SongAnalysisDocument(estimatedBPM: 100, bucketNotes: timeline)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SongAnalysisDocument.self, from: data)
        XCTAssertEqual(decoded.bucketNotes, timeline)

        let older = try JSONDecoder().decode(
            SongAnalysisDocument.self, from: Data("{}".utf8))
        XCTAssertNil(older.bucketNotes)
    }

    func testPassSkipsCurrentTimelineUnlessForcedAndLeavesDocumentsWithoutStemsAlone() {
        var document = SongAnalysisDocument(
            sourceDuration: 4, estimatedBPM: 120, beatTimes: [0.5, 1.0, 1.5, 2.0])
        XCTAssertNotNil(BucketNotePass.gridKey(for: document))
        XCTAssertTrue(BucketNotePass.stemAudio(for: document).isEmpty)
        BucketNotePass.apply(to: &document)
        XCTAssertNil(document.bucketNotes)  // no stems → nothing to cut, nothing invented

        let current = BucketNoteTimeline(
            gridKey: BucketNotePass.gridKey(for: document)!, clickTimes: [0, 0.5], stems: [])
        document.bucketNotes = current
        BucketNotePass.apply(to: &document)
        XCTAssertEqual(document.bucketNotes, current)  // current → untouched
        BucketNotePass.apply(to: &document, force: true)
        XCTAssertEqual(document.bucketNotes, current)  // forced but no stems → keeps the old
    }

    /// The Review menu's enable checks run on every playback tick, so the ungated listing must
    /// never open a stem: files that are not audio at all still count as present. The gated list
    /// (what the passes use) does open them, and drops the unreadable instruments as silent.
    func testUngatedStemListingNeverOpensAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func notAudio(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent("\(name).wav")
            try Data("not audio".utf8).write(to: url)
            return url
        }
        var document = SongAnalysisDocument(
            sourceDuration: 4, estimatedBPM: 120, beatTimes: [0.5, 1.0, 1.5, 2.0])
        document.stems = StoredStemFiles(
            files: StemFiles(
                vocals: try notAudio("vocals"), drums: try notAudio("drums"),
                bass: try notAudio("bass"), guitar: try notAudio("guitar"),
                piano: try notAudio("piano"), other: try notAudio("other")))

        XCTAssertEqual(
            InstrumentChordPass.stemAudio(for: document, gated: false).map(\.id),
            [StemID(.guitar), StemID(.piano)])
        XCTAssertFalse(SoloTranscriptionPass.stemAudio(for: document, gated: false).isEmpty)
        XCTAssertFalse(BucketNotePass.stemAudio(for: document, gated: false).isEmpty)
        XCTAssertTrue(InstrumentChordPass.stemAudio(for: document).isEmpty)
    }

    // MARK: - Review row formatting

    func testRowsAreWindowedOrderedAndTransposedWithBassLast() {
        let key = BucketGridKey(bpm: 120, anchor: 0, duration: 4)
        let clicks: [TimeInterval] = [0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
        let timeline = BucketNoteTimeline(
            gridKey: key, clickTimes: clicks,
            stems: [
                StemBucketNotes(
                    stemID: StemID(.bass),
                    notes: [
                        StemBucketNote(
                            bucketIndex: 2, midiNote: 40, pitchClasses: [4], confidence: 0.9,
                            coverage: 1),
                        StemBucketNote(
                            bucketIndex: 6, midiNote: 45, pitchClasses: [9], confidence: 0.9,
                            coverage: 1),
                    ]),
                StemBucketNotes(
                    stemID: StemID(.guitar),
                    notes: [
                        StemBucketNote(
                            bucketIndex: 3, midiNote: nil, pitchClasses: [4, 8, 11],
                            confidence: 0.3, coverage: 0.8)
                    ]),
                StemBucketNotes(
                    stemID: .vocalLead,
                    notes: [
                        StemBucketNote(
                            bucketIndex: 2, midiNote: 64, pitchClasses: [4], confidence: 0.7,
                            coverage: 0.5)
                    ]),
                StemBucketNotes(stemID: StemID(.piano), notes: []),
            ])

        let rows = BucketNoteRowFormatter.rows(
            timeline: timeline, inWindow: 1.0...2.0, transposedBy: 1)

        // Voice, guitar, bass — one row per player, no chord spelled across them; the empty piano
        // stem is dropped.
        XCTAssertEqual(rows.map(\.label), ["Ld", "Gt", "Bs"])
        XCTAssertEqual(rows[0].cells, [BucketNoteRowCell(time: 1.0, text: "F", isDim: false)])
        // Guitar E·G#·B transposed up one spells F major.
        XCTAssertEqual(
            rows[1].cells, [BucketNoteRowCell(time: 1.5, text: "F·A·C (F)", isDim: true)])
        XCTAssertEqual(rows[2].cells.map(\.time), [1.0])  // bucket 6 at 3.0 s is outside

        XCTAssertEqual(
            BucketNoteRowFormatter.rows(
                timeline: timeline, hiddenStems: [StemID(.bass)], inWindow: 0...4
            ).map(\.label), ["Ld", "Gt"])
    }

    func testChordNamingIsExactAndPrefersTheGivenRoot() {
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [60, 64, 67]), "C")
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [9, 0, 4]), "Am")
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [11, 2, 5]), "Bdim")
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [7, 11, 2, 5]), "G7")
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [0, 4, 7, 11]), "Cmaj7")
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [9, 0, 4, 7]), "Am7")
        // Symmetric and rotated sets fall back to the earliest quality, then the lowest root,
        // unless a preferred root (the bass, or the strongest class) names the set.
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [0, 4, 8]), "Caug")
        XCTAssertEqual(BucketChordNaming.name(pitchClasses: [0, 2, 7]), "Csus2")
        XCTAssertEqual(
            BucketChordNaming.name(pitchClasses: [0, 2, 7], preferredRoots: [7]), "Gsus4")
        // Two classes are an interval; a stray class spells nothing.
        XCTAssertNil(BucketChordNaming.name(pitchClasses: [0, 4]))
        XCTAssertNil(BucketChordNaming.name(pitchClasses: [0, 4, 7, 2]))
    }

    /// Eric, 2026-10-07: every instrument is its own source. Each row is one player's part —
    /// no chord spelled across players — and a note held into the next bucket is one note.
    func testEachPlayerKeepsItsOwnRowAndAHeldNoteIsShownOnce() {
        let key = BucketGridKey(bpm: 120, anchor: 0, duration: 2)
        let clicks: [TimeInterval] = [0, 0.5, 1.0, 1.5, 2.0]
        let timeline = BucketNoteTimeline(
            gridKey: key, clickTimes: clicks,
            stems: [
                StemBucketNotes(
                    stemID: StemID(.bass),
                    notes: [45, 45, 36].enumerated().map {
                        StemBucketNote(
                            bucketIndex: $0.offset, midiNote: $0.element,
                            pitchClasses: [$0.element % 12], confidence: 0.9, coverage: 1)
                    }),
                StemBucketNotes(
                    stemID: StemID(.guitar),
                    notes: [
                        StemBucketNote(
                            bucketIndex: 0, midiNote: nil, pitchClasses: [0, 4],
                            confidence: 0.9, coverage: 1),
                        StemBucketNote(
                            bucketIndex: 1, midiNote: nil, pitchClasses: [0, 4, 7],
                            confidence: 0.9, coverage: 1),
                    ]),
            ])

        let rows = BucketNoteRowFormatter.rows(timeline: timeline, inWindow: 0...2)
        XCTAssertEqual(rows.map(\.label), ["Gt", "Bs"])
        XCTAssertEqual(rows[0].cells.map(\.text), ["C·E", "C·E·G (C)"])
        // The A held through the second bucket is one note; the C is a change.
        XCTAssertEqual(rows[1].cells.map(\.text), ["A", "C"])
        XCTAssertEqual(rows[1].cells.map(\.time), [0, 1.0])

        let guitarOnly = BucketNoteRowFormatter.rows(
            timeline: timeline, hiddenStems: [StemID(.bass)], inWindow: 0...2)
        XCTAssertEqual(guitarOnly.map(\.label), ["Gt"])
    }

    // MARK: - Helpers

    private func tone(frequency: Double, duration: TimeInterval, amplitude: Float = 0.5) -> [Float]
    {
        let count = Int(sampleRate * duration)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func mix(_ parts: [Float]...) -> [Float] {
        let count = parts.map(\.count).min() ?? 0
        return (0..<count).map { index in parts.reduce(0) { $0 + $1[index] } / Float(parts.count) }
    }

    // MARK: - Phantom instruments

    /// A constant-level stereo WAV: only its LEVEL matters to the leakage gate.
    private func writeLevelWAV(_ name: String, level: Float, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            buffer.floatChannelData![channel].update(repeating: level, count: Int(frames))
        }
        try file.write(from: buffer)
        return url
    }

    func testTheOtherStemGetsNoNoteRowWhenThereIsAGuitaristOrPianistToSpeakFor() {
        let url = URL(fileURLWithPath: "/dev/null")
        func ids(_ raw: [String]) -> [String] {
            BucketNotePass.withoutOtherMusicians(raw.map { (StemID(rawValue: $0), url) })
                .map(\.id.rawValue)
        }
        // Six-stem set: `other` is some other musician, omitted by design — children included.
        XCTAssertEqual(
            ids(["vocals", "bass", "guitar.lead", "piano", "other", "other.synth"]),
            ["vocals", "bass", "guitar.lead", "piano"])
        // Legacy four-stem set: `other` is the only instrument stem there is.
        XCTAssertEqual(ids(["vocals", "bass", "other"]), ["vocals", "bass", "other"])
    }

    func testAnInstrumentStemThatIsOnlyResidueGetsNoNoteRow() throws {
        // Seven Bridges Road, 2026-09-20: the piano stem sat 56 dB below the guitar on a recording
        // with no piano; self-normalisation amplified the bleed and reported 40 notes on it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries: [(id: StemID, url: URL)] = [
            (StemID(.guitar), try writeLevelWAV("guitar.wav", level: 0.1, in: directory)),
            (StemID(.piano), try writeLevelWAV("piano.wav", level: 0.000_15, in: directory)),
            (StemID(.other), try writeLevelWAV("other.wav", level: 0.02, in: directory)),
            (StemID(.vocals), try writeLevelWAV("vocals.wav", level: 0.000_15, in: directory)),
            (
                StemID(rawValue: "accompaniment"),
                try writeLevelWAV("accompaniment.wav", level: 0.5, in: directory)
            ),
        ]

        let kept = BucketNotePass.withoutPhantomInstruments(entries).map(\.id.rawValue)

        // Piano (-56 dB) goes. `other` (-14 dB) is a quiet real instrument and stays. The voice
        // is not an instrument stem, and the loud accompaniment SUM must not set the bar.
        XCTAssertEqual(kept, ["guitar", "other", "vocals", "accompaniment"])
    }
}
