import XCTest

@testable import SongWorkbench

final class KeyAwareChordFilteringTests: XCTestCase {

    // MARK: - KeyPriorChordRescorer

    private let dbMajor = MusicalKey(root: .cSharp, quality: .major)

    func testDiatonicChordsKeepFullConfidence() {
        let rescorer = KeyPriorChordRescorer(key: dbMajor)
        // Db major diatonic: I=Db, IV=Gb, V=Ab(+7), ii=Ebm, iii=Fm, vi=Bbm.
        for chord in [
            Chord(root: .cSharp, quality: .major),
            Chord(root: .fSharp, quality: .major),
            Chord(root: .gSharp, quality: .major),
            Chord(root: .gSharp, quality: .dominant7),
            Chord(root: .dSharp, quality: .minor),
            Chord(root: .f, quality: .minor),
            Chord(root: .aSharp, quality: .minor),
        ] {
            XCTAssertEqual(rescorer.weight(for: chord), 1.0, "\(chord)")
        }
    }

    func testChromaticChordsAreStronglyDiscounted() {
        let rescorer = KeyPriorChordRescorer(key: dbMajor)
        // The audit's noise vocabulary on the reference song: D, Dm, Cm, Gm, Em in Db major.
        // (E major is interval 3 = bIII, classed borrowed, tested below.)
        for chord in [
            Chord(root: .d, quality: .major),
            Chord(root: .d, quality: .minor),
            Chord(root: .c, quality: .minor),
            Chord(root: .g, quality: .minor),
            Chord(root: .e, quality: .minor),
        ] {
            XCTAssertEqual(rescorer.weight(for: chord), rescorer.chromaticWeight, "\(chord)")
        }
    }

    func testBorrowedChordsAreMildlyDiscounted() {
        let rescorer = KeyPriorChordRescorer(key: dbMajor)
        // In Db major: iv = F#m (interval 5 minor), bVII = B (10 major), bVI = A (8 major),
        // bIII = E (3 major).
        for chord in [
            Chord(root: .fSharp, quality: .minor),
            Chord(root: .b, quality: .major),
            Chord(root: .a, quality: .major),
            Chord(root: .e, quality: .major),
        ] {
            XCTAssertEqual(rescorer.weight(for: chord), rescorer.borrowedWeight, "\(chord)")
        }
    }

    func testRescoreScalesObservationConfidence() {
        let rescorer = KeyPriorChordRescorer(key: dbMajor)
        let observations = [
            ChordObservation(
                timestamp: 0, chord: Chord(root: .cSharp, quality: .major), confidence: 0.8),
            ChordObservation(
                timestamp: 1, chord: Chord(root: .d, quality: .minor), confidence: 0.6),
        ]
        let rescored = rescorer.rescore(observations)
        XCTAssertEqual(rescored[0].confidence, 0.8, accuracy: 1e-6)
        XCTAssertEqual(rescored[1].confidence, 0.6 * rescorer.chromaticWeight, accuracy: 1e-6)
        XCTAssertEqual(rescored[0].timestamp, 0)
        XCTAssertEqual(rescored[1].chord, observations[1].chord)
    }

    func testMinorKeyDiatonicSet() {
        let bbMinor = MusicalKey(root: .aSharp, quality: .minor)
        let rescorer = KeyPriorChordRescorer(key: bbMinor)
        // Bb natural minor: i=Bbm, iv=Ebm, v=Fm, bIII=Db, bVI=Gb, bVII=Ab.
        for chord in [
            Chord(root: .aSharp, quality: .minor),
            Chord(root: .dSharp, quality: .minor),
            Chord(root: .f, quality: .minor),
            Chord(root: .cSharp, quality: .major),
            Chord(root: .fSharp, quality: .major),
            Chord(root: .gSharp, quality: .major),
        ] {
            XCTAssertEqual(rescorer.weight(for: chord), 1.0, "\(chord)")
        }
        // Harmonic-minor V is borrowed, not chromatic.
        XCTAssertEqual(
            rescorer.weight(for: Chord(root: .f, quality: .major)), rescorer.borrowedWeight)
    }

    func testKeyPriorFlipsNoiseWindowToDiatonicWinner() {
        // One beat window where chromatic Em outscores diatonic Ab on raw confidence
        // (1.29 vs 1.15) but loses once the prior is applied (0.903 vs 1.15).
        let key = dbMajor
        let observations = [
            ChordObservation(
                timestamp: 0.10, chord: Chord(root: .e, quality: .minor), confidence: 0.65),
            ChordObservation(
                timestamp: 0.15, chord: Chord(root: .e, quality: .minor), confidence: 0.64),
            ChordObservation(
                timestamp: 0.20, chord: Chord(root: .gSharp, quality: .major), confidence: 0.60),
            ChordObservation(
                timestamp: 0.40, chord: Chord(root: .gSharp, quality: .major), confidence: 0.55),
        ]
        let beat = BeatEstimate(bpm: 120, beatTimes: [0, 0.5, 1.0], confidence: 1)

        let rawEvents = ChordEventReducer().events(
            from: SongAudioAnalysis(beat: beat, chords: observations, estimatedKey: key))
        XCTAssertEqual(rawEvents.first?.chord, "Em", "raw vote must favour the noise for this test")

        let rescored = KeyPriorChordRescorer(key: key).rescore(observations)
        let events = ChordEventReducer().events(
            from: SongAudioAnalysis(beat: beat, chords: rescored, estimatedKey: key))
        XCTAssertEqual(events.first?.chord, "Ab")
    }

    // MARK: - ChordEventDurationFilter

    private func event(_ time: TimeInterval, _ chord: String, conf: Float = 0.8)
        -> EditableChordEvent
    {
        EditableChordEvent(time: time, chord: chord, confidence: conf)
    }

    private let uniformBeats: [TimeInterval] = (0...16).map { TimeInterval($0) * 0.5 }

    func testMergesSubBeatSliverIntoPreviousChord() {
        // C# at 0, sliver E at 2.0 lasting 0.15s (0.3 beats), F# at 2.15.
        let events = [event(0, "C#"), event(2.0, "E"), event(2.15, "F#")]
        let merged = ChordEventDurationFilter.merge(
            events, beatTimes: uniformBeats, sourceDuration: 8)
        XCTAssertEqual(merged.map(\.chord), ["C#", "F#"])
        XCTAssertEqual(merged.map(\.time), [0, 2.15])
    }

    func testFlickerSandwichCollapsesToSurroundingChord() {
        // A - B(0.2 beats) - A: dropping B must also collapse the duplicate A.
        let events = [event(0, "Ab"), event(2.0, "Cm"), event(2.1, "Ab"), event(4.0, "F#")]
        let merged = ChordEventDurationFilter.merge(
            events, beatTimes: uniformBeats, sourceDuration: 8)
        XCTAssertEqual(merged.map(\.chord), ["Ab", "F#"])
    }

    func testKeepsFullBeatPassingChord() {
        // One-beat (0.5s) passing chord must survive.
        let events = [event(0, "C#"), event(2.0, "Bbm"), event(2.5, "F#")]
        let merged = ChordEventDurationFilter.merge(
            events, beatTimes: uniformBeats, sourceDuration: 8)
        XCTAssertEqual(merged.map(\.chord), ["C#", "Bbm", "F#"])
    }

    func testFinalEventMeasuredAgainstSourceDuration() {
        // Last event lasting 0.1s to end of audio is a sliver.
        let events = [event(0, "C#"), event(7.9, "D")]
        let merged = ChordEventDurationFilter.merge(
            events, beatTimes: uniformBeats, sourceDuration: 8)
        XCTAssertEqual(merged.map(\.chord), ["C#"])
    }

    func testFinalEventWithoutSourceDurationIsKept() {
        let events = [event(0, "C#"), event(7.9, "D")]
        let merged = ChordEventDurationFilter.merge(events, beatTimes: uniformBeats)
        XCTAssertEqual(merged.map(\.chord), ["C#", "D"])
    }

    func testFirstEventIsNeverDropped() {
        // First event spans 0.1s but must survive (defines harmony start); the SECOND sliver
        // is the drop candidate.
        let events = [event(0, "C#", conf: 0.9), event(0.1, "E", conf: 0.5), event(0.25, "F#")]
        let merged = ChordEventDurationFilter.merge(
            events, beatTimes: uniformBeats, sourceDuration: 8)
        XCTAssertEqual(merged.first?.chord, "C#")
        XCTAssertEqual(merged.map(\.chord), ["C#", "F#"])
    }

    func testEmptyBeatGridOnlyCollapsesDuplicates() {
        let events = [event(0, "C#"), event(1, "C#"), event(2, "F#")]
        let merged = ChordEventDurationFilter.merge(events, beatTimes: [], sourceDuration: 8)
        XCTAssertEqual(merged.map(\.chord), ["C#", "F#"])
    }
}
