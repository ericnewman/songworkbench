import AVFoundation
import XCTest

@testable import SongWorkbench

final class MIDIRenditionTests: XCTestCase {
    func testEachStemPlaysAsItsTrackTypeAndTheWholeDrumsStemHasNoRendition() {
        XCTAssertEqual(MIDIInstrumentCategory.category(for: .vocalLead), .vocals)
        XCTAssertEqual(
            MIDIInstrumentCategory.category(for: VoiceTrackPass.stemID(forVoice: 2)), .voices)
        XCTAssertEqual(MIDIInstrumentCategory.category(for: StemKind.bass.id), .bass)
        XCTAssertEqual(MIDIInstrumentCategory.category(for: StemKind.guitar.id), .guitar)
        XCTAssertEqual(MIDIInstrumentCategory.category(for: StemKind.piano.id), .piano)
        XCTAssertEqual(MIDIInstrumentCategory.category(for: .drumKick), .drums)
        // Only the separated drum pieces map to GM drums (Eric: "if multi-track drums are enabled").
        XCTAssertNil(MIDIInstrumentCategory.category(for: StemKind.drums.id))
    }

    func testDrumPiecesUseTheGeneralMIDIPercussionKeys() {
        XCTAssertEqual(GMDrumMap.note(for: .drumKick), 36)
        XCTAssertEqual(GMDrumMap.note(for: .drumSnare), 38)
        XCTAssertEqual(GMDrumMap.note(for: .drumToms), 45)
        XCTAssertEqual(GMDrumMap.note(for: .drumCymbals), 42)
        XCTAssertEqual(GeneralMIDI.programNames.count, 128)
    }

    func testABassRenditionDropsOvertonesHeardAsHighNotes() {
        let notes = [40, 52, 77].map {
            RenditionNote(start: 0, end: 1, midiNote: $0, velocity: 100)
        }
        XCTAssertEqual(MIDIInstrumentCategory.bass.playable(notes).map(\.midiNote), [40, 52])
        XCTAssertEqual(MIDIInstrumentCategory.piano.playable(notes).count, 3)
    }

    func testADrumPieceBecomesOneHitPerAttack() {
        let sampleRate = 44_100.0
        var samples = [Float](repeating: 0, count: Int(sampleRate * 3))
        for hit in [0.5, 1.5, 2.5] {
            let start = Int(hit * sampleRate)
            for i in 0..<2_000 {
                samples[start + i] = Float(exp(-Double(i) / 300)) * (i % 2 == 0 ? 0.8 : -0.8)
            }
        }
        let hits = GMDrumMap.hits(samples: samples, sampleRate: sampleRate, note: 36)
        XCTAssertEqual(hits.count, 3)
        for (hit, expected) in zip(hits, [0.5, 1.5, 2.5]) {
            XCTAssertEqual(hit.start, expected, accuracy: 0.05)
            XCTAssertEqual(hit.midiNote, 36)
        }
    }

    func testTheMIDISwitchSurvivesASaveAndOldDocumentsDecodeWithoutIt() throws {
        var mixer = StemMixerModel()
        mixer.setPlaysMIDI(true, for: StemKind.bass.id)
        let decoded = try JSONDecoder().decode(
            StemMixerModel.self, from: JSONEncoder().encode(mixer))
        XCTAssertTrue(decoded[StemKind.bass.id].playsMIDI)
        XCTAssertFalse(decoded[StemKind.guitar.id].playsMIDI)
        let legacy = #"{"gain":1,"isMuted":false,"isSoloed":false,"pan":0}"#
        let state = try JSONDecoder().decode(StemMixState.self, from: Data(legacy.utf8))
        XCTAssertFalse(state.playsMIDI)
    }

    func testTheRendererSoundsOnlyWhereTheNotesAre() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: MIDIRenditionRenderer.soundBankURL.path),
            "needs the system General MIDI sound bank")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendition-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try MIDIRenditionRenderer.render(
            notes: [RenditionNote(start: 1, end: 1.5, midiNote: 60, velocity: 110)],
            program: 0, drumKit: false, duration: 3, sampleRate: 44_100, to: url)

        let (samples, rate) = try MonoSampleLoader.load(url: url)
        XCTAssertEqual(Double(samples.count) / rate, 3, accuracy: 0.01)
        func peak(_ range: ClosedRange<Double>) -> Float {
            samples[Int(range.lowerBound * rate)..<Int(range.upperBound * rate)].map(abs).max() ?? 0
        }
        XCTAssertLessThan(peak(0...0.9), 1e-4, "silent before the note")
        XCTAssertGreaterThan(peak(1.0...1.5), 0.01, "the note sounds")
    }
}
