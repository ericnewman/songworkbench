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
        // Ab*maj7*, not a bare Ab: the frames say C-Eb-G and the bass says Ab, and Ab-C-Eb-G is
        // literally what those four notes spell. The re-rooter cannot know the source was a
        // plain Ab triad whose root was too quiet to classify — it can only pick the chord that
        // best explains the evidence, and the seventh explains all four notes where the triad
        // leaves G unaccounted for. What matters for chord accuracy is that the ROOT is
        // recovered (Cm -> Ab), which is the point this test was written to protect.
        XCTAssertEqual(events.map(\.chord), ["C#", "Abmaj7", "C#"])
    }

    func testBassRerootRejectsTwoToneSeventhCoincidence() {
        // C# triad frames sounding over an F# bass. F#maj7 shares TWO tones with the detected
        // C# triad (C# + E#/F) while the F# triad shares only one, so the old "shares >= 2
        // tones" rule promoted this to F#maj7.
        //
        // That rule was measured and it is wrong: a flat two-tone bar is easier for a 4-note
        // seventh to clear than for a 3-note triad, purely because a seventh has more tones to
        // clear it with. Across four cached songs that asymmetry turned 5-17 genuinely-classified
        // maj7 frames into 248-441 (a 15-88x inflation) and produced 6.8 % maj7 emission against
        // 0 % in the reference charts. The bar is now normalised to the candidate's own size --
        // a triad must match 2 of its 3 tones, a seventh 3 of its 4 -- so a two-tone coincidence
        // no longer overrules the chroma classifier and the frames keep their own label.
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
        XCTAssertEqual(events.map(\.chord), ["C#"])
    }

    func testBassRerootRecoversMinorSeventhMaskedAsRelativeMajor() {
        // The counterpart the old rule could never satisfy. A Cm7 (C-Eb-G-Bb) is note-identical
        // to Eb6, so the chroma classifier hears Eb major; the bass says C. Cm7 shares all THREE
        // detected tones (Eb, G, Bb) where the C minor triad shares only two, so argmax picks
        // the seventh.
        //
        // The old scan could not reach this at all: it was first-match over
        // [.major, .minor, .major7, .dominant7], so `.minor` returned at two tones before any
        // seventh was considered -- and `.minor7` was absent from that list entirely. Measured
        // consequence: m7 was emitted 0.0 % of the time against 2.8 % in the reference charts.
        var observations: [ChordObservation] = []
        for beatIndex in 0..<8 {
            let t = TimeInterval(beatIndex) * 0.5
            observations.append(obs(t + 0.1, .dSharp, .major, 0.75))
            observations.append(obs(t + 0.3, .dSharp, .major, 0.75))
        }
        let beats = (0...8).map { TimeInterval($0) * 0.5 }
        let bass = [BassNoteObservation(timestamp: 0.05, midiNote: 36, confidence: 0.8)]  // C
        let events = ChordTimelineDecoder().events(
            from: analysis(observations, beats: beats), key: nil, bassNotes: bass)
        XCTAssertEqual(events.map(\.chord), ["Cm7"])
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

    // MARK: - Metric (downbeat-aware) switch penalty

    private func dummyWindows(_ count: Int) -> [ChordTimelineDecoder.WindowEvidence] {
        (0..<count).map {
            ChordTimelineDecoder.WindowEvidence(
                start: TimeInterval($0) * 0.5, scores: [:], meanRawConfidence: [:])
        }
    }

    private func assertPenalties(
        _ actual: [Float], _ expected: [Float], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 1e-5, file: file, line: line)
        }
    }

    func testWindowSwitchPenaltiesApplyMetricFactorsByBarPosition() {
        // Meter (4 beats/bar, phase 1): window 1 is the downbeat. Positions by index:
        // 0→3 (weak), 1→0 (downbeat), 2→1 (weak), 3→2 (half-bar), 4→3 (weak), 5→0 (downbeat).
        let penalties = ChordTimelineDecoder.windowSwitchPenalties(
            windows: dummyWindows(6),
            onsets: [],
            basePenalty: 1.5,
            onsetPenaltyFactor: 0.5,
            onsetTolerance: 0.12,
            meter: .init(beatsPerBar: 4, barPhase: 1)
        )
        assertPenalties(penalties, [1.95, 1.05, 1.95, 1.275, 1.95, 1.05])
    }

    func testNilMeterKeepsFlatPenalties() {
        let penalties = ChordTimelineDecoder.windowSwitchPenalties(
            windows: dummyWindows(4),
            onsets: [0.5],
            basePenalty: 1.5,
            onsetPenaltyFactor: 0.5,
            onsetTolerance: 0.12
        )
        assertPenalties(penalties, [1.5, 0.75, 1.5, 1.5])
    }

    func testCombinedMetricAndOnsetDiscountIsFloored() {
        // Downbeat factor 0.4 x onset 0.5 = raw 0.3 < floor 0.35 x 1.5 = 0.525 -> floored.
        let penalties = ChordTimelineDecoder.windowSwitchPenalties(
            windows: dummyWindows(1),
            onsets: [0.0],
            basePenalty: 1.5,
            onsetPenaltyFactor: 0.5,
            onsetTolerance: 0.12,
            meter: .init(beatsPerBar: 4, barPhase: 0),
            downbeatFactor: 0.4
        )
        assertPenalties(penalties, [0.525])
    }

    func testWeakBeatExcursionAbsorbedByMeterButDownbeatExcursionSurvives() {
        // A two-beat F# excursion whose per-window dominance over C# is ~0.9 nats
        // (2x0.7 F# vs one 0.57 C# frame -> ln(1.4/0.57) = 0.899; total ~1.8), with
        // onsets flanking both possible excursion placements. Flat onset-discounted cost
        // is 2 x 0.75 = 1.5 < 1.8, so WITHOUT meter the excursion always survives.
        // WITH meter (phase 0: downbeats at windows 0 and 4):
        //  - starting on WEAK window 5 (exit weak window 7): 0.975 + 0.975 = 1.95 > 1.8
        //    -> absorbed (harmonic rhythm says mid-bar two-beat blips are usually jitter);
        //  - starting on DOWNBEAT window 4 (exit half-bar window 6): 0.525 + 0.6375 =
        //    1.1625 < 1.8 -> survives (changes on the downbeat stay cheap).
        func observations(excursionAt startBeat: Int) -> [ChordObservation] {
            var result: [ChordObservation] = []
            for beatIndex in 0..<8 {
                let t = TimeInterval(beatIndex) * 0.5
                if beatIndex == startBeat || beatIndex == startBeat + 1 {
                    result.append(obs(t + 0.1, .fSharp, .major, 0.7))
                    result.append(obs(t + 0.3, .fSharp, .major, 0.7))
                    result.append(obs(t + 0.4, .cSharp, .major, 0.57))
                } else {
                    result.append(obs(t + 0.1, .cSharp, .major, 0.7))
                    result.append(obs(t + 0.3, .cSharp, .major, 0.7))
                }
            }
            return result
        }
        let beats = (0...8).map { TimeInterval($0) * 0.5 }
        let onsets = [2.0, 2.5, 3.0, 3.5]
        let meter = ChordTimelineDecoder.BarMeter(beatsPerBar: 4, barPhase: 0)

        let weakNoMeter = ChordTimelineDecoder().events(
            from: analysis(observations(excursionAt: 5), beats: beats), key: dbMajor,
            instrumentOnsets: onsets)
        XCTAssertEqual(
            weakNoMeter.map(\.chord), ["C#", "F#", "C#"],
            "without a meter the onset discount lets the weak-beat excursion through")

        let weakWithMeter = ChordTimelineDecoder().events(
            from: analysis(observations(excursionAt: 5), beats: beats), key: dbMajor,
            instrumentOnsets: onsets, meter: meter)
        XCTAssertEqual(
            weakWithMeter.map(\.chord), ["C#"],
            "the weak-beat premium should absorb the mid-bar excursion")

        let downbeatWithMeter = ChordTimelineDecoder().events(
            from: analysis(observations(excursionAt: 4), beats: beats), key: dbMajor,
            instrumentOnsets: onsets, meter: meter)
        XCTAssertEqual(
            downbeatWithMeter.map(\.chord), ["C#", "F#", "C#"],
            "the same excursion starting on the downbeat must survive")
        XCTAssertEqual(downbeatWithMeter[1].time, 2.0, accuracy: 1e-9)
    }
}
