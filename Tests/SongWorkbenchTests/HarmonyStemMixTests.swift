import XCTest

@testable import SongWorkbench

final class HarmonyStemMixTests: XCTestCase {
    /// Constant-amplitude square-ish signal at `level`, so RMS is exactly `level`.
    private func tone(_ level: Float, count: Int = 1_000) -> [Float] {
        (0..<count).map { $0.isMultiple(of: 2) ? level : -level }
    }

    private func contributor(_ label: String, _ weight: Float, _ samples: [Float])
        -> HarmonyStemMix.Contributor
    {
        HarmonyStemMix.Contributor(label: label, weight: weight, samples: samples)
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    // MARK: - Weighting

    func testWeightsExpressPriorityRegardlessOfHowLoudTheStemWas() {
        // A quiet-but-real piano at a 0.6 weight must contribute 0.6x the guitar, not 0.6x its own
        // (tiny) mix level. Both stems are the same waveform at wildly different levels, so the
        // mix is guitar*1.0 + piano*0.6 in the same phase — 1.6x a unit-RMS signal.
        let loudGuitar = tone(0.8)
        let quietPiano = tone(0.05)
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, loudGuitar),
            contributor("piano", 0.6, quietPiano),
        ])
        XCTAssertEqual(mix.included, ["guitar", "piano"])
        XCTAssertTrue(mix.excludedAsLeakage.isEmpty)
        // Peak normalization divides by 1.6, so RMS lands back at 1.0 relative to the peak.
        XCTAssertEqual(rms(mix.samples), 1.0, accuracy: 1e-4)
    }

    func testZeroWeightStemNeverReachesTheMix() {
        // The shipped bass weight. Bass must not enter the chroma by default.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("bass", 0.0, tone(0.9)),
        ])
        XCTAssertEqual(mix.included, ["guitar"])
    }

    func testBassIsShippedAtZeroWeight() {
        let bass = HarmonyStemMix.defaultWeights.first { $0.kind == .bass }
        XCTAssertEqual(
            bass?.weight, 0, "bass in the chroma manufactures inversions as root changes")
        XCTAssertEqual(HarmonyStemMix.defaultWeights.map(\.kind), [.guitar, .piano, .bass])
    }

    // MARK: - Leakage gate

    func testStemFarBelowTheLoudestIsDroppedAsLeakage() {
        // 40 dB down: separation bleed, not a part. Without the gate, unit-RMS normalization
        // would amplify it to full level and double-count the guitar.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, tone(0.005)),
        ])
        XCTAssertEqual(mix.included, ["guitar"])
        XCTAssertEqual(mix.excludedAsLeakage, ["piano"])
    }

    func testStemJustInsideTheFloorIsKept() {
        // 20 dB down is a quiet but genuine part, above the -25 dB floor.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, tone(0.05)),
        ])
        XCTAssertEqual(mix.included, ["guitar", "piano"])
    }

    func testLeakageGateIsRelativeNotAbsolute() {
        // A quiet recording: both stems are low level, but neither is bleed relative to the other.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.01)),
            contributor("piano", 0.6, tone(0.008)),
        ])
        XCTAssertEqual(mix.included, ["guitar", "piano"])
    }

    // MARK: - Degenerate input

    func testSilentAndEmptyContributorsAreIgnored() {
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, []),
            contributor("other", 0.4, [Float](repeating: 0, count: 1_000)),
        ])
        XCTAssertEqual(mix.included, ["guitar"])
    }

    func testNothingUsableYieldsAnEmptyMix() {
        XCTAssertTrue(HarmonyStemMix.mixed([]).samples.isEmpty)
        XCTAssertTrue(
            HarmonyStemMix.mixed([contributor("guitar", 0, tone(0.5))]).samples.isEmpty)
        XCTAssertTrue(
            HarmonyStemMix.mixed([
                contributor("guitar", 1, [Float](repeating: 0, count: 100))
            ]).samples.isEmpty)
    }

    func testMixLengthIsTheShortestIncludedContributor() {
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5, count: 1_000)),
            contributor("piano", 0.6, tone(0.5, count: 600)),
        ])
        XCTAssertEqual(mix.samples.count, 600)
    }

    func testMixStaysInsideUnitRange() {
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, tone(0.4)),
            contributor("other", 0.5, tone(0.3)),
        ])
        XCTAssertLessThanOrEqual(mix.samples.map(abs).max() ?? 0, 1.0)
    }
}

final class InstrumentChordPassTests: XCTestCase {
    func testEveryStemHasItsOwnColorAndPianoIsNoLongerTextColored() {
        XCTAssertEqual(Set(StemKind.allCases.map(\.laneColor)).count, StemKind.allCases.count)
        XCTAssertEqual(StemKind.piano.laneColor, .swTeal)
    }

    func testAChordBelongsToTheOneInstrumentPlayingIt() {
        func track(_ id: StemID, _ chords: [(TimeInterval, String)]) -> InstrumentChordTrack {
            InstrumentChordTrack(
                stemID: id, chords: chords.map { EditableChordEvent(time: $0.0, chord: $0.1) })
        }
        let guitar = track(StemID(.guitar), [(0, "C"), (4, "G")])
        let piano = track(StemID(.piano), [(0, "C"), (4, "Am")])
        let tracks = [guitar, piano]
        XCTAssertEqual(
            InstrumentChordAgreement.instrument(forChord: "G", at: 4.1, tracks: tracks),
            StemID(.guitar))
        XCTAssertEqual(
            InstrumentChordAgreement.instrument(forChord: "Am", at: 3.9, tracks: tracks),
            StemID(.piano), "a change just after the chart chord still counts")
        XCTAssertNil(
            InstrumentChordAgreement.instrument(forChord: "C", at: 1, tracks: tracks),
            "a chord both instruments play belongs to neither")
        XCTAssertNil(InstrumentChordAgreement.instrument(forChord: "F", at: 1, tracks: tracks))
        let refined = [
            track(.guitarLead, [(0, "C")]), track(.guitarRhythm, [(0, "C")]),
            track(StemID(.piano), [(0, "F")]),
        ]
        XCTAssertEqual(
            InstrumentChordAgreement.instrument(forChord: "C", at: 1, tracks: refined),
            .guitarLead, "lead and rhythm guitar are one instrument")
    }

    /// A piano stem playing C then G, and a guitar stem that is only faint bleed: the piano gets
    /// a track with those chords, and the bleed stem gets none.
    func testEachChordalStemGetsItsOwnChordsAndBleedIsSkipped() throws {
        let sampleRate = 22_050.0
        func tone(_ midi: [Int], seconds: Double, amplitude: Float) -> [Float] {
            (0..<Int(seconds * sampleRate)).map { index in
                let t = Double(index) / sampleRate
                return midi.reduce(Float(0)) { sum, note in
                    let frequency = 440 * pow(2, Double(note - 69) / 12)
                    return sum + amplitude * Float(sin(2 * .pi * frequency * t))
                }
            }
        }
        let piano =
            tone([48, 60, 64, 67], seconds: 6, amplitude: 0.15)
            + tone([43, 55, 59, 62], seconds: 6, amplitude: 0.15)
        let bleed = piano.map { $0 * 0.01 }
        var document = SongAnalysisDocument()
        document.estimatedBPM = 120
        document.beatTimes = (0..<24).map { Double($0) * 0.5 }
        document.sourceDuration = 12

        let tracks = InstrumentChordPass.tracks(
            for: [
                (StemID(.guitar), bleed, sampleRate), (StemID(.piano), piano, sampleRate),
            ], document: document)
        XCTAssertEqual(tracks.map(\.stemID), [StemID(.piano)], "the bleed stem is gated out")
        let chords = try XCTUnwrap(tracks.first?.chords)
        XCTAssertEqual(
            InstrumentChordAgreement.sounding(in: tracks[0], at: 3)?.chord.prefix(1), "C",
            "chords: \(chords.map { "\($0.chord)@\($0.time)" })")
        XCTAssertEqual(
            InstrumentChordAgreement.sounding(in: tracks[0], at: 9)?.chord.prefix(1), "G",
            "chords: \(chords.map { "\($0.chord)@\($0.time)" })")
    }

    func testInstrumentChordRowsSitUnderTheirNoteRowsAndNameTheCarriedChord() {
        let timeline = InstrumentChordTimeline(
            gridKey: BucketGridKey(bpm: 120, anchor: 0, duration: 20),
            tracks: [
                InstrumentChordTrack(
                    stemID: StemID(.piano),
                    chords: [
                        EditableChordEvent(time: 1, chord: "C"),
                        EditableChordEvent(time: 5, chord: "G"),
                    ]),
                InstrumentChordTrack(
                    stemID: StemID(.guitar), chords: [EditableChordEvent(time: 2, chord: "Am")]),
            ])
        let rows = InstrumentChordRowFormatter.rows(timeline: timeline, inWindow: 4...8)
        XCTAssertEqual(
            rows.map(\.label), ["GtC", "PnC"], "guitar before piano, like the note rows")
        XCTAssertEqual(rows[0].cells.map(\.text), ["Am"], "still sounding from 2 s")
        XCTAssertEqual(rows[0].cells.map(\.isDim), [true])
        XCTAssertEqual(rows[1].cells.map(\.text), ["C", "G"])
        XCTAssertEqual(rows[1].cells.map(\.isDim), [true, false])

        let transposed = InstrumentChordRowFormatter.rows(
            timeline: timeline, hiddenStems: [StemID(.guitar)], inWindow: 4...8, transposedBy: 2)
        XCTAssertEqual(transposed.map(\.label), ["PnC"])
        XCTAssertEqual(transposed[0].cells.map(\.text), ["D", "A"])

        func noteRow(_ id: StemID) -> BucketNoteRow {
            BucketNoteRow(stemID: id, label: "n", cells: [])
        }
        let merged = InstrumentChordRowFormatter.interleaved(
            noteRows: [noteRow(StemID(.guitar)), noteRow(StemID(.piano)), noteRow(StemID(.bass))],
            chordRows: rows)
        XCTAssertEqual(merged.map(\.label), ["n", "GtC", "n", "PnC", "n"])
    }
}
