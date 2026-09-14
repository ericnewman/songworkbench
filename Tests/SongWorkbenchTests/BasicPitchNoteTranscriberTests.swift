import Foundation
import XCTest

@testable import SongWorkbench

final class BasicPitchNoteTranscriberTests: XCTestCase {
    private let bins = BasicPitchNoteTranscriber.noteBins

    /// Synthetic posteriors: `frameCount` frames, 11.6 ms apart, all zero unless painted.
    private func blank(frameCount: Int) -> (note: [Float], onset: [Float], times: [TimeInterval]) {
        (
            [Float](repeating: 0, count: frameCount * bins),
            [Float](repeating: 0, count: frameCount * bins),
            (0..<frameCount).map { Double($0) * 256 / 22050 }
        )
    }

    private func posteriors(
        frameCount: Int, note: [Float], onset: [Float], times: [TimeInterval]
    ) -> BasicPitchPosteriors {
        BasicPitchPosteriors(
            frameCount: frameCount, frameTimes: times, note: note, onset: onset, contour: [])
    }

    func testDecodesAnOnsetLedNoteWithItsFrameSpan() {
        var (note, onset, times) = blank(frameCount: 200)
        let bin = 69 - BasicPitchNoteTranscriber.midiOffset
        for frame in 20..<80 { note[frame * bins + bin] = 0.8 }
        onset[19 * bins + bin] = 0.2
        onset[20 * bins + bin] = 0.9
        onset[21 * bins + bin] = 0.2
        let events = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 200, note: note, onset: onset, times: times),
            inferOnsets: false, melodiaTrick: false)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.midiNote, 69)
        XCTAssertEqual(events.first?.onset ?? -1, times[20], accuracy: 1e-9)
        XCTAssertEqual(events.first?.offset ?? -1, times[80], accuracy: 1e-9)
        XCTAssertEqual(events.first?.confidence ?? 0, 0.8, accuracy: 1e-5)
        XCTAssertNil(events.first?.pitchBendSemitones)  // no contour given
    }

    func testRejectsNotesShorterThanTheMinimumAndBelowTheOnsetThreshold() {
        var (note, onset, times) = blank(frameCount: 100)
        let bin = 60 - BasicPitchNoteTranscriber.midiOffset
        for frame in 10..<16 { note[frame * bins + bin] = 0.9 }  // 6 frames < 11
        onset[10 * bins + bin] = 0.9
        let short = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 100, note: note, onset: onset, times: times),
            inferOnsets: false, melodiaTrick: false)
        XCTAssertTrue(short.isEmpty)

        (note, onset, times) = blank(frameCount: 100)
        for frame in 10..<60 { note[frame * bins + bin] = 0.9 }
        onset[10 * bins + bin] = 0.4  // below 0.5
        let quiet = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 100, note: note, onset: onset, times: times),
            inferOnsets: false, melodiaTrick: false)
        XCTAssertTrue(quiet.isEmpty)
    }

    func testMelodiaTrickRecoversANoteWithoutAnOnset() {
        let (blankNote, onset, times) = blank(frameCount: 200)
        var note = blankNote
        let bin = 64 - BasicPitchNoteTranscriber.midiOffset
        for frame in 100..<150 { note[frame * bins + bin] = 0.7 }
        let without = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 200, note: note, onset: onset, times: times),
            inferOnsets: false, melodiaTrick: false)
        XCTAssertTrue(without.isEmpty)
        let with = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 200, note: note, onset: onset, times: times),
            inferOnsets: false, melodiaTrick: true)
        XCTAssertEqual(with.count, 1)
        XCTAssertEqual(with.first?.midiNote, 64)
        XCTAssertEqual(with.first?.onset ?? -1, times[100], accuracy: 1e-9)
        // The melodia pass ends one frame early (`i_end = i - 1 - k`), as in the original.
        XCTAssertEqual(with.first?.offset ?? -1, times[149], accuracy: 1e-9)
    }

    func testInferredOnsetsTurnAFramePosteriorJumpIntoAnOnset() {
        let (blankNote, onset, times) = blank(frameCount: 200)
        var note = blankNote
        let bin = 57 - BasicPitchNoteTranscriber.midiOffset
        for frame in 30..<90 { note[frame * bins + bin] = 0.9 }
        // No onset head activity at all; the jump at frame 30 must be inferred (and rescaled
        // to the onset head's maximum — which is 0 here, so give it one weak blip to scale to).
        var onsets = onset
        onsets[150 * bins + 10] = 0.6
        let events = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 200, note: note, onset: onsets, times: times),
            inferOnsets: true, melodiaTrick: false)
        XCTAssertEqual(events.map(\.midiNote), [57])
        XCTAssertEqual(events.first?.onset ?? -1, times[30], accuracy: 1e-9)
    }

    func testTwoSimultaneousNotesStaySeparate() {
        var (note, onset, times) = blank(frameCount: 200)
        for midi in [60, 67] {
            let bin = midi - BasicPitchNoteTranscriber.midiOffset
            for frame in 20..<80 { note[frame * bins + bin] = 0.8 }
            onset[20 * bins + bin] = 0.9
        }
        let events = BasicPitchNoteDecoder.decode(
            posteriors(frameCount: 200, note: note, onset: onset, times: times),
            inferOnsets: false, melodiaTrick: false)
        XCTAssertEqual(events.map(\.midiNote), [60, 67])
    }

    // MARK: - Model

    private static func repoModelURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/nmp.onnx")
    }

    private func sine(midi: Int, seconds: Double, sampleRate: Double) -> [Float] {
        let hz = 440 * pow(2, Double(midi - 69) / 12)
        return (0..<Int(seconds * sampleRate)).map {
            0.5 * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate))
        }
    }

    func testBundledModelTranscribesA440SineAsMIDI69() throws {
        let transcriber = try BasicPitchNoteTranscriber(modelURL: Self.repoModelURL())
        let events = try transcriber.transcribe(
            samples: sine(midi: 69, seconds: 2, sampleRate: 22050), sampleRate: 22050)
        let longest = try XCTUnwrap(events.max { $0.duration < $1.duration })
        XCTAssertEqual(longest.midiNote, 69)
        XCTAssertGreaterThan(longest.duration, 1.5)
        XCTAssertLessThan(longest.onset, 0.1)
        XCTAssertGreaterThan(longest.confidence, 0.5)
    }

    func testTwoNoteSequenceAt44100HzYieldsTwoEventsInOrder() throws {
        let transcriber = try BasicPitchNoteTranscriber(modelURL: Self.repoModelURL())
        let samples =
            sine(midi: 69, seconds: 1, sampleRate: 44100)
            + sine(midi: 72, seconds: 1, sampleRate: 44100)
        let events = try transcriber.transcribe(samples: samples, sampleRate: 44100)
        // Keep the notes that carry the sound; octave ghosts of a pure sine are short and weak.
        let main = events.filter { $0.duration > 0.5 }.sorted { $0.onset < $1.onset }
        XCTAssertEqual(main.map(\.midiNote), [69, 72])
        XCTAssertLessThan(main[0].onset, 0.1)
        XCTAssertEqual(main[1].onset, 1.0, accuracy: 0.1)
        XCTAssertEqual(main[0].offset, 1.0, accuracy: 0.15)
    }

    func testResamplerHalvesTheSampleCount() throws {
        let out = try BasicPitchNoteTranscriber.resampled(
            [Float](repeating: 0.25, count: 44100), from: 44100)
        XCTAssertEqual(out.count, 22050, accuracy: 30)
    }

    // MARK: - Document

    func testNoteEventsRoundTripAndAreNilOnOlderDocuments() throws {
        let timeline = NoteEventTimeline(
            stemID: StemID(.guitar),
            events: [
                NoteEvent(
                    onset: 1, offset: 1.5, midiNote: 64, confidence: 0.7, pitchBendSemitones: 0.1),
                NoteEvent(
                    onset: 0.5, offset: 0.9, midiNote: 60, confidence: 0.6, pitchBendSemitones: nil),
            ])
        XCTAssertEqual(timeline.events.map(\.midiNote), [60, 64])  // sorted by onset
        XCTAssertTrue(timeline.isCurrent)
        let document = SongAnalysisDocument(estimatedBPM: 100, noteEvents: [timeline])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SongAnalysisDocument.self, from: data)
        XCTAssertEqual(decoded.noteEvents, [timeline])
        let older = try JSONDecoder().decode(
            SongAnalysisDocument.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        XCTAssertNil(older.noteEvents)
        XCTAssertFalse(NoteTranscriptionPass.isCurrent(for: older))
    }
}
