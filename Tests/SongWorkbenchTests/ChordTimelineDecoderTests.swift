import XCTest

@testable import SongWorkbench

final class ChordTimelineDecoderTests: XCTestCase {
    private let dbMajor = MusicalKey(root: .cSharp, quality: .major)

    private func obs(_ t: TimeInterval, _ root: PitchClass, _ q: ChordQuality, _ c: Float)
        -> ChordObservation
    {
        ChordObservation(timestamp: t, chord: Chord(root: root, quality: q), confidence: c)
    }

    private func analysis(_ observations: [ChordObservation], beats: [TimeInterval])
        -> SongAudioAnalysis
    {
        SongAudioAnalysis(
            beat: BeatEstimate(bpm: 120, beatTimes: beats, confidence: 1),
            chords: observations,
            estimatedKey: nil
        )
    }

    func testSustainedChordWithFlickerFramesDecodesToSingleEvent() {
        // C# dominates every beat, with one noisy Em frame per window that independent
        // voting could occasionally promote; the switch penalty must hold C#.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<8 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.05, .cSharp, .major, 0.7))
            observations.append(obs(t + 0.20, .cSharp, .major, 0.65))
            observations.append(obs(t + 0.35, .e, .minor, 0.6))
        }
        let beats = (0...8).map { TimeInterval($0) * 0.5 }
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor)
        XCTAssertEqual(events.map(\.chord), ["C#"])
        XCTAssertEqual(events.first?.time, 0)
    }

    func testGenuineChangeWithSustainedEvidenceProducesTwoEvents() {
        var observations: [ChordObservation] = []
        for beatIndex in 0..<4 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.7))
        }
        for beatIndex in 4..<8 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .fSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .fSharp, .major, 0.7))
        }
        let beats = (0...8).map { TimeInterval($0) * 0.5 }
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor)
        XCTAssertEqual(events.map(\.chord), ["C#", "F#"])
        XCTAssertEqual(events[1].time, 2.0, accuracy: 1e-9)
    }

    func testWeakEvidenceWindowsEmitNothingAndPreviousChordSustains() {
        // Strong C# for two beats, silence for four beats, strong C# again:
        // the silent middle must not emit anything (no-chord state), and the
        // resumed C# must NOT create a duplicate event.
        var observations: [ChordObservation] = []
        for beatIndex in [0, 1, 6, 7] {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.8))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.8))
        }
        let beats = (0...8).map { TimeInterval($0) * 0.5 }
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor)
        XCTAssertEqual(events.map(\.chord), ["C#"])
    }

    func testKeyPriorFlipsChromaticWindowWinner() {
        // Em raw evidence (1.29) beats Ab (1.15) in the first window; the prior must flip it.
        // Surrounding windows are solid Ab so the penalty also pulls toward Ab.
        var observations: [ChordObservation] = [
            obs(0.10, .e, .minor, 0.65),
            obs(0.15, .e, .minor, 0.64),
            obs(0.20, .gSharp, .major, 0.60),
            obs(0.40, .gSharp, .major, 0.55),
        ]
        for beatIndex in 1..<4 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .gSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .gSharp, .major, 0.7))
        }
        let beats = (0...4).map { TimeInterval($0) * 0.5 }
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor)
        XCTAssertEqual(events.map(\.chord), ["Ab"])
    }

    func testEventConfidenceIsMeanRawFrameConfidenceNotPriorScaled() {
        let observations = [
            obs(0.1, .cSharp, .major, 0.8),
            obs(0.3, .cSharp, .major, 0.6),
        ]
        let beats: [TimeInterval] = [0, 0.5, 1.0]
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].confidence ?? 0, 0.7, accuracy: 1e-3)
    }

    func testBassRerootRecoversChordMaskedByChromaConfusion() {
        // The Summertime verse scenario: an Ab passage whose root is quiet reads as Cm in
        // every frame (shares C+Eb) — the classifier never emits Ab, so without bass
        // re-rooting the sustained C# rides straight through. Bass = Ab through the passage.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<4 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.75))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.75))
        }
        for beatIndex in 4..<10 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .c, .minor, 0.7))
            observations.append(obs(t + 0.3, .c, .minor, 0.65))
        }
        for beatIndex in 10..<12 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.75))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.75))
        }
        let beats = (0...12).map { TimeInterval($0) * 0.5 }
        let bass = [
            BassNoteObservation(timestamp: 0.05, midiNote: 37, confidence: 0.8),  // C#
            BassNoteObservation(timestamp: 2.05, midiNote: 44, confidence: 0.8),  // Ab
            BassNoteObservation(timestamp: 5.05, midiNote: 37, confidence: 0.8),  // C#
        ]
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor, bassNotes: bass)
        XCTAssertEqual(events.map(\.chord), ["C#", "Ab", "C#"])
    }

    func testBassRerootRecoversUpperStructureSeventh() {
        // C# triad frames sounding over an F# bass: shares only C# with the F# triad but
        // C#+E# with F#maj7 — the actual chord. Surrounding C# sections keep their own bass.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<4 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.75))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.75))
        }
        for beatIndex in 4..<10 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.7))
        }
        let beats = (0...10).map { TimeInterval($0) * 0.5 }
        let bass = [
            BassNoteObservation(timestamp: 0.05, midiNote: 37, confidence: 0.8),  // C#
            BassNoteObservation(timestamp: 2.05, midiNote: 42, confidence: 0.8),  // F#
        ]
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor, bassNotes: bass)
        XCTAssertEqual(events.map(\.chord), ["C#", "F#maj7"])
        XCTAssertEqual(events.last?.time ?? 0, 2.0, accuracy: 0.51)
    }

    func testLowConfidenceBassDoesNotReroot() {
        var observations: [ChordObservation] = []
        for beatIndex in 0..<6 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.75))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.75))
        }
        let beats = (0...6).map { TimeInterval($0) * 0.5 }
        let junkBass = [BassNoteObservation(timestamp: 1.0, midiNote: 42, confidence: 0.1)]
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor, bassNotes: junkBass)
        XCTAssertEqual(events.map(\.chord), ["C#"])
    }

    func testSameRootExtensionMergesIntoTriad() {
        let merged = ChordTimelineDecoder.mergeSameRootExtensions([
            EditableChordEvent(time: 0, chord: "F#", confidence: 0.8),
            EditableChordEvent(time: 2, chord: "F#maj7", confidence: 0.7),
            EditableChordEvent(time: 4, chord: "Ab", confidence: 0.9),
            EditableChordEvent(time: 6, chord: "Ebm7", confidence: 0.6),
            EditableChordEvent(time: 8, chord: "Ebm", confidence: 0.7),
        ])
        XCTAssertEqual(merged.map(\.chord), ["F#", "Ab", "Ebm"])
        XCTAssertEqual(merged.map(\.time), [0, 4, 6])
        // Different roots or genuinely different qualities never merge.
        let kept = ChordTimelineDecoder.mergeSameRootExtensions([
            EditableChordEvent(time: 0, chord: "F#", confidence: 0.8),
            EditableChordEvent(time: 2, chord: "F#m", confidence: 0.7),
        ])
        XCTAssertEqual(kept.map(\.chord), ["F#", "F#m"])
    }

    func testOneBeatPassingChordOnInstrumentOnsetSurvives() {
        // C# everywhere except beat window 4 (t=2.0–2.5), where F# has clear-but-not-
        // overwhelming dominance (ratio ~6.2, ln≈1.83). At full penalty the excursion costs
        // 2×1.5=3.0 nats and is absorbed; with onsets at the change boundaries the cost is
        // 2×0.75=1.5 and the real passing chord survives. Regression for field-reported
        // missed chord changes.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<8 where beatIndex != 4 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.7))
        }
        let t4 = 2.0
        observations.append(obs(t4 + 0.05, .fSharp, .major, 0.7))
        observations.append(obs(t4 + 0.15, .fSharp, .major, 0.7))
        observations.append(obs(t4 + 0.25, .fSharp, .major, 0.7))
        observations.append(obs(t4 + 0.35, .fSharp, .major, 0.7))
        observations.append(obs(t4 + 0.45, .cSharp, .major, 0.45))
        let beats = (0...8).map { TimeInterval($0) * 0.5 }

        let withoutOnsets = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor)
        XCTAssertEqual(
            withoutOnsets.map(\.chord), ["C#"],
            "full-price switches should absorb the excursion (flicker suppression)")

        let withOnsets = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor,
            instrumentOnsets: [2.0, 2.5])
        XCTAssertEqual(withOnsets.map(\.chord), ["C#", "F#", "C#"])
        XCTAssertEqual(withOnsets[1].time, 2.0, accuracy: 1e-9)
    }

    func testOnsetsFarFromWindowStartsDoNotDiscountPenalty() {
        // Same evidence as the flicker test; onsets exist but none within tolerance of the
        // noisy windows' starts, so decoding is unchanged.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<8 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.05, .cSharp, .major, 0.7))
            observations.append(obs(t + 0.20, .cSharp, .major, 0.65))
            observations.append(obs(t + 0.35, .e, .minor, 0.6))
        }
        let beats = (0...8).map { TimeInterval($0) * 0.5 }
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: dbMajor,
            instrumentOnsets: [0.25, 0.75, 1.25, 1.75, 2.25, 2.75, 3.25, 3.75])
        XCTAssertEqual(events.map(\.chord), ["C#"])
    }

    func testMissingBeatGridFallsBackToWindowVoting() {
        let observations = [
            obs(0.5, .cSharp, .major, 0.8),
            obs(1.0, .cSharp, .major, 0.8),
            obs(3.0, .fSharp, .major, 0.8),
            obs(3.5, .fSharp, .major, 0.8),
        ]
        let analysis = SongAudioAnalysis(beat: nil, chords: observations, estimatedKey: nil)
        let events = ChordTimelineDecoder().events(from: analysis, key: dbMajor)
        XCTAssertEqual(events.map(\.chord), ["C#", "F#"])
    }

    func testExplicitBeatTimesOverridesAnalysisEmbeddedGrid() {
        // Regression for the grid-mismatch finding: AnalysisStage decodes on its
        // drum-locked `resolvedBeatTimes`, which can differ from the harmony engine's own
        // `analysis.beat.beatTimes` embedded above. Genuine change C#→F# on the TRUE beats
        // (0, 0.5, ... 4.0); `analysis` embeds a DECOY grid offset by a quarter beat, which
        // would straddle every chord boundary and blur the windows if it were used instead.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<4 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .cSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .cSharp, .major, 0.7))
        }
        for beatIndex in 4..<8 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .fSharp, .major, 0.7))
            observations.append(obs(t + 0.3, .fSharp, .major, 0.7))
        }
        let trueBeats = (0...8).map { TimeInterval($0) * 0.5 }
        let decoyBeats = trueBeats.map { $0 + 0.25 }
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: decoyBeats), key: dbMajor,
            beatTimes: trueBeats)
        XCTAssertEqual(events.map(\.chord), ["C#", "F#"])
        XCTAssertEqual(events[1].time, 2.0, accuracy: 1e-9)
    }
}
