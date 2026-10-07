import XCTest

@testable import SongWorkbench

final class HarmonyStemMixTests: XCTestCase {
    func testBassIsShippedAtZeroWeight() {
        let bass = HarmonyStemMix.defaultWeights.first { $0.kind == .bass }
        XCTAssertEqual(
            bass?.weight, 0, "bass in the chroma manufactures inversions as root changes")
        XCTAssertEqual(HarmonyStemMix.defaultWeights.map(\.kind), [.guitar, .piano, .bass])
    }

    // MARK: - The one player chord detection listens to (levels: guitar, piano)

    func testGuitarLeadsWheneverItHoldsARealPart() {
        // A quieter guitar still leads: chords are the guitarist's (Eric, 2026-09-27).
        XCTAssertEqual(HarmonyStemMix.leadIndex([0.05, 0.5]), 0)
    }

    func testAGuitarStemThatIsOnlyBleedGivesWayToThePiano() {
        // 40 dB below the piano: separation bleed, not a part.
        XCTAssertEqual(HarmonyStemMix.leadIndex([0.005, 0.5]), 1)
    }

    func testLeakageGateIsRelativeNotAbsolute() {
        // A quiet recording: both stems are low level, but neither is bleed relative to the other.
        XCTAssertEqual(HarmonyStemMix.keptAfterLeakageGate([0.01, 0.008]), [0, 1])
        XCTAssertEqual(HarmonyStemMix.keptAfterLeakageGate([0.5, 0.05]), [0, 1])  // -20 dB: kept
    }

    func testNothingAudibleHasNoLead() {
        XCTAssertNil(HarmonyStemMix.leadIndex([]))
        XCTAssertNil(HarmonyStemMix.leadIndex([0, 0]))
    }
}

final class InstrumentChordPassTests: XCTestCase {
    func testEveryStemHasItsOwnColorAndPianoIsNoLongerTextColored() {
        XCTAssertEqual(Set(StemKind.allCases.map(\.laneColor)).count, StemKind.allCases.count)
        XCTAssertEqual(StemKind.piano.laneColor, .swTeal)
    }

    func testAChordNoPlayerHasIsOmittedAndASkewedOneIsKept() {
        func event(_ time: TimeInterval, _ chord: String) -> EditableChordEvent {
            EditableChordEvent(time: time, chord: chord, confidence: 0.8)
        }
        let guitar = InstrumentChordTrack(
            stemID: StemID(.guitar), chords: [event(0, "G"), event(4.4, "C"), event(12, "G")])
        var accepted = event(10, "F#")
        accepted.accepted = true
        let chart = [
            event(0, "G"), event(2, "Em"),  // Em: nobody plays it
            event(3, "G"),  // restates the G still held once Em is gone
            event(4, "C"),  // the guitar's C, placed 0.4 s apart by the two decodes
            event(8, "Am"), accepted, event(12, "G"), event(20, "G"),  // re-struck after a rest
        ]
        let kept = InstrumentChordPass.playedChords(
            chart, tracks: [guitar], rests: [14...19], beatLength: 0.5)
        XCTAssertEqual(kept.map(\.chord), ["G", "C", "F#", "G", "G"])
        XCTAssertEqual(kept.map(\.time), [0, 4, 10, 12, 20])
        XCTAssertEqual(
            InstrumentChordPass.playedChords(chart, tracks: [], rests: [], beatLength: 0.5), chart)
    }

    func testPlayerRestsAreSustainedSilencesNotTheSpaceBetweenStrums() {
        // 0.1 s hops: 3 s playing, a 0.4 s dip between strums, 2 s playing, a 4 s rest, 1 s playing.
        let levels =
            [Float](repeating: 0.2, count: 30) + [Float](repeating: 0.000_1, count: 4)
            + [Float](repeating: 0.2, count: 20) + [Float](repeating: 0.000_1, count: 40)
            + [Float](repeating: 0.2, count: 10)
        let rests = PlayerRests.intervals(levels: levels)
        XCTAssertEqual(rests.count, 1)
        XCTAssertEqual(rests[0].lowerBound, 5.4, accuracy: 0.001)
        XCTAssertEqual(rests[0].upperBound, 9.4, accuracy: 0.001)

        // A chord struck at 4 s is cut off by that rest; one struck after it is not.
        XCTAssertTrue(PlayerRests.interrupts(rests, chordTime: 4, at: 7))
        XCTAssertTrue(PlayerRests.interrupts(rests, chordTime: 4, at: 9.8), "cut off, not resumed")
        XCTAssertFalse(PlayerRests.interrupts(rests, chordTime: 4, at: 5))
        XCTAssertFalse(PlayerRests.interrupts(rests, chordTime: 9.5, at: 10))
        XCTAssertEqual(PlayerRests.end(of: 4, rests: rests), 5.4)
        XCTAssertNil(PlayerRests.end(of: 9.5, rests: rests))
    }

    func testAChordIsCreditedToEveryPlayerWhoseOwnTrackHasIt() {
        func track(_ id: StemID, _ chords: [(TimeInterval, String)]) -> InstrumentChordTrack {
            InstrumentChordTrack(
                stemID: id, chords: chords.map { EditableChordEvent(time: $0.0, chord: $0.1) })
        }
        let tracks = [
            track(StemID(.guitar), [(0, "C"), (4, "G")]),
            track(StemID(.piano), [(0, "C"), (4, "Am")]),
        ]
        XCTAssertEqual(
            InstrumentChordAgreement.agreeingStems(forChord: "C", at: 1, tracks: tracks),
            [StemID(.guitar), StemID(.piano)])
        XCTAssertEqual(
            InstrumentChordAgreement.agreeingStems(forChord: "Am", at: 3.9, tracks: tracks),
            [StemID(.piano)], "a change just after the chart chord still counts")
        XCTAssertTrue(
            InstrumentChordAgreement.agreeingStems(forChord: "F", at: 1, tracks: tracks).isEmpty)
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

    /// Eric, 2026-10-07: only the chord player's stem decides the chord line. A walking bass
    /// under one held guitar chord must not re-root it or license a change.
    func testAWalkingBassDoesNotChangeTheChordLine() throws {
        let rate = 22_050.0
        // Eight seconds of a C major triad (C4 E4 G4).
        let samples = (0..<Int(8 * rate)).map { index -> Float in
            let time = Double(index) / rate
            return Float(
                [261.63, 329.63, 392.0].reduce(0) { $0 + 0.2 * sin(2 * .pi * $1 * time) })
        }
        var document = SongAnalysisDocument()
        document.estimatedBPM = 120
        document.beatTimes = stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }
        document.sourceDuration = 8
        let alone = try InstrumentChordPass.chords(
            samples: samples, sampleRate: rate, document: document)
        // A, F, G, E under the held C: each a plausible re-rooting (Am, F, ...) if the bass voted.
        document.bassNotes = [45, 41, 43, 40, 45, 41, 43, 40].enumerated().map {
            BassNoteObservation(
                timestamp: Double($0.offset), midiNote: $0.element, confidence: 0.95)
        }
        let withBass = try InstrumentChordPass.chords(
            samples: samples, sampleRate: rate, document: document)

        XCTAssertFalse(alone.isEmpty)
        XCTAssertEqual(withBass.map(\.chord), alone.map(\.chord))
        XCTAssertEqual(withBass.map(\.time), alone.map(\.time))
    }
}
