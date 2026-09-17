import AVFoundation
import XCTest

@testable import SongWorkbench

final class AudioAnalysisTests: XCTestCase {
    func testAudioRegionExporterWritesOnlyRequestedFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AudioRegionExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.wav")
        let destinationURL = directory.appendingPathComponent("region.wav")
        let sampleRate = 8_000.0
        try writeSilentWAV(
            to: sourceURL,
            frameCount: 24_000,
            sampleRate: sampleRate
        )

        try AudioRegionExporter().export(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            range: 0.75...1.5
        )

        let result = try AVAudioFile(forReading: destinationURL)
        XCTAssertEqual(result.processingFormat.sampleRate, sampleRate)
        XCTAssertEqual(result.length, 6_000)
    }

    func testPhaseInvariantChannelEnergyPreservesOppositePolarityStereo() {
        XCTAssertEqual(
            PhaseInvariantChannelEnergy.sample([1, -1]), 1, accuracy: 1e-9,
            "energy detectors must not cancel a wide or polarity-inverted stereo vocal")
        XCTAssertEqual(PhaseInvariantChannelEnergy.sample([]), 0)
    }

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

    func testEPedalWithFSharpMinorUpperStructureRelabelsAwayFromE() {
        // Eight Miles High intro shape: open-E drone plus F#m tones. Root-weighted matching
        // locks onto E; the pedal relabeler must recover F#m.
        let frames = pedalFrames([
            .e: 0.70, .fSharp: 0.10, .a: 0.09, .cSharp: 0.08,
        ])
        let naive = frames.map { ChordClassifier().classify($0).chord.displayName }
        XCTAssertTrue(
            naive.contains("E"),
            "sanity: the drone wins without pedal handling, got \(Set(naive))")
        let relabeled = PedalAwareChordRelabeler.observations(
            from: frames, classifier: ChordClassifier())
        XCTAssertEqual(Set(relabeled.map { $0.chord.displayName }), ["F#m"])
    }

    func testEPedalWithGMajorUpperStructureRelabelsToG() {
        let frames = pedalFrames([
            .e: 0.70, .g: 0.10, .b: 0.09, .d: 0.08,
        ])
        let relabeled = PedalAwareChordRelabeler.observations(
            from: frames, classifier: ChordClassifier())
        XCTAssertEqual(Set(relabeled.map { $0.chord.displayName }), ["G"])
    }

    func testEPowerChordDoesNotBecomeBWhenThePedalIsDownweighted() {
        // E5 (E+B, no third). Downweighting E leaves B; that leftover must not be promoted
        // to B major because the third and fifth of B are absent.
        let frames = pedalFrames([.e: 0.55, .b: 0.40])
        let relabeled = PedalAwareChordRelabeler.observations(
            from: frames, classifier: ChordClassifier())
        XCTAssertEqual(Set(relabeled.map { $0.chord.root }), [.e])
    }

    func testPlainCMajorWithoutAPedalStaysCMajor() {
        let frames = pedalFrames([.c: 0.40, .e: 0.30, .g: 0.28])
        let relabeled = PedalAwareChordRelabeler.observations(
            from: frames, classifier: ChordClassifier())
        XCTAssertEqual(Set(relabeled.map { $0.chord.displayName }), ["C"])
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

    private func writeSilentWAV(
        to url: URL,
        frameCount: AVAudioFrameCount,
        sampleRate: Double
    ) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
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

    /// Normalized chroma frames with a small floor in unused bins, 100 ms apart.
    private func pedalFrames(_ energy: [PitchClass: Float], count: Int = 20) -> [ChromaVector] {
        (0..<count).map { index in
            var values = Array(repeating: Float(0.01), count: PitchClass.allCases.count)
            for (pitchClass, value) in energy {
                values[pitchClass.rawValue] = value
            }
            let total = values.reduce(Float.zero, +)
            return ChromaVector(
                timestamp: Double(index) * 0.1,
                values: values.map { $0 / total }
            )
        }
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

    func testNormalFinalLinesWithLongOutroAreKept() {
        // Settle Down regression: unique multi-word closing lines followed by a long
        // instrumental outro. The old geometric heuristic cut everything after the
        // second-to-last line; degenerate-tail + VAD corroboration must keep them.
        let lines = [
            sentenceSegment("Build a little house with a front porch swing", start: 209.9),
            sentenceSegment("Sit all day together and listen to the birds sing", start: 215.3),
            sentenceSegment("I never thought I'd want to hang around", start: 220.8),
            sentenceSegment("She makes me want to settle down", start: 226.8),
        ]
        let pruned = TrailingLyricTailPruner.pruned(
            lines, lastVoicedEnd: 230.3, vocalOffset: 230.3, sourceDuration: 257.1)
        XCTAssertEqual(pruned.count, 4)

        XCTAssertNil(
            TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail(
                lines, sourceDuration: 257.1),
            "unique multi-word tail lines are real lyrics, not instrumental-tail junk")
    }

    func testRepeatedOutroHookKeptWhenVADSaysVoiced() {
        // Key West regression: the hook repeats through a sung outro. Geometry flags the
        // repeats as a degenerate tail, but the VAD says vocals continue well past the
        // proposed cutoff — the signal wins and the outro is kept.
        let lines = [
            sentenceSegment("Where friends come from near and far", start: 203.2),
            sentenceSegment("Yeah I need a break in the Key West bar", start: 207.3),
            sentenceSegment("Yeah I need a break in the Key West bar", start: 213.8),
            sentenceSegment("Yeah I need a break in the Key West bar", start: 222.2),
        ]
        let pruned = TrailingLyricTailPruner.pruned(
            lines, lastVoicedEnd: 228.8, vocalOffset: 228.8, sourceDuration: 231.0)
        XCTAssertEqual(pruned.count, 4)
    }

    func testDegenerateBlipTailStillCutWithVADAgreement() {
        // The case the pruner exists for: short "I" blips stranded right after the last
        // real line, with the VAD agreeing vocals ended at the body. Geometry detects the
        // junk tail and the signal cutoff removes it.
        let body = sentenceSegment("And under the stars it feels so right", start: 104.3)
        let blip1 = sentenceSegment("I", start: body.end)
        let blip2 = sentenceSegment("I", start: body.end + 1.7)
        XCTAssertNotNil(
            TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail(
                [body, blip1, blip2], sourceDuration: 158.7))
        let pruned = TrailingLyricTailPruner.pruned(
            [body, blip1, blip2],
            lastVoicedEnd: body.end, vocalOffset: body.end, sourceDuration: 158.7)
        XCTAssertEqual(pruned.map(\.text), [body.text])
    }

    func testChordOnsetAlignerSnapRefusesToCreateSubBeatSliver() {
        // Two genuine one-beat-apart changes; an onset sits just before the SECOND event
        // such that snapping would compress the pair to 0.2s (< 0.8 beat at 0.5s/beat).
        // With the beat grid provided, the second event must keep its decoder time.
        let events = [
            EditableChordEvent(time: 2.0, chord: "A", confidence: 0.8),
            EditableChordEvent(time: 2.5, chord: "D", confidence: 0.8),
        ]
        let beats = (0...10).map { TimeInterval($0) * 0.5 }
        let snapped = ChordOnsetAligner.snap(
            events, toOnsets: [2.0, 2.2], tolerance: 0.35, beatTimes: beats)
        XCTAssertEqual(snapped[0].time, 2.0, accuracy: 0.000_001)
        XCTAssertEqual(snapped[1].time, 2.5, accuracy: 0.000_001)
        // Without the beat grid the old compressing behavior remains (documented).
        let compressed = ChordOnsetAligner.snap(events, toOnsets: [2.0, 2.2], tolerance: 0.35)
        XCTAssertEqual(compressed[1].time, 2.2, accuracy: 0.000_001)
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

    func testDrumBeatGridKeepsTheMetronomeRigidWhenKickHitsAreJitteredAndSparse() {
        // A kick often supplies every other beat. Its onsets are useful phase evidence, but
        // must never pull individual metronome ticks early or late.
        let kicks: [TimeInterval] = [0.51, 1.47, 2.53, 3.48]
        let beats = DrumBeatGrid.beatTimes(onsets: kicks, bpm: 120, duration: 4)

        XCTAssertGreaterThan(beats.count, 5)
        for (previous, next) in zip(beats, beats.dropFirst()) {
            XCTAssertEqual(next - previous, 0.5, accuracy: 1e-9)
        }
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

    func testVocalWordOnsetAlignerNeverStacksTwoWordsOnTheSameOnset() {
        // Regression: BOTH words snap to the identical nearest onset (0.90) — a plain
        // "nondecreasing" floor previously let the second word land at EXACTLY the first
        // word's time (0.90 == 0.90), stacking their anchors and inflating onset-corroboration
        // scores for candidates whose words bunch near one energy burst. Every word's onset
        // must now be STRICTLY later than the previous one.
        let segment = TimedLyricSegment(
            start: 1.0, end: 1.9, text: "a b",
            words: [
                TimedLyricWord(text: "a", start: 1.00, end: 1.40, characterRange: 0..<1),
                TimedLyricWord(text: "b", start: 1.50, end: 1.90, characterRange: 2..<3),
            ])
        let out = VocalWordOnsetAligner.snapped(
            [segment], toOnsets: [0.90], tolerance: 0.7)
        XCTAssertGreaterThan(out[0].words[1].start, out[0].words[0].start)
    }

    func testVocalWordOnsetAlignerDoesNotFabricateMicroOnsetsFromOneBurst() {
        // Field shape: one vocal energy burst falls within the correction window for two words.
        // The old clamp snapped both to that burst, then fabricated a second start 20 ms later.
        let segment = TimedLyricSegment(
            start: 1.0, end: 1.9, text: "a b",
            words: [
                TimedLyricWord(text: "a", start: 1.00, end: 1.40, characterRange: 0..<1),
                TimedLyricWord(text: "b", start: 1.50, end: 1.90, characterRange: 2..<3),
            ])

        let out = VocalWordOnsetAligner.snapped(
            [segment], toOnsets: [0.90], tolerance: 0.7)

        XCTAssertEqual(out[0].words[0].start, 0.90, accuracy: 1e-9)
        XCTAssertEqual(
            out[0].words[1].start, 1.50, accuracy: 1e-9,
            "without a second distinct vocal onset, preserve the second ASR start")
    }

    func testVocalWordOnsetAlignerUsesDistinctSupportedOnsets() {
        // Both words are closest to 1.04, but the second also has a distinct supported onset at
        // 1.18. Use both real bursts instead of manufacturing 1.06 from minimumWordGap.
        let segment = TimedLyricSegment(
            start: 1.0, end: 1.6, text: "go now",
            words: [
                TimedLyricWord(text: "go", start: 1.00, end: 1.30, characterRange: 0..<2),
                TimedLyricWord(text: "now", start: 1.08, end: 1.60, characterRange: 3..<6),
            ])

        let out = VocalWordOnsetAligner.snapped(
            [segment], toOnsets: [1.04, 1.18], tolerance: 0.15)

        XCTAssertEqual(out[0].words.map(\.start), [1.04, 1.18])
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

    // MARK: - LineTailSustainExtender (line-final held notes)

    private func heldTailLines() -> [TimedLyricSegment] {
        [
            TimedLyricSegment(
                start: 10.0, end: 11.0, text: "one two",
                words: [
                    TimedLyricWord(text: "one", start: 10.0, end: 10.4, characterRange: 0..<3),
                    TimedLyricWord(text: "two", start: 10.5, end: 11.0, characterRange: 4..<7),
                ]),
            TimedLyricSegment(
                start: 14.0, end: 15.0, text: "three",
                words: [
                    TimedLyricWord(text: "three", start: 14.0, end: 15.0, characterRange: 0..<5)
                ]),
        ]
    }

    func testLineTailSustainExtendsHeldLastWordToEndOfSungInterval() {
        // Whisper ended the held "two" at 11.0 while the voice sings on to 12.6.
        let out = LineTailSustainExtender.extended(
            heldTailLines(), sungIntervals: [9.9...12.6, 13.9...15.2])
        XCTAssertEqual(out[0].words[1].end, 12.6, accuracy: 1e-9)
        XCTAssertEqual(out[0].end, 12.6, accuracy: 1e-9)
        XCTAssertEqual(out[0].words[1].start, 10.5, accuracy: 1e-9)
        XCTAssertEqual(out[1].words[0].end, 15.2, accuracy: 1e-9)
    }

    func testLineTailSustainStopsBeforeNextLineAndAtMaximum() {
        // One sung interval runs into the next line: stop just short of its first word.
        let out = LineTailSustainExtender.extended(heldTailLines(), sungIntervals: [9.9...20.0])
        XCTAssertEqual(out[0].words[1].end, 13.95, accuracy: 1e-9)
        // The last line has no next line; the maximum extension bounds it instead.
        XCTAssertEqual(out[1].words[0].end, 19.0, accuracy: 1e-9)
    }

    func testLineTailSustainLeavesUnsungTailsAlone() {
        let lines = heldTailLines()
        // The voice stopped before the word's end.
        XCTAssertEqual(LineTailSustainExtender.extended(lines, sungIntervals: [9.9...10.9]), lines)
        // The voice re-enters after a real pause; that later interval is not the held note.
        XCTAssertEqual(LineTailSustainExtender.extended(lines, sungIntervals: [11.3...12.0]), lines)
        XCTAssertEqual(LineTailSustainExtender.extended(lines, sungIntervals: []), lines)
    }

    // MARK: - TranscriptionVoicedCoverage (whisper decode-collapse detection)

    private func coverageResult(_ spans: [(Double, Double)]) -> TranscriptionResult {
        TranscriptionResult(
            text: "",
            languageCode: nil,
            sourceDuration: 226,
            completedAt: Date(timeIntervalSince1970: 0),
            // Coverage counts words, not segment spans: one short word every half second.
            segments: spans.map { span in
                TimedTranscriptionSegment(
                    text: "x", startTime: span.0, endTime: span.1,
                    tokens: stride(from: span.0, to: span.1, by: 0.5).map {
                        TimedTranscriptionToken(
                            text: "la", startTime: $0, endTime: min($0 + 0.5, span.1),
                            confidence: 0.9)
                    },
                    confidence: 0.9)
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
        // Two fully-overlapping 50s segments must count once (0.5 plus the last word's 0.25 s
        // padding), not twice.
        let overlapping = coverageResult([(0, 50), (0, 50)])
        XCTAssertEqual(
            TranscriptionVoicedCoverage.fraction(of: overlapping, voicedIntervals: voiced) ?? 0,
            0.5025, accuracy: 1e-9)
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

    // MARK: - Merged onsets across chordal stems

    func testMergedOnsetsCombinesEveryStemAndDeduplicates() throws {
        // Two stems that attack at the SAME moment plus one that attacks alone. The shared
        // attack must count once; the solo attack must not be lost — which is exactly what the
        // old first-stem-wins selection did to a piano-only chord change.
        let sampleRate = 8_000.0
        let shared = try writeBurstWAV(atSeconds: [0.1], sampleRate: sampleRate)
        let sharedPlusSolo = try writeBurstWAV(atSeconds: [0.1, 1.2], sampleRate: sampleRate)
        defer {
            for url in [shared, sharedPlusSolo] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let single = try InstrumentOnsetDetector.onsets(url: shared)
        let merged = InstrumentOnsetDetector.mergedOnsets(urls: [shared, sharedPlusSolo])

        XCTAssertEqual(single.count, 1, "one stem hears one attack")
        XCTAssertEqual(merged.count, 2, "the second stem's solo attack is picked up, once")
        XCTAssertEqual(merged, merged.sorted(), "merged onsets are in time order")
    }

    func testMergedOnsetsIsEmptyForNoStems() {
        XCTAssertTrue(InstrumentOnsetDetector.mergedOnsets(urls: []).isEmpty)
    }

    /// A WAV of silence with a short loud burst at each of `seconds`.
    private func writeBurstWAV(
        atSeconds seconds: [Double],
        sampleRate: Double,
        duration: Double = 2
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) { channel[frame] = 0 }
        for second in seconds {
            let start = Int(second * sampleRate)
            for offset in 0..<Int(sampleRate * 0.05) where start + offset < Int(frameCount) {
                channel[start + offset] = offset.isMultiple(of: 2) ? 0.9 : -0.9
            }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: - Onset threshold adapts to local dynamics

    func testQuietPassageAttacksAreFoundAlongsideALoudChorus() throws {
        // The failure this fixes: one global gate at 10% of the loudest frame in the FILE meant a
        // verse well below the chorus cleared no threshold at all — zero onsets across the whole
        // quiet passage, and `ChordEvidenceAudit` then deleted those chords as unsupported.
        let sampleRate = 8_000.0
        let url = try writeTwoLevelBurstWAV(
            loudSeconds: [0.2, 0.7], quietSeconds: [2.2, 2.7],
            quietGain: 0.06, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }

        let onsets = try InstrumentOnsetDetector.onsets(url: url)
        let quiet = onsets.filter { $0 > 1.8 }
        let loud = onsets.filter { $0 < 1.8 }
        XCTAssertGreaterThanOrEqual(loud.count, 2, "loud attacks must still be found")
        XCTAssertGreaterThanOrEqual(
            quiet.count, 2,
            "attacks 24 dB down must be found too — got \(onsets)")
    }

    func testAdaptiveThresholdsTrackEachBlockSeparately() {
        // A loud block then a quiet one: the quiet block's threshold must fall with it.
        let loud = [Float](repeating: 0, count: 20) + [Float](repeating: 1.0, count: 20)
        let quiet = [Float](repeating: 0, count: 20) + [Float](repeating: 0.01, count: 20)
        let thresholds = InstrumentOnsetDetector.adaptiveThresholds(
            flux: loud + quiet, blockHops: 40, multiplier: 2.5, absoluteFloor: 0.0001)
        XCTAssertGreaterThan(thresholds[30], thresholds[70], "quiet block gets a lower bar")
        XCTAssertGreaterThan(thresholds[70], 0, "but never zero")
    }

    func testAdaptiveThresholdsNeverFallBelowTheSilenceFloor() {
        let silence = [Float](repeating: 0, count: 100)
        let thresholds = InstrumentOnsetDetector.adaptiveThresholds(
            flux: silence, blockHops: 50, multiplier: 2.5, absoluteFloor: 0.25)
        XCTAssertTrue(thresholds.allSatisfy { $0 >= 0.25 })
    }

    /// Silence with loud bursts at `loudSeconds` and `quietGain`-scaled bursts at `quietSeconds`.
    private func writeTwoLevelBurstWAV(
        loudSeconds: [Double],
        quietSeconds: [Double],
        quietGain: Float,
        sampleRate: Double,
        duration: Double = 3.5
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) { channel[frame] = 0 }
        for (seconds, gain) in [(loudSeconds, Float(0.9)), (quietSeconds, 0.9 * quietGain)] {
            for second in seconds {
                let start = Int(second * sampleRate)
                for offset in 0..<Int(sampleRate * 0.08) where start + offset < Int(frameCount) {
                    channel[start + offset] = offset.isMultiple(of: 2) ? gain : -gain
                }
            }
        }
        try file.write(from: buffer)
        return url
    }
}

/// Pitch-salience singing detection (`VocalPitchSalience`) — the RC-4 evidence signal.
/// The contract that matters: QUIET pitched singing is detected (the doo-doo intro the
/// energy VAD missed) and loud UNPITCHED residue is not (the bleed the energy VAD flagged).
final class VocalPitchSalienceTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Voice-like tone: fundamental plus a few harmonics, with slight vibrato so it is not
    /// suspiciously pure.
    private func voiceSamples(
        seconds: Double, amplitude: Float, fundamental: Double = 220
    ) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            let f = fundamental * (1 + 0.01 * sin(2 * .pi * 5 * t))
            let v =
                sin(2 * .pi * f * t) + 0.5 * sin(2 * .pi * 2 * f * t)
                + 0.25 * sin(2 * .pi * 3 * f * t)
            return amplitude * Float(v / 1.75)
        }
    }

    /// Deterministic broadband noise (linear congruential), the shape of separation residue.
    private func noiseSamples(seconds: Double, amplitude: Float) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<Int(seconds * sampleRate)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            return amplitude * (unit * 2 - 1)
        }
    }

    func testQuietSingingIsDetectedAndLoudResidueIsNot() {
        // 1s silence · 1.5s QUIET voice · 1.5s LOUD noise: exactly the two failure modes.
        let samples =
            noiseSamples(seconds: 1.0, amplitude: 0.0005)
            + voiceSamples(seconds: 1.5, amplitude: 0.05)
            + noiseSamples(seconds: 1.5, amplitude: 0.5)
        let sung = VocalPitchSalience.sungIntervals(samples: samples, sampleRate: sampleRate)
        XCTAssertFalse(sung.isEmpty, "quiet pitched singing must be detected")
        // Everything detected lies in the voice span; nothing in the loud noise span.
        for interval in sung {
            XCTAssertGreaterThan(interval.upperBound, 0.9)
            XCTAssertLessThan(interval.lowerBound, 2.6)
        }
        XCTAssertFalse(
            sung.contains { $0.lowerBound > 2.6 },
            "loud unpitched residue must not read as singing")
    }

    func testSilenceProducesNothing() {
        let sung = VocalPitchSalience.sungIntervals(
            samples: [Float](repeating: 0, count: 44_100 * 3), sampleRate: sampleRate)
        XCTAssertTrue(sung.isEmpty)
    }
}

// MARK: - Pitch evidence protects soft singing from the energy gate

extension AudioAnalysisTests {
    func testHallucinationGateKeepsPitchSupportedLineTheEnergyVADMissed() {
        let body = sentenceSegment("verse line here", start: 10)
        let soft = sentenceSegment("doo doo da", start: 30)
        let energy: [ClosedRange<TimeInterval>] = [9.5...13.0]

        XCTAssertEqual(
            VocalHallucinationGate.filtered([body, soft], voicedIntervals: energy).map(\.text),
            ["verse line here"])
        XCTAssertEqual(
            VocalHallucinationGate.filtered(
                [body, soft], voicedIntervals: energy, sungIntervals: [29.8...32.0]
            ).map(\.text),
            ["verse line here", "doo doo da"])
    }

    func testHallucinationGateDropsALineBothEnergyAndPitchReject() {
        let stray = sentenceSegment("thank you", start: 60)
        XCTAssertEqual(
            VocalHallucinationGate.filtered(
                [stray], voicedIntervals: [9.5...13.0], sungIntervals: [20.0...25.0]
            ).count, 0)
    }

    func testTailCutoffMovesPastPitchedSingingOnly() {
        XCTAssertEqual(
            VocalHallucinationGate.pitchExtended(50, sungIntervals: [10...20, 55...58]), 58)
        XCTAssertEqual(VocalHallucinationGate.pitchExtended(50, sungIntervals: [10...20]), 50)
        XCTAssertEqual(VocalHallucinationGate.pitchExtended(50, sungIntervals: []), 50)
        XCTAssertNil(VocalHallucinationGate.pitchExtended(nil, sungIntervals: [55...58]))
    }
}

// MARK: - Adjacent lines never overlap

extension AudioAnalysisTests {
    func testOverlappingAdjacentLinesClipOnlyTheEarlierLinesEnds() {
        let first = TimedLyricSegment(
            start: 30.32, end: 35.00, text: "held note",
            words: [
                TimedLyricWord(text: "held", start: 30.32, end: 34.49, characterRange: 0..<4),
                TimedLyricWord(text: "note", start: 34.49, end: 35.00, characterRange: 5..<9),
            ])
        let second = TimedLyricSegment(
            start: 34.93, end: 36, text: "next",
            words: [TimedLyricWord(text: "next", start: 34.93, end: 36, characterRange: 0..<4)])

        let clipped = LyricLineOverlapClipper.clipped([second, first])

        XCTAssertEqual(clipped.map(\.text), ["held note", "next"])
        XCTAssertEqual(clipped[0].end, 34.93, accuracy: 1e-9)
        XCTAssertEqual(clipped[0].words.map(\.start), [30.32, 34.49])
        XCTAssertEqual(clipped[0].words.last?.end ?? 0, 34.93, accuracy: 1e-9)
        XCTAssertEqual(clipped[1], second)
    }
}
