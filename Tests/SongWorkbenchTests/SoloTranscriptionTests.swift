import XCTest

@testable import SongWorkbench

final class SoloTranscriptionTests: XCTestCase {
    private let sampleRate = 44_100.0

    // MARK: - Frame / bucket classification

    func testSparseChromaIsLeadLikeAndSpreadChromaIsNot() {
        var single = [Float](repeating: 0, count: 12)
        single[0] = 0.7
        single[7] = 0.2  // a strong fifth partial is still one note
        single[4] = 0.1
        XCTAssertTrue(SoloTranscriptionAnalyzer.isLeadLike(chroma: single))

        var triad = [Float](repeating: 0, count: 12)
        triad[0] = 0.35
        triad[4] = 0.3
        triad[7] = 0.3
        XCTAssertFalse(SoloTranscriptionAnalyzer.isLeadLike(chroma: triad))
        XCTAssertFalse(
            SoloTranscriptionAnalyzer.isLeadLike(chroma: [Float](repeating: 0, count: 12)))
    }

    func testSyntheticMelodyTriadAndSilenceClassifyPerBucket() {
        // 120 BPM, 0.5 s buckets: 2 s of a moving sine melody, 2 s of a sustained C-major triad,
        // 2 s of silence.
        let melody = [261.63, 293.66, 329.63, 349.23, 392.0, 440.0, 493.88, 523.25]
            .flatMap { tone(frequency: $0, duration: 0.25) }
        let triad = mix(
            tone(frequency: 261.63, duration: 2), tone(frequency: 329.63, duration: 2),
            tone(frequency: 392.0, duration: 2))
        let silence = [Float](repeating: 0, count: Int(sampleRate * 2))
        let samples = melody + triad + silence
        let clicks = MetronomeGrid.periodicGrid(period: 0.5, anchor: 0, duration: 6)
        let verdicts = SoloTranscriptionAnalyzer.classifyBuckets(
            chromaFrames: BucketNoteAnalyzer.chromaFrames(samples: samples, sampleRate: sampleRate),
            pitchFrames: VocalHarmonyAnalyzer(
                maximumNotesPerFrame: 1, midiRange: VocalHarmonyAnalyzer.guitarMidiRange
            ).frameEstimates(samples: samples, sampleRate: sampleRate),
            clickTimes: clicks)

        XCTAssertEqual(verdicts.count, 12)
        XCTAssertEqual(verdicts[0..<4].map(\.kind), Array(repeating: .lead, count: 4))
        XCTAssertEqual(verdicts[4..<8].map(\.kind), Array(repeating: .chordal, count: 4))
        // The last bucket's frames straddle the triad's tail; the rest of the silence is silent.
        XCTAssertEqual(verdicts[9..<12].map(\.kind), Array(repeating: .silent, count: 3))
    }

    // MARK: - Passage grouping

    func testPassagesNeedTwoBarsAndTolerateSingleBucketGaps() {
        let clicks = MetronomeGrid.periodicGrid(period: 0.5, anchor: 0, duration: 12)  // 24 buckets
        func verdict(_ index: Int, _ kind: SoloTranscriptionAnalyzer.BucketClass)
            -> SoloTranscriptionAnalyzer.BucketVerdict
        {
            .init(bucketIndex: index, kind: kind, confidence: kind == .lead ? 0.8 : 0)
        }
        var verdicts = (0..<24).map { verdict($0, .chordal) }
        // Buckets 2…9 lead with a one-bucket chord stab at 5: one 8-bucket (2-bar) passage.
        for index in 2...9 where index != 5 { verdicts[index] = verdict(index, .lead) }
        // Buckets 14…20 lead but a two-bucket gap at 16-17 splits it into runs of 2 and 3: too short.
        for index in [14, 15, 18, 19, 20] { verdicts[index] = verdict(index, .lead) }

        let passages = SoloTranscriptionAnalyzer.passages(
            verdicts: verdicts, clickTimes: clicks, beatsPerBar: 4, stemID: StemID(.guitar))
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].startBucket, 2)
        XCTAssertEqual(passages[0].endBucket, 9)
        XCTAssertEqual(passages[0].startTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(passages[0].endTime, 5.0, accuracy: 1e-9)
        XCTAssertEqual(passages[0].confidence, 0.8, accuracy: 1e-6)
    }

    func testSevenLeadBucketsInFourFourIsNotAPassage() {
        let clicks = MetronomeGrid.periodicGrid(period: 0.5, anchor: 0, duration: 5)
        let verdicts = (0..<10).map {
            SoloTranscriptionAnalyzer.BucketVerdict(
                bucketIndex: $0, kind: $0 < 7 ? .lead : .silent, confidence: 1)
        }
        XCTAssertTrue(
            SoloTranscriptionAnalyzer.passages(
                verdicts: verdicts, clickTimes: clicks, beatsPerBar: 4, stemID: StemID(.guitar)
            ).isEmpty)
        // In 3/4 the same seven buckets clear the two-bar bar.
        XCTAssertEqual(
            SoloTranscriptionAnalyzer.passages(
                verdicts: verdicts, clickTimes: clicks, beatsPerBar: 3, stemID: StemID(.guitar)
            ).count, 1)
    }

    // MARK: - 16th transcription

    func testSixteenthTranscriptionMergesHeldNotesAndKeepsRests() {
        // One bucket [0, 1): 16ths of 0.25 s. E4 for the first two 16ths, rest, then G4.
        let clicks: [TimeInterval] = [0, 1, 2]
        let passage = SoloPassage(
            stemID: StemID(.guitar), startBucket: 0, endBucket: 1, startTime: 0, endTime: 2,
            confidence: 1)
        var frames: [PitchFrameEstimate] = []
        for time in stride(from: 0.02, to: 0.5, by: 0.05) {
            frames.append(.init(time: time, midiNote: 64, confidence: 0.9))
        }
        for time in stride(from: 0.52, to: 0.75, by: 0.05) {
            frames.append(.init(time: time, midiNote: nil, confidence: 0))
        }
        for time in stride(from: 0.77, to: 1.0, by: 0.05) {
            frames.append(.init(time: time, midiNote: 67, confidence: 0.8))
        }
        // Second bucket: no frames at all → the G4 holds through it.
        let notes = SoloTranscriptionAnalyzer.transcribe(
            passage: passage, pitchFrames: frames, clickTimes: clicks)

        XCTAssertEqual(notes.map(\.startSixteenth), [0, 3])
        XCTAssertEqual(notes.map(\.lengthSixteenths), [2, 5])
        XCTAssertEqual(notes.map(\.midiNote), [64, 67])
        for note in notes {
            XCTAssertEqual(
                GuitarTabAssigner.standardTuning[note.string] + note.fret, note.midiNote)
        }
    }

    func testSyntheticMelodyIsTranscribedOnSixteenths() {
        // 120 BPM: eight 8th notes (two 16ths each) over 2 s.
        let midis = [60, 62, 64, 65, 67, 69, 71, 72]
        let samples = midis.flatMap {
            tone(frequency: 440 * pow(2, Double($0 - 69) / 12), duration: 0.25)
        }
        let clicks = MetronomeGrid.periodicGrid(period: 0.5, anchor: 0, duration: 2)
        let passage = SoloPassage(
            stemID: StemID(.guitar), startBucket: 0, endBucket: 3, startTime: 0, endTime: 2,
            confidence: 1)
        let pitch = VocalHarmonyAnalyzer(
            maximumNotesPerFrame: 1, midiRange: VocalHarmonyAnalyzer.guitarMidiRange
        ).frameEstimates(samples: samples, sampleRate: sampleRate)
        let notes = SoloTranscriptionAnalyzer.transcribe(
            passage: passage, pitchFrames: pitch, clickTimes: clicks)

        XCTAssertEqual(notes.map(\.midiNote), midis)
        // Frames straddling a note change may land the boundary a 16th early or late; every
        // note is one or two 16ths long and they tile the passage.
        XCTAssertEqual(notes.map(\.lengthSixteenths).reduce(0, +), 16)
        for note in notes { XCTAssertTrue((1...3).contains(note.lengthSixteenths)) }
    }

    // MARK: - Tab assignment

    func testScaleFromC3LandsInOnePosition() {
        let positions = GuitarTabAssigner.assign(midiNotes: [48, 50, 52, 53, 55, 57, 59, 60])
        let frets = positions.map(\.fret).filter { $0 > 0 }
        XCTAssertLessThanOrEqual(frets.max()! - frets.min()!, GuitarTabAssigner.positionSpan)
        for (midi, position) in zip([48, 50, 52, 53, 55, 57, 59, 60], positions) {
            XCTAssertEqual(GuitarTabAssigner.standardTuning[position.string] + position.fret, midi)
        }
    }

    func testOutOfRangeNotesAreClampedNotDropped() {
        let positions = GuitarTabAssigner.assign(midiNotes: [30, 64, 100])
        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(positions[0].string, 0)
        XCTAssertEqual(positions[0].fret, 0)
        XCTAssertEqual(positions[2].string, 5)
        XCTAssertEqual(positions[2].fret, GuitarTabAssigner.maximumFret)
        XCTAssertTrue(GuitarTabAssigner.assign(midiNotes: []).isEmpty)
    }

    func testTimelineStalenessFollowsGridKeyAndVersion() {
        let key = BucketGridKey(bpm: 120, anchor: 0.5, duration: 60)
        var timeline = SoloTranscriptionTimeline(
            gridKey: key, clickTimes: [0.5, 1], transcriptions: [])
        XCTAssertTrue(timeline.isCurrent(for: key))
        XCTAssertFalse(timeline.isCurrent(for: BucketGridKey(bpm: 121, anchor: 0.5, duration: 60)))
        XCTAssertFalse(timeline.isCurrent(for: nil))
        timeline.versionTag = "solos-0"
        XCTAssertFalse(timeline.isCurrent(for: key))
    }

    func testSixteenthTimesFollowEachBucketsOwnSpan() {
        let timeline = SoloTranscriptionTimeline(
            gridKey: BucketGridKey(bpm: 120, anchor: 0, duration: 3), clickTimes: [0, 1, 3],
            transcriptions: [])
        let passage = SoloPassage(
            stemID: StemID(.guitar), startBucket: 0, endBucket: 1, startTime: 0, endTime: 3,
            confidence: 1)
        XCTAssertEqual(timeline.time(ofSixteenth: 1, in: passage), 0.25)
        XCTAssertEqual(timeline.time(ofSixteenth: 5, in: passage), 1.5)
        XCTAssertNil(timeline.time(ofSixteenth: 8, in: passage))
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
}
