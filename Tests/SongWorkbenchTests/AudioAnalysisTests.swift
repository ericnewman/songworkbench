import XCTest

@testable import SongWorkbench

final class AudioAnalysisTests: XCTestCase {
    func testFramerAppliesHannWindowAndTimestampsEachHop() throws {
        let framer = try MonoSampleFramer(frameLength: 4, hopLength: 2, sampleRate: 8)

        let frames = framer.frames(from: Array(repeating: 1, count: 8))

        XCTAssertEqual(frames.map(\.timestamp), [0, 0.25, 0.5])
        XCTAssertEqual(frames[0].samples[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(frames[0].samples[1], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(frames[0].samples[2], 1, accuracy: 0.000_001)
        XCTAssertEqual(frames[0].samples[3], 0.5, accuracy: 0.000_001)
    }

    func testMagnitudeSpectrumFindsBinCenteredTone() throws {
        let sampleRate = 4_096.0
        let frameLength = 4_096
        let samples = sineWave(frequency: 440, sampleRate: sampleRate, count: frameLength)
        let frame = AudioFrame(timestamp: 1.25, samples: samples)

        let spectrum = try MagnitudeSpectrumAnalyzer().analyze(
            frame,
            sampleRate: sampleRate
        )

        let peakBin = spectrum.magnitudes.indices.max {
            spectrum.magnitudes[$0] < spectrum.magnitudes[$1]
        }
        XCTAssertEqual(peakBin, 440)
        XCTAssertEqual(spectrum.timestamp, 1.25)
        XCTAssertEqual(spectrum.binWidth, 1, accuracy: 0.000_001)
    }

    func testChromaConcentratesEnergyInMajorTriadPitchClasses() throws {
        let sampleRate = 8_192.0
        let frameLength = 8_192
        let samples = mixedSineWave(
            frequencies: [261, 330, 392],
            sampleRate: sampleRate,
            count: frameLength
        )
        let spectrum = try MagnitudeSpectrumAnalyzer().analyze(
            AudioFrame(timestamp: 0.5, samples: samples),
            sampleRate: sampleRate
        )

        let chroma = ChromaAnalyzer().analyze(spectrum)

        XCTAssertEqual(chroma.timestamp, 0.5)
        XCTAssertGreaterThan(chroma.values[PitchClass.c.rawValue], 0.2)
        XCTAssertGreaterThan(chroma.values[PitchClass.e.rawValue], 0.2)
        XCTAssertGreaterThan(chroma.values[PitchClass.g.rawValue], 0.2)
        XCTAssertGreaterThan(
            chroma.values[PitchClass.c.rawValue]
                + chroma.values[PitchClass.e.rawValue]
                + chroma.values[PitchClass.g.rawValue],
            0.8
        )
    }

    func testClassifierProducesTimestampedMajorAndMinorObservations() {
        let classifier = ChordClassifier()
        let cMajor = ChromaVector(timestamp: 2.0, values: triad(root: .c, third: 4))
        let aMinor = ChromaVector(timestamp: 3.5, values: triad(root: .a, third: 3))

        let majorObservation = classifier.classify(cMajor)
        let minorObservation = classifier.classify(aMinor)

        XCTAssertEqual(majorObservation.timestamp, 2.0)
        XCTAssertEqual(majorObservation.chord, Chord(root: .c, quality: .major))
        XCTAssertGreaterThan(majorObservation.confidence, 0.9)
        XCTAssertEqual(minorObservation.timestamp, 3.5)
        XCTAssertEqual(minorObservation.chord, Chord(root: .a, quality: .minor))
        XCTAssertGreaterThan(minorObservation.confidence, 0.9)
    }

    func testClassifierRecognizesSeventhChordTemplates() {
        let classifier = ChordClassifier()
        let cMaj7 = ChromaVector(timestamp: 0, values: seventh(root: .c, quality: .major7))
        let aMin7 = ChromaVector(timestamp: 1, values: seventh(root: .a, quality: .minor7))
        let gDom7 = ChromaVector(timestamp: 2, values: seventh(root: .g, quality: .dominant7))

        XCTAssertEqual(classifier.classify(cMaj7).chord, Chord(root: .c, quality: .major7))
        XCTAssertEqual(classifier.classify(aMin7).chord, Chord(root: .a, quality: .minor7))
        XCTAssertEqual(classifier.classify(gDom7).chord, Chord(root: .g, quality: .dominant7))
        XCTAssertEqual(Chord(root: .c, quality: .major7).displayName, "Cmaj7")
        XCTAssertEqual(Chord(root: .a, quality: .minor7).displayName, "Am7")
        XCTAssertEqual(Chord(root: .g, quality: .dominant7).displayName, "G7")
    }

    func testRootWeightingDisambiguatesAbMajorFromCMinor() {
        // Ab major (Ab-C-Eb) and C minor (C-Eb-G) share C and Eb. With the Ab bass
        // present plus some G bleed, equal-weight templates pick C minor; weighting the
        // root recovers Ab major.
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        values[PitchClass.gSharp.rawValue] = 0.95  // Ab
        values[PitchClass.c.rawValue] = 0.7
        values[PitchClass.dSharp.rawValue] = 0.95  // Eb
        values[PitchClass.g.rawValue] = 1.0
        let chroma = ChromaVector(timestamp: 0, values: values)

        XCTAssertEqual(
            ChordClassifier(rootWeight: 1).classify(chroma).chord,
            Chord(root: .c, quality: .minor)
        )
        XCTAssertEqual(
            ChordClassifier(rootWeight: 1.6).classify(chroma).chord,
            Chord(root: .gSharp, quality: .major)
        )
    }

    func testBassInformedRefinerRerootsSharedNoteConfusion() {
        // Cm (C-Eb-G) detected, but the bass plays Ab → Ab major (Ab-C-Eb), which shares
        // C+Eb with Cm. The bass is the unambiguous root, so it wins.
        let abMidi = 56  // Ab3
        let events = [EditableChordEvent(time: 3.0, chord: "Cm", confidence: 0.8)]
        let bass = [BassNoteObservation(timestamp: 2.9, midiNote: abMidi, confidence: 0.9)]

        let refined = BassInformedChordRefiner().refine(events, bassNotes: bass)
        XCTAssertEqual(refined.map(\.chord), ["Ab"])
    }

    func testBassInformedRefinerKeepsChordWhenBassMatchesRootOrIsChordTone() {
        let refiner = BassInformedChordRefiner()
        // Bass = root: unchanged.
        let cWithCBass = refiner.refine(
            [EditableChordEvent(time: 0, chord: "C", confidence: 0.8)],
            bassNotes: [BassNoteObservation(timestamp: 0, midiNote: 48, confidence: 0.9)]  // C
        )
        XCTAssertEqual(cWithCBass.map(\.chord), ["C"])
        // Bass = the third (E under C major) is an inversion, not a re-root: keep C.
        let cWithEBass = refiner.refine(
            [EditableChordEvent(time: 0, chord: "C", confidence: 0.8)],
            bassNotes: [BassNoteObservation(timestamp: 0, midiNote: 52, confidence: 0.9)]  // E
        )
        XCTAssertEqual(cWithEBass.map(\.chord), ["C"])
    }

    func testBassInformedRefinerLeavesChordUnchangedWhenNoBassIsNear() {
        // A quiet intro: bass notes only appear much later. The early chord must keep its
        // chroma classification rather than be re-rooted from a distant, unrelated bass note.
        let events = [EditableChordEvent(time: 1.0, chord: "Eb", confidence: 0.8)]
        let bass = [BassNoteObservation(timestamp: 13.0, midiNote: 48, confidence: 0.9)]  // C
        let refined = BassInformedChordRefiner().refine(events, bassNotes: bass)
        XCTAssertEqual(refined.map(\.chord), ["Eb"])
    }

    func testPipelineClassifiesSyntheticAMinorChord() throws {
        let sampleRate = 8_192.0
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: sampleRate,
            frameLength: 8_192,
            hopLength: 4_096
        )
        let samples = mixedSineWave(
            frequencies: [220, 262, 330],
            sampleRate: sampleRate,
            count: 8_192
        )

        let observations = try ChordAnalysisPipeline(configuration: configuration)
            .analyze(samples: samples)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].timestamp, 0)
        XCTAssertEqual(observations[0].chord, Chord(root: .a, quality: .minor))
    }

    func testPipelineHonorsTaskCancellationBetweenFrames() async throws {
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: 44_100,
            frameLength: 4_096,
            hopLength: 1_024
        )
        let task = Task {
            try ChordAnalysisPipeline(configuration: configuration).analyze(
                samples: [Float](repeating: 0.1, count: 441_000)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(task.isCancelled)
        }
    }

    private func sineWave(frequency: Double, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func scaledSineWave(
        frequency: Double, sampleRate: Double, count: Int, amplitude: Float
    ) -> [Float] {
        sineWave(frequency: frequency, sampleRate: sampleRate, count: count).map { $0 * amplitude }
    }

    private func mixedSineWave(
        frequencies: [Double],
        sampleRate: Double,
        count: Int
    ) -> [Float] {
        let scale = 1 / Float(frequencies.count)
        return (0..<count).map { index in
            frequencies.reduce(Float.zero) { sample, frequency in
                sample + scale * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
            }
        }
    }

    private func triad(root: PitchClass, third: Int) -> [Float] {
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        values[root.rawValue] = 1
        values[(root.rawValue + third) % values.count] = 1
        values[(root.rawValue + 7) % values.count] = 1
        return values
    }

    private func seventh(root: PitchClass, quality: ChordQuality) -> [Float] {
        var values = triad(root: root, third: quality == .minor || quality == .minor7 ? 3 : 4)
        switch quality {
        case .major7:
            values[(root.rawValue + 11) % values.count] = 1.2
        case .minor7, .dominant7:
            values[(root.rawValue + 10) % values.count] = 1.2
        default: break
        }
        return values
    }

    func testVocalOnsetDetectorFindsOnsetAfterSilentIntro() {
        let sampleRate = 8_000.0
        let silence = [Float](repeating: 0, count: Int(sampleRate * 2))  // 2s instrumental intro
        let vocal = sineWave(frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 2))

        let onset = VocalOnsetDetector.firstOnset(samples: silence + vocal, sampleRate: sampleRate)

        XCTAssertNotNil(onset)
        if let onset { XCTAssertEqual(onset, 2.0, accuracy: 0.1) }
    }

    func testVocalOnsetDetectorReturnsNilWhenAudioStartsImmediately() {
        let sampleRate = 8_000.0
        let vocal = sineWave(frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 3))

        // No silent intro to gate → leave the transcription untouched.
        XCTAssertNil(VocalOnsetDetector.firstOnset(samples: vocal, sampleRate: sampleRate))
    }

    func testVocalOnsetDetectorReturnsNilForDegenerateInput() {
        XCTAssertNil(VocalOnsetDetector.firstOnset(samples: [], sampleRate: 8_000))
        XCTAssertNil(VocalOnsetDetector.firstOnset(samples: [0.1, 0.2, 0.3], sampleRate: 0))
    }

    func testReanchorCompressesIntroLineToVocalOnsetWithoutLosingLines() {
        let introLine = TimedLyricSegment(
            start: 0, end: 17.34, text: "Late night day shes",
            words: [
                TimedLyricWord(text: "Late", start: 0, end: 4, characterRange: 0..<4),
                TimedLyricWord(text: "shes", start: 16, end: 17.34, characterRange: 15..<19),
            ])
        let secondLine = TimedLyricSegment(start: 22.8, end: 27.0, text: "When I dishes insane")

        let result = VocalOnsetReanchor.reanchor([introLine, secondLine], onset: 16)

        XCTAssertEqual(result.count, 2)  // never drops a line
        XCTAssertEqual(result[0].start, 16, accuracy: 0.001)  // compressed to the onset
        XCTAssertEqual(result[0].end, 17.34, accuracy: 0.001)  // reliable end kept
        XCTAssertEqual(result[0].words.first?.start ?? -1, 16, accuracy: 0.001)
        XCTAssertEqual(result[0].words.last?.end ?? -1, 17.34, accuracy: 0.001)
        XCTAssertLessThanOrEqual(result[0].end, result[1].start)
        XCTAssertEqual(result[1], secondLine)  // line already after the onset is untouched
    }

    func testReanchorTranslatesLineEntirelyBeforeOnset() {
        let early = TimedLyricSegment(
            start: 2, end: 4, text: "ghost words",
            words: [
                TimedLyricWord(text: "ghost", start: 2, end: 3, characterRange: 0..<5),
                TimedLyricWord(text: "words", start: 3, end: 4, characterRange: 6..<11),
            ])
        let real = TimedLyricSegment(start: 30, end: 33, text: "real line")

        let result = VocalOnsetReanchor.reanchor([early, real], onset: 16)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].start, 16, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 18, accuracy: 0.001)  // 2s span preserved by translation
        XCTAssertEqual(result[1], real)
    }

    func testReanchorLeavesCorrectlyTimedLinesUntouched() {
        let a = TimedLyricSegment(start: 20, end: 24, text: "a")
        let b = TimedLyricSegment(start: 25, end: 28, text: "b")
        // First line already at/after the onset → no-op.
        XCTAssertEqual(VocalOnsetReanchor.reanchor([a, b], onset: 16), [a, b])

        // First line starts only slightly before the onset (within the lead tolerance) → no-op.
        let near = TimedLyricSegment(start: 15.5, end: 18, text: "near")
        let later = TimedLyricSegment(start: 22, end: 25, text: "later")
        XCTAssertEqual(VocalOnsetReanchor.reanchor([near, later], onset: 16), [near, later])
    }

    func testTranscriptionOnsetCorrectionReanchorsBeforeGrouping() {
        let segment = TimedTranscriptionSegment(
            text: "Late night shes",
            startTime: 0,
            endTime: 17.34,
            tokens: [
                TimedTranscriptionToken(text: "Late", startTime: 0, endTime: 4, confidence: 0.8),
                TimedTranscriptionToken(
                    text: "shes", startTime: 16, endTime: 17.34, confidence: 0.8),
            ],
            confidence: 0.8
        )
        let prepared = TranscriptionOnsetCorrection.preparedSegments([segment], onset: 16)

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[0].tokens.first?.startTime ?? -1, 16, accuracy: 0.001)
        XCTAssertEqual(prepared[0].tokens.map(\.text), ["Late", "shes"])
    }

    func testVocalActivityEnvelopeFindsTwoSungRegionsSeparatedByASilentGap() {
        let sampleRate = 8_000.0
        let silence = [Float](repeating: 0, count: Int(sampleRate))  // 1s
        let tone = sineWave(frequency: 220, sampleRate: sampleRate, count: Int(sampleRate))  // 1s
        let samples = silence + tone + silence + tone  // sing, pause, sing

        let intervals = VocalActivityEnvelope.voicedIntervals(
            samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(intervals.count, 2)
        if intervals.count == 2 {
            XCTAssertEqual(intervals[0].lowerBound, 1.0, accuracy: 0.12)
            XCTAssertEqual(intervals[0].upperBound, 2.0, accuracy: 0.12)
            XCTAssertEqual(intervals[1].lowerBound, 3.0, accuracy: 0.12)
            XCTAssertEqual(intervals[1].upperBound, 4.0, accuracy: 0.12)
        }
    }

    func testVocalActivityEnvelopeReturnsEmptyForDegenerateInput() {
        XCTAssertTrue(
            VocalActivityEnvelope.voicedIntervals(samples: [], sampleRate: 8_000).isEmpty)
        XCTAssertTrue(
            VocalActivityEnvelope.voicedIntervals(samples: [0.1, 0.2], sampleRate: 0).isEmpty)
    }

    func testVocalAlignmentShiftsLinesForwardToTheVoicedOnset() {
        let line1 = TimedLyricSegment(
            start: 1, end: 3, text: "a",
            words: [TimedLyricWord(text: "a", start: 1, end: 1.5, characterRange: 0..<1)])
        let line2 = TimedLyricSegment(start: 10, end: 12, text: "b")
        let voiced: [ClosedRange<TimeInterval>] = [2.0...3.0, 10.5...11.5]

        let result = VocalAlignmentCorrector.align([line1, line2], voicedIntervals: voiced)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].start, 2.0, accuracy: 0.001)  // pushed onto the singing
        XCTAssertEqual(result[0].words.first?.start ?? -1, 2.0, accuracy: 0.001)  // words move too
        XCTAssertEqual(result[1].start, 10.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(result[0].end, result[1].start)  // order preserved
    }

    func testVocalAlignmentClampsIntroLineToFirstOnsetEvenWhenFar() {
        let intro = TimedLyricSegment(start: 0, end: 2, text: "first")
        let voiced: [ClosedRange<TimeInterval>] = [16.0...18.0]  // long instrumental intro

        let result = VocalAlignmentCorrector.align([intro], voicedIntervals: voiced)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 16.0, accuracy: 0.001)
    }

    func testVocalAlignmentLeavesWellAlignedLinesUntouched() {
        let line = TimedLyricSegment(start: 5, end: 7, text: "ok")
        let voiced: [ClosedRange<TimeInterval>] = [5.0...6.5]

        let result = VocalAlignmentCorrector.align([line], voicedIntervals: voiced)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 5.0, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 7.0, accuracy: 0.001)
    }

    func testDistributeAcrossSignalSpreadsWordsOverOneRegion() {
        let line = TimedLyricSegment(
            start: 0, end: 99, text: "ab cd",
            words: [
                TimedLyricWord(text: "ab", start: 0, end: 1, characterRange: 0..<2),
                TimedLyricWord(text: "cd", start: 1, end: 2, characterRange: 3..<5),
            ])
        let voiced: [ClosedRange<TimeInterval>] = [10.0...12.0]

        let result = VocalAlignmentCorrector.distributeAcrossSignal(
            [line], voicedIntervals: voiced)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].words.count, 2)
        XCTAssertEqual(result[0].words[0].start, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].words[1].start, 11.0, accuracy: 0.001)  // equal weights → halfway
        XCTAssertEqual(result[0].start, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 12.0, accuracy: 0.001)
    }

    func testDistributeAcrossSignalSkipsSilentGapsAndStartsWordsOnSignal() {
        let line = TimedLyricSegment(
            start: 0, end: 99, text: "ab cd",
            words: [
                TimedLyricWord(text: "ab", start: 0, end: 1, characterRange: 0..<2),
                TimedLyricWord(text: "cd", start: 1, end: 2, characterRange: 3..<5),
            ])
        let voiced: [ClosedRange<TimeInterval>] = [10.0...11.0, 20.0...21.0]

        let result = VocalAlignmentCorrector.distributeAcrossSignal(
            [line], voicedIntervals: voiced)

        XCTAssertEqual(result[0].words[0].start, 10.0, accuracy: 0.001)
        // Second word lands in the next region (snapped past the 11–20 silent gap), not in it.
        XCTAssertEqual(result[0].words[1].start, 20.0, accuracy: 0.001)
    }

    func testDistributeAcrossSignalClampsWordEndToItsRegionNotIntoTheGap() {
        // One word, two regions: the word must stay within its own region (10...11) and NOT stretch
        // across the silent gap to 21 (that gap belongs to the next line).
        let line = TimedLyricSegment(
            start: 0, end: 99, text: "abcd",
            words: [TimedLyricWord(text: "abcd", start: 0, end: 1, characterRange: 0..<4)])
        let voiced: [ClosedRange<TimeInterval>] = [10.0...11.0, 20.0...21.0]

        let result = VocalAlignmentCorrector.distributeAcrossSignal(
            [line], voicedIntervals: voiced)

        XCTAssertEqual(result[0].words[0].start, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].words[0].end, 11.0, accuracy: 0.001)  // clamped to region end
        XCTAssertEqual(result[0].end, 11.0, accuracy: 0.001)
    }

    func testDistributeAcrossSignalIsPerLineAndDoesNotCramDistantLinesEarly() {
        // line1 sings at ~10-12; line2 sings at ~30-32 but its singing was NOT detected (only the
        // first region exists). Global distribution would cram line2 into [10,12] (drift); per-line
        // distribution leaves line2 on its ASR timing because there's no signal near it.
        let line1 = TimedLyricSegment(
            start: 10, end: 12, text: "a b",
            words: [
                TimedLyricWord(text: "a", start: 10, end: 11, characterRange: 0..<1),
                TimedLyricWord(text: "b", start: 11, end: 12, characterRange: 2..<3),
            ])
        let line2 = TimedLyricSegment(
            start: 30, end: 32, text: "c d",
            words: [
                TimedLyricWord(text: "c", start: 30, end: 31, characterRange: 0..<1),
                TimedLyricWord(text: "d", start: 31, end: 32, characterRange: 2..<3),
            ])
        let voiced: [ClosedRange<TimeInterval>] = [10.0...12.0]  // line2's singing undetected

        let result = VocalAlignmentCorrector.distributeAcrossSignal(
            [line1, line2], voicedIntervals: voiced)

        XCTAssertEqual(result[0].words[0].start, 10.0, accuracy: 0.05)  // line1 placed on signal
        XCTAssertEqual(result[1].start, 30.0, accuracy: 0.001)  // line2 NOT crammed early
        XCTAssertEqual(result[1], line2)  // unchanged (kept ASR timing)
    }

    func testRepeatedPhraseCollapserCollapsesALoopedLine() {
        let unit = ["tried", "to", "fake", "it"]
        var words: [TimedLyricWord] = []
        var time = 0.0
        for _ in 0..<2 {
            for text in unit {
                words.append(
                    TimedLyricWord(
                        text: text, start: time, end: time + 0.4, characterRange: 0..<text.count))
                time += 0.4
            }
        }
        let segment = TimedLyricSegment(start: 0, end: time, text: "looped", words: words)

        let result = RepeatedPhraseCollapser.collapse([segment])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].words.map(\.text), unit)  // one copy kept
        XCTAssertEqual(result[0].text, "tried to fake it")
    }

    func testRepeatedPhraseCollapserLeavesSingleWordStutterAndNormalLines() {
        // "na na na na" — single-word stutter (one distinct word) must be left alone.
        let stutter = TimedLyricSegment(
            start: 0, end: 4, text: "na na na na",
            words: (0..<4).map {
                TimedLyricWord(
                    text: "na", start: Double($0), end: Double($0) + 0.5, characterRange: 0..<2)
            })
        XCTAssertEqual(RepeatedPhraseCollapser.collapse([stutter])[0].words.count, 4)

        // A normal non-repeating line is untouched.
        let normalWords = ["every", "little", "echo", "in", "this", "room"]
        let normal = TimedLyricSegment(
            start: 0, end: 6, text: normalWords.joined(separator: " "),
            words: normalWords.enumerated().map {
                TimedLyricWord(
                    text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5,
                    characterRange: 0..<$0.element.count)
            })
        XCTAssertEqual(RepeatedPhraseCollapser.collapse([normal])[0].words.count, 6)
    }

    /// Builds a segment from a single-spaced sentence, assigning sequential character ranges and
    /// 0.5s-per-word timings starting at `start`.
    private func sentenceSegment(_ text: String, start: TimeInterval = 0) -> TimedLyricSegment {
        var words: [TimedLyricWord] = []
        var cursor = 0
        var time = start
        for token in text.split(separator: " ", omittingEmptySubsequences: true) {
            let lower = cursor
            cursor += token.count
            words.append(
                TimedLyricWord(
                    text: String(token), start: time, end: time + 0.5,
                    characterRange: lower..<cursor)
            )
            cursor += 1  // the separating space
            time += 0.5
        }
        return TimedLyricSegment(start: start, end: time, text: text, words: words)
    }

    func testPhraseRepairFixesGarbledWordInsideRecurringPhrase() {
        // "flip flops and barbecue" recurs; one line garbles it to "barki" inside a longer,
        // otherwise-unique line that the whole-line cluster vote can't reach.
        let segments = [
            sentenceSegment("grab a chair flip flops and barbecue warm sun"),
            sentenceSegment("let the summer flip flops and barbecue cold bruise"),
            sentenceSegment("here we are flip flops and barbecue once again"),
            sentenceSegment("nothing better than flip flops and barki charcoal sparks fly high"),
        ]

        let result = RepeatedLyricCorrector().corrected(segments)

        XCTAssertTrue(result[3].text.contains("barbecue"))
        XCTAssertFalse(result[3].text.contains("barki"))
        // The rest of the unique tail is untouched.
        XCTAssertTrue(result[3].text.contains("charcoal sparks fly high"))
    }

    func testPhraseRepairPreservesPluralAndIsIdempotent() {
        let segments = [
            sentenceSegment("we love flip flops and barbecue every day"),
            sentenceSegment("they want flip flops and barbecue all night"),
            sentenceSegment("come for flip flops and barbecue right here"),
            sentenceSegment("nothing beats flip flops and barbecues by the lake"),
        ]

        let once = RepeatedLyricCorrector().corrected(segments)
        // "barbecues" is a legitimate plural of the dominant "barbecue" — left alone.
        XCTAssertTrue(once[3].text.contains("barbecues"))
        // Applying twice changes nothing.
        XCTAssertEqual(RepeatedLyricCorrector().corrected(once), once)
    }

    func testPhraseRepairLeavesUnrelatedRareWord() {
        // "ice cold bruise" recurs, but a line says "ice cold beer" — "beer" shares no stem with
        // "bruise", so it must NOT be swapped.
        let segments = [
            sentenceSegment("summer days ice cold bruise feels nice"),
            sentenceSegment("long nights ice cold bruise again now"),
            sentenceSegment("by the fire ice cold bruise once more"),
            sentenceSegment("we drank an ice cold beer by noon"),
        ]

        let result = RepeatedLyricCorrector().corrected(segments)

        XCTAssertTrue(result[3].text.contains("beer"))
        XCTAssertFalse(result[3].text.contains("bruise"))
    }

    func testHallucinationGateDropsOffSignalFragmentAndKeepsRealLines() {
        let realLine = sentenceSegment("hold me close tonight", start: 10)  // 4 words ~10–11.5
        let strayWord = sentenceSegment("time", start: 60)  // 1 word at 60, far from any singing
        let voiced: [ClosedRange<TimeInterval>] = [9.5...13.0]  // covers the real line only

        let result = VocalHallucinationGate.filtered(
            [realLine, strayWord], voicedIntervals: voiced)

        XCTAssertEqual(result.map(\.text), ["hold me close tonight"])
    }

    func testHallucinationGateKeepsShortLineThatSitsOnSinging() {
        let shortOnSignal = sentenceSegment("yeah", start: 10)  // 1 word, but on a voiced region
        let voiced: [ClosedRange<TimeInterval>] = [9.0...11.0]

        XCTAssertEqual(
            VocalHallucinationGate.filtered([shortOnSignal], voicedIntervals: voiced).count, 1)
    }

    func testHallucinationGateIsNoOpWithoutVoicedIntervals() {
        let stray = sentenceSegment("time", start: 60)
        XCTAssertEqual(
            VocalHallucinationGate.filtered([stray], voicedIntervals: []).map(\.text), ["time"])
    }

    func testHallucinationGateDropsLinesAfterTrailingCutoff() {
        let realLine = sentenceSegment("hold me close tonight", start: 10)
        let trailing = sentenceSegment("fake outro words", start: 62)
        let voiced: [ClosedRange<TimeInterval>] = [9.5...13.0, 60.0...61.0]  // bleed blip at 60

        let result = VocalHallucinationGate.filtered(
            [realLine, trailing],
            voicedIntervals: voiced,
            trailingCutoff: 58)

        XCTAssertEqual(result.map(\.text), ["hold me close tonight"])
    }

    func testHallucinationGateKeepsRealOutroVocalBeforeCutoff() {
        let body = sentenceSegment("verse line here", start: 10)
        let outroVocal = sentenceSegment("fade away now", start: 52)
        let voiced: [ClosedRange<TimeInterval>] = [9.5...13.0, 51.0...55.0]

        let result = VocalHallucinationGate.filtered(
            [body, outroVocal],
            voicedIntervals: voiced,
            trailingCutoff: 56)

        XCTAssertEqual(result.map(\.text), ["verse line here", "fade away now"])
    }

    func testVoicedIntervalsForGatingClipsStrictVADAtTrailingCutoff() {
        let strict: [ClosedRange<TimeInterval>] = [0...5, 10...12, 52...62]
        let clipped = VocalActivityEnvelope.voicedIntervalsForGating(strict, trailingCutoff: 55)
        XCTAssertEqual(clipped.map(\.upperBound), [5, 12, 55])
    }

    func testVocalOffsetDetectorFindsEndBeforeSilentOutro() {
        let sampleRate = 8_000.0
        let vocal = sineWave(frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 2))
        let silence = [Float](repeating: 0, count: Int(sampleRate * 2))

        let offset = VocalOffsetDetector.lastOffset(
            samples: vocal + silence, sampleRate: sampleRate)

        XCTAssertNotNil(offset)
        if let offset { XCTAssertEqual(offset, 2.0, accuracy: 0.15) }
    }

    func testVocalOffsetDetectorReturnsNilWhenVocalsRunToEnd() {
        let sampleRate = 8_000.0
        let vocal = sineWave(frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 3))

        XCTAssertNil(VocalOffsetDetector.lastOffset(samples: vocal, sampleRate: sampleRate))
    }

    func testVocalOffsetDetectorIgnoresLowLevelInstrumentalBleedAfterSinging() {
        let sampleRate = 8_000.0
        let vocalBody = scaledSineWave(
            frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 107.7), amplitude: 0.8)
        let bleed = scaledSineWave(
            frequency: 330, sampleRate: sampleRate, count: Int(sampleRate * 1.3), amplitude: 0.06)
        let silence = [Float](repeating: 0, count: Int(sampleRate * 5))
        let samples = vocalBody + bleed + silence

        let offset = VocalOffsetDetector.lastOffset(samples: samples, sampleRate: sampleRate)

        XCTAssertNotNil(offset)
        if let offset {
            XCTAssertGreaterThan(offset, 106.5)
            XCTAssertLessThan(offset, 108.5)
        }
    }

    func testStrictVADIgnoresLowLevelBleedAfterSinging() {
        let sampleRate = 8_000.0
        let vocalBody = scaledSineWave(
            frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 107.7), amplitude: 0.8)
        let bleed = scaledSineWave(
            frequency: 330, sampleRate: sampleRate, count: Int(sampleRate * 1.3), amplitude: 0.06)
        let silence = [Float](repeating: 0, count: Int(sampleRate * 5))
        let samples = vocalBody + bleed + silence

        let intervals = VocalActivityEnvelope.voicedIntervals(
            samples: samples, sampleRate: sampleRate,
            configuration: .strictVocalPresence)

        XCTAssertFalse(intervals.isEmpty)
        if let last = intervals.last {
            XCTAssertLessThan(last.upperBound, 108.5)
        }
    }

    func testVocalOffsetDetectorStillFindsQuietVocalTail() {
        let sampleRate = 8_000.0
        let loud = scaledSineWave(
            frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 2), amplitude: 0.8)
        let quietTail = scaledSineWave(
            frequency: 220, sampleRate: sampleRate, count: Int(sampleRate * 1), amplitude: 0.28)
        let silence = [Float](repeating: 0, count: Int(sampleRate * 5))
        let samples = loud + quietTail + silence

        let offset = VocalOffsetDetector.lastOffset(samples: samples, sampleRate: sampleRate)

        XCTAssertNotNil(offset)
        if let offset { XCTAssertEqual(offset, 3.0, accuracy: 0.2) }
    }

    func testTrailingCorrectionDropsTokensAfterOffset() {
        let segments = [
            TimedTranscriptionSegment(
                text: "real line",
                startTime: 10,
                endTime: 12,
                tokens: [
                    TimedTranscriptionToken(
                        text: "real", startTime: 10, endTime: 11, confidence: 0.9)
                ],
                confidence: 0.9),
            TimedTranscriptionSegment(
                text: "hallucinated outro",
                startTime: 60,
                endTime: 62,
                tokens: [
                    TimedTranscriptionToken(
                        text: "hallucinated", startTime: 60, endTime: 61, confidence: 0.2)
                ],
                confidence: 0.2),
        ]

        let result = TranscriptionOnsetCorrection.preparedSegments(
            segments, droppingAfter: 55)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tokens.first?.text, "real")
    }

    func testSegmentDropRemovesEntireSegmentsStartingAtOrAfterOffset() {
        let segments = [
            TimedTranscriptionSegment(
                text: "real line",
                startTime: 10,
                endTime: 12,
                tokens: [
                    TimedTranscriptionToken(
                        text: "real", startTime: 10, endTime: 11, confidence: 0.9)
                ],
                confidence: 0.9),
            TimedTranscriptionSegment(
                text: "bleed hallucination",
                startTime: 55,
                endTime: 57,
                tokens: [
                    TimedTranscriptionToken(
                        text: "bleed", startTime: 54.8, endTime: 55.2, confidence: 0.3)
                ],
                confidence: 0.3),
            TimedTranscriptionSegment(
                text: "late outro",
                startTime: 60,
                endTime: 62,
                tokens: [
                    TimedTranscriptionToken(
                        text: "late", startTime: 60, endTime: 61, confidence: 0.2)
                ],
                confidence: 0.2),
        ]

        let dropped = TranscriptionOnsetCorrection.preparedSegments(
            segments, droppingSegmentsStartingAtOrAfter: 55)

        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped[0].text, "real line")
    }

    func testTrailingTailPrunerDropsTwoHallucinatedOutroLines() {
        let body = sentenceSegment("last real line here", start: 48)
        let bleedLine = sentenceSegment("guitar bleed words", start: 56)
        let lateLine = sentenceSegment("fake outro phrase", start: 60)
        let voiced: [ClosedRange<TimeInterval>] = [47.0...49.0, 55.5...55.8]

        var lyrics = VocalHallucinationGate.filtered(
            [body, bleedLine, lateLine],
            voicedIntervals: voiced,
            trailingCutoff: 55,
            lastVoicedEnd: 55.8)
        lyrics = TrailingLyricTailPruner.pruned(
            lyrics, lastVoicedEnd: 55.8, vocalOffset: 55)

        XCTAssertEqual(lyrics.map(\.text), ["last real line here"])
    }

    func testSummertimeTailHallucinationsDroppedAtLineStartCutoff() {
        let realLine = sentenceSegment(
            "And under the stars it feels so right", start: 104.26)
        var adjustedReal = realLine
        adjustedReal.end = 107.76
        if let lastWord = adjustedReal.words.last {
            var words = adjustedReal.words
            words[words.count - 1] = TimedLyricWord(
                text: lastWord.text, start: lastWord.start, end: 107.76,
                characterRange: lastWord.characterRange)
            adjustedReal.words = words
        }
        let hallucination1 = sentenceSegment("Sunset winks and starts to leave", start: 107.76)
        let hallucination2 = sentenceSegment("Sunset winks and starts to leave", start: 109.36)
        let vocalOffset = 107.7
        let lastVoicedEnd = 107.76
        let voiced = VocalActivityEnvelope.voicedIntervalsForGating(
            [104.0...107.76, 109.0...109.5], trailingCutoff: vocalOffset)

        var lyrics = VocalHallucinationGate.filtered(
            [adjustedReal, hallucination1, hallucination2],
            voicedIntervals: voiced,
            trailingCutoff: vocalOffset,
            lastVoicedEnd: lastVoicedEnd)
        lyrics = TrailingLyricTailPruner.pruned(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset,
            sourceDuration: 233)
        lyrics = TrailingDuplicateLineCollapser.collapsed(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset)
        lyrics = TrailingEarlierLyricRepeater.filtered(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: vocalOffset,
            sourceDuration: 233)

        XCTAssertEqual(lyrics.count, 1)
        XCTAssertEqual(lyrics[0].text, "And under the stars it feels so right")
    }

    func testSummertimeSingleTailEarlierLyricRepeaterDropped() {
        let earlier = sentenceSegment("Sunset winks and starts to leave", start: 40)
        let realLine = sentenceSegment(
            "And under the stars it feels so right", start: 104.26)
        var adjustedReal = realLine
        adjustedReal.end = 107.76
        if let lastWord = adjustedReal.words.last {
            var words = adjustedReal.words
            words[words.count - 1] = TimedLyricWord(
                text: lastWord.text, start: lastWord.start, end: 107.76,
                characterRange: lastWord.characterRange)
            adjustedReal.words = words
        }
        let tailCopy = sentenceSegment("Sunset winks and starts to leave", start: 107.76)
        let lateOffset = 109.5

        var lyrics = [earlier, adjustedReal, tailCopy]
        lyrics = TrailingEarlierLyricRepeater.filtered(
            lyrics, lastVoicedEnd: lateOffset, vocalOffset: lateOffset,
            sourceDuration: 233)

        XCTAssertEqual(
            lyrics.map(\.text),
            [
                "Sunset winks and starts to leave",
                "And under the stars it feels so right",
            ])
    }

    func testTrailingEarlierLyricRepeaterKeepsRealDoubleChorus() {
        let chorus1 = sentenceSegment("It's a party going on tonight", start: 4)
        let chorus2 = sentenceSegment("It's a party going on tonight", start: 24)
        let result = TrailingEarlierLyricRepeater.filtered(
            [chorus1, chorus2],
            lastVoicedEnd: 30,
            vocalOffset: 30,
            sourceDuration: 60)
        XCTAssertEqual(result.count, 2)
    }

    func testSummertimeTailHallucinationsDroppedWhenVocalOffsetNilAndBleedBlip() {
        let realLine = sentenceSegment(
            "And under the stars it feels so right", start: 104.26)
        var adjustedReal = realLine
        adjustedReal.end = 107.76
        if let lastWord = adjustedReal.words.last {
            var words = adjustedReal.words
            words[words.count - 1] = TimedLyricWord(
                text: lastWord.text, start: lastWord.start, end: 107.76,
                characterRange: lastWord.characterRange)
            adjustedReal.words = words
        }
        let hallucination1 = sentenceSegment("Sunset winks and starts to leave", start: 107.76)
        let hallucination2 = sentenceSegment("Sunset winks and starts to leave", start: 109.36)
        let strictVoiced: [ClosedRange<TimeInterval>] = [104.0...107.76, 109.0...109.5]
        let tailCutoff = VocalTailCutoffResolver.resolve(
            detectedOffset: nil,
            strictVoicedIntervals: strictVoiced,
            sourceDuration: 233)
        XCTAssertNotNil(tailCutoff.effectiveOffset)
        if let offset = tailCutoff.effectiveOffset {
            XCTAssertEqual(offset, 107.76, accuracy: 0.01)
        }

        let voiced = VocalActivityEnvelope.voicedIntervalsForGating(
            strictVoiced, trailingCutoff: tailCutoff.effectiveOffset)
        let lastVoicedEnd = tailCutoff.lastVoicedEnd ?? voiced.map(\.upperBound).max()

        var lyrics = VocalHallucinationGate.filtered(
            [adjustedReal, hallucination1, hallucination2],
            voicedIntervals: voiced,
            trailingCutoff: tailCutoff.effectiveOffset,
            lastVoicedEnd: lastVoicedEnd)
        lyrics = TrailingLyricTailPruner.pruned(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: tailCutoff.effectiveOffset,
            sourceDuration: 233)
        lyrics = TrailingDuplicateLineCollapser.collapsed(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: tailCutoff.effectiveOffset)
        lyrics = TrailingEarlierLyricRepeater.filtered(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: tailCutoff.effectiveOffset,
            sourceDuration: 233)

        XCTAssertEqual(lyrics.map(\.text), ["And under the stars it feels so right"])
    }

    func testSummertimeTailHallucinationsDroppedWhenVocalOffsetIsLate() {
        let realLine = sentenceSegment(
            "And under the stars it feels so right", start: 104.26)
        var adjustedReal = realLine
        adjustedReal.end = 107.76
        if let lastWord = adjustedReal.words.last {
            var words = adjustedReal.words
            words[words.count - 1] = TimedLyricWord(
                text: lastWord.text, start: lastWord.start, end: 107.76,
                characterRange: lastWord.characterRange)
            adjustedReal.words = words
        }
        let hallucination1 = sentenceSegment("Sunset winks and starts to leave", start: 107.76)
        let hallucination2 = sentenceSegment("Sunset winks and starts to leave", start: 109.36)
        let lateOffset = 109.5
        let lastVoicedEnd = 109.5
        let voiced = VocalActivityEnvelope.voicedIntervalsForGating(
            [104.0...107.76, 109.0...109.5], trailingCutoff: lateOffset)

        var lyrics = VocalHallucinationGate.filtered(
            [adjustedReal, hallucination1, hallucination2],
            voicedIntervals: voiced,
            trailingCutoff: lateOffset,
            lastVoicedEnd: lastVoicedEnd)
        lyrics = TrailingLyricTailPruner.pruned(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: lateOffset,
            sourceDuration: 233)
        lyrics = TrailingDuplicateLineCollapser.collapsed(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: lateOffset)
        lyrics = TrailingEarlierLyricRepeater.filtered(
            lyrics, lastVoicedEnd: lastVoicedEnd, vocalOffset: lateOffset,
            sourceDuration: 233)

        XCTAssertEqual(lyrics.map(\.text), ["And under the stars it feels so right"])
    }

    func testVocalTailCutoffResolverPrefersBodyEndOverLateDetector() {
        let strictVoiced: [ClosedRange<TimeInterval>] = [104.0...107.76, 109.0...109.5]
        let resolved = VocalTailCutoffResolver.resolve(
            detectedOffset: 109.5,
            strictVoicedIntervals: strictVoiced,
            sourceDuration: 233)
        XCTAssertNotNil(resolved.effectiveOffset)
        XCTAssertNotNil(resolved.lastVoicedEnd)
        if let offset = resolved.effectiveOffset {
            XCTAssertEqual(offset, 107.76, accuracy: 0.01)
        }
        if let voicedEnd = resolved.lastVoicedEnd {
            XCTAssertEqual(voicedEnd, 107.76, accuracy: 0.01)
        }
    }

    func testTrailingDuplicateLineCollapserDropsRepeatedTailLines() {
        let body = sentenceSegment("real chorus line here", start: 40)
        let duplicate1 = sentenceSegment("Sunset winks and starts to leave", start: 107.76)
        let duplicate2 = sentenceSegment("Sunset winks and starts to leave", start: 109.36)

        let result = TrailingDuplicateLineCollapser.collapsed(
            [body, duplicate1, duplicate2],
            lastVoicedEnd: 107.76,
            vocalOffset: 107.7)

        XCTAssertEqual(
            result.map(\.text),
            [
                "real chorus line here",
                "Sunset winks and starts to leave",
            ])
    }

    func testTrailingCorrectionDropsTokensStartingAtOrAfterOffset() {
        let segments = [
            TimedTranscriptionSegment(
                text: "real line tail",
                startTime: 104,
                endTime: 108,
                tokens: [
                    TimedTranscriptionToken(
                        text: "real", startTime: 104, endTime: 105, confidence: 0.9),
                    TimedTranscriptionToken(
                        text: "tail", startTime: 107.76, endTime: 108, confidence: 0.2),
                ],
                confidence: 0.9)
        ]

        let result = TranscriptionOnsetCorrection.preparedSegments(
            segments, droppingAfter: 107.7)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tokens.map(\.text), ["real"])
    }

    func testTrailingTailPrunerKeepsRealOutroVocalBeforeOffset() {
        let body = sentenceSegment("verse line here", start: 10)
        let outroVocal = sentenceSegment("fade away now", start: 52)
        let voiced: [ClosedRange<TimeInterval>] = [9.5...13.0, 51.0...54.5]

        var lyrics = VocalHallucinationGate.filtered(
            [body, outroVocal],
            voicedIntervals: voiced,
            trailingCutoff: 55)
        lyrics = TrailingLyricTailPruner.pruned(
            lyrics, lastVoicedEnd: 54.5, vocalOffset: 55)

        XCTAssertEqual(lyrics.map(\.text), ["verse line here", "fade away now"])
    }

    func testDistributeAcrossSignalNoOpWithoutVoicedRegions() {
        let line = TimedLyricSegment(
            start: 1, end: 2, text: "x",
            words: [TimedLyricWord(text: "x", start: 1, end: 2, characterRange: 0..<1)])
        XCTAssertEqual(
            VocalAlignmentCorrector.distributeAcrossSignal([line], voicedIntervals: []), [line])
    }

    func testInstrumentOnsetDetectorFindsTwoBurstsSeparatedBySilence() {
        let sampleRate = 8_000.0
        let silence = [Float](repeating: 0, count: Int(sampleRate))  // 1s
        // 0.5s
        let burst = sineWave(frequency: 220, sampleRate: sampleRate, count: Int(sampleRate / 2))
        // silence, burst@1.0, silence, burst@2.5
        let samples = silence + burst + silence + burst

        let onsets = InstrumentOnsetDetector.onsets(samples: samples, sampleRate: sampleRate)

        // Each attack should yield exactly one onset near where the burst begins.
        XCTAssertEqual(onsets.count, 2)
        if onsets.count == 2 {
            XCTAssertEqual(onsets[0], 1.0, accuracy: 0.12)
            XCTAssertEqual(onsets[1], 2.5, accuracy: 0.12)
        }
    }

    func testInstrumentOnsetDetectorReturnsEmptyForDegenerateInput() {
        XCTAssertTrue(InstrumentOnsetDetector.onsets(samples: [], sampleRate: 8_000).isEmpty)
        XCTAssertTrue(
            InstrumentOnsetDetector.onsets(samples: [0.1, 0.2, 0.3], sampleRate: 0).isEmpty)
        // Input shorter than one analysis window yields no onsets.
        XCTAssertTrue(
            InstrumentOnsetDetector.onsets(samples: [0.1, 0.2, 0.3], sampleRate: 8_000).isEmpty)
    }

    func testChordOnsetAlignerSnapsEventsToNearestOnsetWithinTolerance() {
        let events = [
            EditableChordEvent(time: 1.0, chord: "C", confidence: 0.8),
            EditableChordEvent(time: 2.4, chord: "G", confidence: 0.8),
        ]
        let onsets: [TimeInterval] = [1.05, 2.5]

        let snapped = ChordOnsetAligner.snap(events, toOnsets: onsets, tolerance: 0.2)

        XCTAssertEqual(snapped.count, 2)
        XCTAssertEqual(snapped[0].time, 1.05, accuracy: 0.000_001)
        XCTAssertEqual(snapped[1].time, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(snapped.map(\.chord), ["C", "G"])  // order/content preserved
    }

    func testChordOnsetAlignerLeavesEventWithNoNearbyOnsetPut() {
        let events = [
            EditableChordEvent(time: 1.0, chord: "C", confidence: 0.8),
            // no onset within tolerance
            EditableChordEvent(time: 5.0, chord: "G", confidence: 0.8),
        ]
        let onsets: [TimeInterval] = [1.05, 2.5]

        let snapped = ChordOnsetAligner.snap(events, toOnsets: onsets, tolerance: 0.2)

        XCTAssertEqual(snapped[0].time, 1.05, accuracy: 0.000_001)
        XCTAssertEqual(snapped[1].time, 5.0, accuracy: 0.000_001)  // unchanged
    }

    func testChordOnsetAlignerEmptyOnsetsLeavesEventsUnchanged() {
        let events = [
            EditableChordEvent(time: 1.0, chord: "C", confidence: 0.8),
            EditableChordEvent(time: 2.4, chord: "G", confidence: 0.8),
        ]
        XCTAssertEqual(ChordOnsetAligner.snap(events, toOnsets: []), events)
    }

    func testChordOnsetAlignerKeepsTimesNondecreasing() {
        // Two close events whose nearest onsets would reorder them: the second is clamped up to
        // the first so order is preserved.
        let events = [
            EditableChordEvent(time: 1.0, chord: "C", confidence: 0.8),
            EditableChordEvent(time: 1.1, chord: "G", confidence: 0.8),
        ]
        let onsets: [TimeInterval] = [1.2, 0.95]

        let snapped = ChordOnsetAligner.snap(events, toOnsets: onsets, tolerance: 0.35)

        XCTAssertLessThanOrEqual(snapped[0].time, snapped[1].time)
        XCTAssertEqual(snapped.count, 2)
    }

    // MARK: - DrumBeatGrid

    func testDrumBeatGridPhaseLocksAndSnapsToDrumOnsets() {
        // BPM 120 → interval 0.5. Drum hits at 0.5, 1.0, 1.5, 2.0. Each real hit must appear as a
        // beat snapped onto the actual onset (phase-locked + onset-snapped).
        let onsets: [TimeInterval] = [0.5, 1.0, 1.5, 2.0]

        let beats = DrumBeatGrid.beatTimes(onsets: onsets, bpm: 120, duration: 2.5)

        for onset in onsets {
            XCTAssertTrue(
                beats.contains(where: { abs($0 - onset) <= 0.05 }),
                "expected a beat snapped to \(onset), got \(beats)")
        }
        // Strictly increasing, ~one beat per interval.
        XCTAssertEqual(beats, beats.sorted())
        XCTAssertEqual(Set(beats).count, beats.count)
    }

    func testDrumBeatGridKeepsUniformBeatWhereOnsetIsMissing() {
        // A missing hit at 1.5 (gap in onsets): the surrounding beats snap to the real onsets, while
        // the beat near 1.5 is kept from the uniform grid (no onset to snap to).
        let onsets: [TimeInterval] = [0.5, 1.0, 2.0]

        let beats = DrumBeatGrid.beatTimes(onsets: onsets, bpm: 120, duration: 2.5)

        XCTAssertEqual(beats[0], 0.5, accuracy: 0.05)
        XCTAssertEqual(beats[1], 1.0, accuracy: 0.05)
        // Still emits a beat near 1.5 even though there's no onset there.
        XCTAssertTrue(
            beats.contains(where: { abs($0 - 1.5) <= 0.05 }),
            "expected a kept uniform-grid beat near 1.5, got \(beats)")
        XCTAssertTrue(beats.contains(where: { abs($0 - 2.0) <= 0.05 }))
    }

    func testDrumBeatGridReturnsEmptyForDegenerateInput() {
        XCTAssertTrue(DrumBeatGrid.beatTimes(onsets: [], bpm: 120, duration: 2.5).isEmpty)
        XCTAssertTrue(DrumBeatGrid.beatTimes(onsets: [0.5, 1.0], bpm: 0, duration: 2.5).isEmpty)
        XCTAssertTrue(DrumBeatGrid.beatTimes(onsets: [0.5, 1.0], bpm: -120, duration: 2.5).isEmpty)
        XCTAssertTrue(DrumBeatGrid.beatTimes(onsets: [0.5, 1.0], bpm: 120, duration: 0).isEmpty)
    }

    func testVocalWordOnsetAlignerSnapsNearWordsAndReDerivesSegment() {
        let segment = TimedLyricSegment(
            start: 0.50, end: 2.00, text: "Oceans moving",
            words: [
                TimedLyricWord(text: "Oceans", start: 0.50, end: 0.72, characterRange: 0..<6),
                TimedLyricWord(text: "moving", start: 1.30, end: 1.80, characterRange: 7..<13),
            ])
        // 0.40 is within tolerance (0.15) of "Oceans" (0.50) → snaps. The nearest onset to
        // "moving" (1.30) is 1.55 at distance 0.25 > tolerance → left unchanged.
        let out = VocalWordOnsetAligner.snapped(
            [segment], toOnsets: [0.40, 1.00, 1.55], tolerance: 0.15)
        XCTAssertEqual(out[0].words[0].start, 0.40, accuracy: 1e-9)
        XCTAssertEqual(out[0].words[1].start, 1.30, accuracy: 1e-9)
        // Segment start is re-derived from the snapped first word.
        XCTAssertEqual(out[0].start, 0.40, accuracy: 1e-9)
    }

    func testVocalWordOnsetAlignerIsNoOpWithoutOnsets() {
        let segment = TimedLyricSegment(
            start: 1, end: 2, text: "hi",
            words: [TimedLyricWord(text: "hi", start: 1, end: 2, characterRange: 0..<2)])
        XCTAssertEqual(VocalWordOnsetAligner.snapped([segment], toOnsets: []), [segment])
    }

    func testVocalWordOnsetAlignerKeepsWordsNondecreasingAndPositiveDuration() {
        let segment = TimedLyricSegment(
            start: 1.0, end: 1.9, text: "a b",
            words: [
                TimedLyricWord(text: "a", start: 1.00, end: 1.40, characterRange: 0..<1),
                TimedLyricWord(text: "b", start: 1.50, end: 1.90, characterRange: 2..<3),
            ])
        // An onset at 0.90 sits within tolerance of BOTH words; the second must not be pulled
        // before the first, and each must keep a positive duration.
        let out = VocalWordOnsetAligner.snapped(
            [segment], toOnsets: [0.90], tolerance: 0.7)
        XCTAssertGreaterThanOrEqual(out[0].words[1].start, out[0].words[0].start)
        XCTAssertLessThan(out[0].words[0].start, out[0].words[0].end)
        XCTAssertLessThan(out[0].words[1].start, out[0].words[1].end)
    }

    // MARK: - StrandedLeadingWordRepairer

    private func oceansSegment() -> TimedLyricSegment {
        // The real Summertime defect: "Oceans" 59.54-59.76 stranded on a bleed blip; the line
        // body starts at 62.12; the gap 59.76-62.12 is unvoiced.
        TimedLyricSegment(
            start: 59.54, end: 63.86, text: "Oceans moving the waves alive",
            words: [
                TimedLyricWord(text: "Oceans", start: 59.54, end: 59.76, characterRange: 0..<6),
                TimedLyricWord(text: "moving", start: 62.12, end: 62.63, characterRange: 7..<13),
                TimedLyricWord(text: "the", start: 62.74, end: 62.92, characterRange: 14..<17),
            ])
    }

    func testStrandedLeadingWordPulledForwardAcrossUnvoicedGap() {
        let voiced: [ClosedRange<TimeInterval>] = [59.45...59.80, 61.80...63.90]
        let out = StrandedLeadingWordRepairer.repaired([oceansSegment()], voicedIntervals: voiced)
        let oceans = out[0].words[0]
        // Translated forward to abut the body at 62.12 (duration 0.22 preserved).
        XCTAssertEqual(oceans.end, 62.04, accuracy: 0.01)
        XCTAssertEqual(oceans.end - oceans.start, 0.22, accuracy: 1e-6)
        XCTAssertEqual(out[0].start, oceans.start, accuracy: 1e-9)
        XCTAssertEqual(out[0].words[1].start, 62.12, accuracy: 1e-9)
    }

    func testHeldNoteVoicedGapIsNotRepaired() {
        // Same shape, but the gap is SUNG (a held "Ocea—ns"): fully voiced → untouched.
        let voiced: [ClosedRange<TimeInterval>] = [59.45...63.90]
        let out = StrandedLeadingWordRepairer.repaired([oceansSegment()], voicedIntervals: voiced)
        XCTAssertEqual(out[0].words[0].start, 59.54, accuracy: 1e-9)
    }

    func testShortGapAndLargeLeadingClustersAreNotRepaired() {
        // Gap under the minimum: untouched.
        var segment = oceansSegment()
        segment.words[0].start = 61.30
        segment.words[0].end = 61.52
        let voiced: [ClosedRange<TimeInterval>] = [61.80...63.90]
        let out = StrandedLeadingWordRepairer.repaired([segment], voicedIntervals: voiced)
        XCTAssertEqual(out[0].words[0].start, 61.30, accuracy: 1e-9)
        // A 3-word leading cluster exceeds maximumLeadingWords (2): untouched.
        let big = TimedLyricSegment(
            start: 10, end: 20, text: "one two three four",
            words: [
                TimedLyricWord(text: "one", start: 10.0, end: 10.2, characterRange: 0..<3),
                TimedLyricWord(text: "two", start: 10.3, end: 10.5, characterRange: 4..<7),
                TimedLyricWord(text: "three", start: 10.6, end: 10.8, characterRange: 8..<13),
                TimedLyricWord(text: "four", start: 15.0, end: 15.3, characterRange: 14..<18),
            ])
        let out2 = StrandedLeadingWordRepairer.repaired(
            [big], voicedIntervals: [15.0...16.0])
        XCTAssertEqual(out2[0].words[0].start, 10.0, accuracy: 1e-9)
    }

    // MARK: - VocalWordSpanNormalizer (audit RC-3: melisma phantom pauses)

    private func summertimesSegment() -> TimedLyricSegment {
        // Real Summertime defect: "Summertime's" got a 0.13s span (46.10-46.23) though the
        // word is HELD to ~48.2 where "here" begins; the chart drew a 2s phantom pause.
        TimedLyricSegment(
            start: 46.10, end: 49.80, text: "Summertime's here with you",
            words: [
                TimedLyricWord(
                    text: "Summertime's", start: 46.10, end: 46.23, characterRange: 0..<12),
                TimedLyricWord(text: "here", start: 48.21, end: 48.80, characterRange: 13..<17),
                TimedLyricWord(text: "with", start: 48.85, end: 49.37, characterRange: 18..<22),
                TimedLyricWord(text: "you", start: 49.31, end: 49.80, characterRange: 23..<26),
            ])
    }

    func testMelismaBridgeExtendsHeldWordAcrossVoicedGap() {
        // Continuously voiced across the whole line: the tiny "Summertime's" span extends
        // to the next word's onset — the hold is sung, not a pause.
        let voiced: [ClosedRange<TimeInterval>] = [45.9...50.0]
        let out = VocalWordSpanNormalizer.normalized(
            [summertimesSegment()], voicedIntervals: voiced)
        XCTAssertEqual(out[0].words[0].end, 48.21, accuracy: 1e-9)
        // Onsets untouched; text/order preserved.
        XCTAssertEqual(out[0].words.map(\.text), ["Summertime's", "here", "with", "you"])
        XCTAssertEqual(out[0].words[1].start, 48.21, accuracy: 1e-9)
    }

    func testRealPauseIsNotBridged() {
        // The gap is genuinely silent: word spans stay put (no fake melisma).
        let voiced: [ClosedRange<TimeInterval>] = [45.9...46.3, 48.15...50.0]
        let out = VocalWordSpanNormalizer.normalized(
            [summertimesSegment()], voicedIntervals: voiced)
        XCTAssertEqual(out[0].words[0].end, 46.23, accuracy: 1e-9)
    }

    func testLateOnsetPulledBackToVoicedReentryEdge() {
        // Mostly-unvoiced gap, but the voice re-enters at 47.60 while ASR put "here" at
        // 48.21 → onset pulled back to the audible edge.
        let voiced: [ClosedRange<TimeInterval>] = [45.9...46.3, 47.60...50.0]
        let out = VocalWordSpanNormalizer.normalized(
            [summertimesSegment()], voicedIntervals: voiced)
        XCTAssertEqual(out[0].words[1].start, 47.60, accuracy: 1e-9)
        // Duration stays positive and order nondecreasing.
        XCTAssertLessThan(out[0].words[1].start, out[0].words[1].end)
        XCTAssertGreaterThanOrEqual(out[0].words[1].start, out[0].words[0].end)
    }

    func testShortGapsAndEmptyVADAreUntouched() {
        let segment = summertimesSegment()
        // No voiced intervals → exact passthrough.
        let out = VocalWordSpanNormalizer.normalized([segment], voicedIntervals: [])
        XCTAssertEqual(out[0].words[0].end, 46.23, accuracy: 1e-9)
        // Sub-minimum gap (0.05s "here"→"with") is never touched even when voiced.
        let out2 = VocalWordSpanNormalizer.normalized(
            [segment], voicedIntervals: [45.9...50.0])
        XCTAssertEqual(out2[0].words[1].end, 48.80, accuracy: 1e-9)
        XCTAssertEqual(out2[0].words[2].start, 48.85, accuracy: 1e-9)
    }

    // MARK: - TranscriptionVoicedCoverage (whisper decode-collapse detection)

    private func coverageResult(_ spans: [(Double, Double)]) -> TranscriptionResult {
        TranscriptionResult(
            text: "",
            languageCode: nil,
            sourceDuration: 226,
            completedAt: Date(timeIntervalSince1970: 0),
            segments: spans.map {
                TimedTranscriptionSegment(
                    text: "x", startTime: $0.0, endTime: $0.1, tokens: [], confidence: 0.9)
            },
            engine: TranscriptionEngineMetadata(
                engineName: "test", modelName: "test", modelVersion: nil,
                modelSizeBytes: 0,
                license: TranscriptionModelLicense(name: "test", url: nil)))
    }

    func testCollapsedDecodeHasLowVoicedCoverage() {
        // The real failure: transcription covers 0–66s then jumps to the outro, while the
        // voice sings through most of the file.
        let voiced: [ClosedRange<TimeInterval>] = [20.0...200.0]
        let collapsed = coverageResult([(0, 66), (204, 204.4), (221, 225.6)])
        let coverage = TranscriptionVoicedCoverage.fraction(
            of: collapsed, voicedIntervals: voiced)
        XCTAssertLessThan(coverage ?? 1, 0.6)

        let healthy = coverageResult([(18, 100), (100, 202)])
        XCTAssertGreaterThan(
            TranscriptionVoicedCoverage.fraction(of: healthy, voicedIntervals: voiced) ?? 0,
            0.95)
    }

    func testOverlappingSegmentsDoNotDoubleCountCoverage() {
        let voiced: [ClosedRange<TimeInterval>] = [0.0...100.0]
        // Two fully-overlapping 50s segments must count once (0.5), not twice.
        let overlapping = coverageResult([(0, 50), (0, 50)])
        XCTAssertEqual(
            TranscriptionVoicedCoverage.fraction(of: overlapping, voicedIntervals: voiced) ?? 0,
            0.5, accuracy: 1e-9)
    }

    // MARK: - VocalTailCutoffResolver: sustained voiced tails are real singing

    func testCutoffExtendsThroughSustainedVoicedOutro() {
        // The real "Settle Down" defect: the level-aware detector anchored at ~220.4 on the
        // last LOUD phrase, but strict VAD hears three sustained sung intervals after it
        // (2.4s / 2.2s / 3.0s — quiet outro repeats). The cutoff must extend to 230.1 so the
        // transcribed lines at 220.8–229.8 survive the tail gates.
        let voiced: [ClosedRange<TimeInterval>] = [
            22.0...220.3, 221.5...223.9, 224.3...226.5, 227.1...230.1,
        ]
        let resolved = VocalTailCutoffResolver.resolve(
            detectedOffset: 220.4, strictVoicedIntervals: voiced, sourceDuration: 257.1)
        XCTAssertEqual(resolved.effectiveOffset ?? 0, 230.1, accuracy: 1e-9)
        XCTAssertEqual(resolved.lastVoicedEnd ?? 0, 230.1, accuracy: 1e-9)
    }

    func testCutoffDoesNotExtendThroughShortBleedBlips() {
        // Trailing sub-1.5s blips after the offset are bleed (the Summertime scenario):
        // the cutoff must NOT extend through them.
        let voiced: [ClosedRange<TimeInterval>] = [22.0...107.7, 109.3...109.9]
        let resolved = VocalTailCutoffResolver.resolve(
            detectedOffset: 107.76, strictVoicedIntervals: voiced, sourceDuration: 158.7)
        // Resolver anchors on the strict-VAD body end (107.7, before the blip) and the
        // 0.6s blip must not extend it.
        XCTAssertEqual(resolved.effectiveOffset ?? 0, 107.7, accuracy: 1e-9)
    }

    // MARK: - IntraLinePauseSplitter (double-phrase ASR lines)

    /// The real "Settle Down" defect: one ASR segment holding two chorus phrases with a
    /// 1.7 s silent pause between "down," and "trading".
    private func settleDownDoubleLine() -> TimedLyricSegment {
        let text = "She makes me want to settle down, trading my rowdy friends"
        var words: [TimedLyricWord] = []
        var cursor = 0
        var time = 54.4
        for token in text.components(separatedBy: " ") {
            let start = cursor
            let end = cursor + token.count
            let onset = time
            words.append(
                TimedLyricWord(
                    text: token, start: onset, end: onset + 0.4, characterRange: start..<end))
            cursor = end + 1
            // 1.72 s pause after "down," (word 6 → 7); tight spacing elsewhere.
            time += token == "down," ? 2.12 : 0.5
        }
        return TimedLyricSegment(start: 54.4, end: 65.8, text: text, words: words)
    }

    func testDoublePhraseLineSplitsAtUnvoicedPause() {
        let segment = settleDownDoubleLine()
        let pauseStart = segment.words[6].end
        let pauseEnd = segment.words[7].start
        // Voice everywhere EXCEPT the pause.
        let voiced: [ClosedRange<TimeInterval>] = [54.0...pauseStart, pauseEnd...66.0]
        let out = IntraLinePauseSplitter.split([segment], voicedIntervals: voiced)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "She makes me want to settle down,")
        XCTAssertEqual(out[1].text, "trading my rowdy friends")
        // Right-hand character ranges are rebased to the new text.
        XCTAssertEqual(out[1].words.first?.characterRange, 0..<7)
        XCTAssertEqual(out[1].words.map(\.text), ["trading", "my", "rowdy", "friends"])
        // Timing preserved: the split lines cover the original words exactly.
        XCTAssertEqual(out[0].start, segment.words[0].start, accuracy: 1e-9)
        XCTAssertEqual(out[1].start, segment.words[7].start, accuracy: 1e-9)
    }

    func testHeldNotePauseDoesNotSplit() {
        // Same shape but the gap is SUNG (fully voiced): a held word, not a phrase break.
        let segment = settleDownDoubleLine()
        let out = IntraLinePauseSplitter.split([segment], voicedIntervals: [54.0...66.0])
        XCTAssertEqual(out.count, 1)
    }

    func testShortGapsAndShortSidesDoNotSplit() {
        var segment = settleDownDoubleLine()
        // Shrink the pause under the threshold: no split.
        let shifted = segment.words.enumerated().map { index, word -> TimedLyricWord in
            var w = word
            if index >= 7 {
                w.start -= 1.4
                w.end -= 1.4
            }
            return w
        }
        segment.words = shifted
        let out = IntraLinePauseSplitter.split(
            [segment], voicedIntervals: [54.0...55.0])
        XCTAssertEqual(out.count, 1)
        // A qualifying gap too close to the edge (fewer than 4 words on one side): no split.
        let tail = TimedLyricSegment(
            start: 0, end: 6, text: "one two three four five six",
            words: [
                TimedLyricWord(text: "one", start: 0.0, end: 0.3, characterRange: 0..<3),
                TimedLyricWord(text: "two", start: 0.4, end: 0.7, characterRange: 4..<7),
                TimedLyricWord(text: "three", start: 0.8, end: 1.1, characterRange: 8..<13),
                TimedLyricWord(text: "four", start: 1.2, end: 1.5, characterRange: 14..<18),
                TimedLyricWord(text: "five", start: 1.6, end: 1.9, characterRange: 19..<23),
                TimedLyricWord(text: "six", start: 4.0, end: 4.3, characterRange: 24..<27),
            ])
        XCTAssertEqual(
            IntraLinePauseSplitter.split([tail], voicedIntervals: [0.0...2.0, 3.9...4.4]).count,
            1)
    }

    // MARK: - UntranscribedVocalRegionDetector (audit RC-4: sung spans with no words)

    func testUntranscribedRegionFoundAfterLastWordOfASection() {
        // Real Summertime shape: words end at 49.8 but the voice sings to 55.4.
        let segment = TimedLyricSegment(
            start: 46.1, end: 49.8, text: "Summertime's here with you",
            words: [
                TimedLyricWord(
                    text: "Summertime's", start: 46.1, end: 48.2, characterRange: 0..<12),
                TimedLyricWord(text: "you", start: 49.3, end: 49.8, characterRange: 23..<26),
            ])
        let regions = UntranscribedVocalRegionDetector.regions(
            voicedIntervals: [23.5...55.4], lyrics: [segment])
        // Leading region (23.5 → padded word start) and the missed tail (padded end → 55.4).
        XCTAssertTrue(
            regions.contains { abs($0.upperBound - 55.4) < 1e-9 && $0.lowerBound > 49.9 },
            "expected the 50.05...55.4 tail, got \(regions)")
    }

    func testFullyCoveredVocalsYieldNoRegions() {
        let segment = TimedLyricSegment(
            start: 10, end: 14, text: "la la",
            words: [
                TimedLyricWord(text: "la", start: 10, end: 12, characterRange: 0..<2),
                TimedLyricWord(text: "la", start: 12, end: 14, characterRange: 3..<5),
            ])
        XCTAssertEqual(
            UntranscribedVocalRegionDetector.regions(
                voicedIntervals: [10.1...13.9], lyrics: [segment]),
            [])
    }

    func testShortUncoveredBlipsAreIgnored() {
        // A 1.0s uncovered voiced blip is under the 1.5s minimum: not a region.
        let segment = TimedLyricSegment(
            start: 10, end: 12, text: "word",
            words: [TimedLyricWord(text: "word", start: 10, end: 12, characterRange: 0..<4)])
        XCTAssertEqual(
            UntranscribedVocalRegionDetector.regions(
                voicedIntervals: [10.0...12.0, 20.0...21.0], lyrics: [segment]),
            [])
        // But a 3s one is.
        let regions = UntranscribedVocalRegionDetector.regions(
            voicedIntervals: [10.0...12.0, 20.0...23.0], lyrics: [segment])
        XCTAssertEqual(regions, [20.0...23.0])
    }
}
