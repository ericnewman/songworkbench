import XCTest

@testable import SongWorkbench

final class BassLineAnalyzerTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// Builds a mono sine buffer at `frequency` for `duration` seconds.
    private func sine(frequency: Double, duration: Double, amplitude: Float = 0.7) -> [Float] {
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            samples[index] = amplitude * Float(sin(phase))
        }
        return samples
    }

    func testDetectsA2From110HzTone() {
        let observations = BassLineAnalyzer().analyze(
            samples: sine(frequency: 110, duration: 1.5),
            sampleRate: sampleRate
        )
        let note = try? XCTUnwrap(observations.first)
        XCTAssertEqual(note?.midiNote ?? 0, 45, accuracy: 1)  // A2
    }

    func testDetectsE2From82HzTone() {
        let observations = BassLineAnalyzer().analyze(
            samples: sine(frequency: 82.41, duration: 1.5),
            sampleRate: sampleRate
        )
        let note = try? XCTUnwrap(observations.first)
        XCTAssertEqual(note?.midiNote ?? 0, 40, accuracy: 1)  // E2
    }

    func testDetectsVeryQuietToneViaPeakNormalization() {
        // A very low-amplitude bass tone (a quiet separated stem) would fall under the
        // silence floor without normalization; after peak normalization it's detected.
        let note = BassLineAnalyzer().analyze(
            samples: sine(frequency: 110, duration: 1.5, amplitude: 0.002),
            sampleRate: sampleRate
        ).first
        XCTAssertEqual(note?.midiNote ?? 0, 45, accuracy: 1)  // A2
    }

    func testSilenceProducesNoObservations() {
        let silence = [Float](repeating: 0, count: Int(sampleRate * 1.5))
        let observations = BassLineAnalyzer().analyze(
            samples: silence,
            sampleRate: sampleRate
        )
        XCTAssertTrue(observations.isEmpty)
    }

    func testTwoToneSequenceProducesTwoSegmentsInOrder() {
        var samples = sine(frequency: 110, duration: 1.0)  // A2 / midi 45
        samples.append(contentsOf: sine(frequency: 146.83, duration: 1.0))  // D3 / midi 50
        let observations = BassLineAnalyzer().analyze(
            samples: samples,
            sampleRate: sampleRate
        )

        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.first?.midiNote ?? 0, 45, accuracy: 1)
        XCTAssertEqual(observations.last?.midiNote ?? 0, 50, accuracy: 1)
        if observations.count == 2 {
            XCTAssertLessThan(observations[0].timestamp, observations[1].timestamp)
        }
    }

    func testNoteNamingMapsPitchClass() {
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 45), "A")  // A2
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 40), "E")  // E2
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 50), "D")  // D3
        XCTAssertEqual(BassNoteNaming.name(forMidiNote: 49), "C#")  // C#3
    }

    func testBorderlineBassNoteSnapsToTheConcurrentChordTone() {
        // Pitch 45.42 rounded to A (45) against a Bb chord — a clash — but the fraction
        // leans well toward Bb (46), a chord tone within the flip distance: snap to Bb.
        let borderline = BassNoteObservation(
            timestamp: 10, midiNote: 45, confidence: 0.8, pitch: 45.42)
        // Pitch 45.08 is a DECISIVE A: even though A clashes with Bb, no flip.
        let decisive = BassNoteObservation(
            timestamp: 12, midiNote: 45, confidence: 0.8, pitch: 45.08)
        // Legacy observation without fractional pitch: untouched.
        let legacy = BassNoteObservation(timestamp: 14, midiNote: 45, confidence: 0.8)
        let chords = [EditableChordEvent(time: 0, chord: "Bb", confidence: 0.9)]

        let snapped = BassChordReconciler.snapped([borderline, decisive, legacy], chords: chords)

        XCTAssertEqual(snapped.map(\.midiNote), [46, 45, 45])
    }

    func testChordToneAndChromaticBassNotesAreNeverFlipped() {
        // Already a chord tone (D over Bb = the third): stays, even with a leaning fraction.
        let third = BassNoteObservation(
            timestamp: 10, midiNote: 50, confidence: 0.8, pitch: 50.4)
        // Clash whose alternative is ALSO not a chord tone: stays (genuine chromatic note).
        let chromatic = BassNoteObservation(
            timestamp: 12, midiNote: 44, confidence: 0.8, pitch: 44.45)
        let chords = [EditableChordEvent(time: 0, chord: "Bb", confidence: 0.9)]

        let snapped = BassChordReconciler.snapped([third, chromatic], chords: chords)

        XCTAssertEqual(snapped.map(\.midiNote), [50, 44])
    }

    func testChordToneParsingHandlesQualitiesAndFlats() {
        XCTAssertEqual(BassChordReconciler.chordTonePitchClasses("Bb"), [10, 2, 5])
        XCTAssertEqual(BassChordReconciler.chordTonePitchClasses("Ebm7"), [3, 6, 10, 1])
        XCTAssertEqual(BassChordReconciler.chordTonePitchClasses("Cmaj7"), [0, 4, 7, 11])
        XCTAssertEqual(BassChordReconciler.chordTonePitchClasses("C7"), [0, 4, 7, 10])
        XCTAssertNil(BassChordReconciler.chordTonePitchClasses("?"))
    }

    func testDetunedRecordingKeepsAConsistentSemitoneGrid() {
        // A recording tuned ~half of a semitone sharp: naive per-note rounding flips notes
        // near the 50-cent boundary to the wrong semitone while leaving others alone — the
        // source of the ±1-semitone bass-vs-chord clashes (field-measured 24-43% clash
        // rate). With the global tuning-offset pass, BOTH notes land on one consistent
        // grid: A2 (45) → D3 (50), a perfect fourth — never 45 → 51.
        let sharp40 = 110.0 * pow(2, 0.40 / 12)  // A2 +40 cents
        let sharp55 = 146.83 * pow(2, 0.55 / 12)  // D3 +55 cents (naively rounds UP)
        var samples = sine(frequency: sharp40, duration: 1.0)
        samples.append(contentsOf: sine(frequency: sharp55, duration: 1.0))

        let observations = BassLineAnalyzer().analyze(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(observations.count, 2)
        let interval = (observations.last?.midiNote ?? 0) - (observations.first?.midiNote ?? 0)
        XCTAssertEqual(interval, 5, "the played fourth must survive detuning")
        XCTAssertEqual(observations.first?.midiNote ?? 0, 45, accuracy: 1)
    }
}
