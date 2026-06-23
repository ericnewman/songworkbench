import XCTest

@testable import SongWorkbench

final class HarmonyAudioSourceTests: XCTestCase {
    func testSelectsOtherStemAndNeverVocalsWhenStemsExist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            other: directory.appendingPathComponent("other.wav")
        )
        try Data().write(to: stems.other)

        let source = try HarmonyAudioSourceSelector().select(
            recordingURL: directory.appendingPathComponent("recording.wav"),
            stems: stems,
            allowsRecordingFallback: false
        )

        XCTAssertEqual(source.url, stems.other)
        XCTAssertNotEqual(source.url, stems.vocals)
        XCTAssertEqual(source.kind, .accompanimentStem)
    }

    func testStandaloneAnalysisRequiresAccompanimentButPipelineMayDeclareFallback() throws {
        let recording = URL(fileURLWithPath: "/tmp/recording.wav")
        XCTAssertThrowsError(
            try HarmonyAudioSourceSelector().select(
                recordingURL: recording,
                stems: nil,
                allowsRecordingFallback: false
            )
        ) { error in
            XCTAssertEqual(error as? HarmonyAudioSourceError, .missingAccompanimentStem)
        }

        let fallback = try HarmonyAudioSourceSelector().select(
            recordingURL: recording,
            stems: nil,
            allowsRecordingFallback: true
        )
        XCTAssertEqual(fallback.url, recording)
        XCTAssertEqual(fallback.kind, .recording)
        XCTAssertEqual(fallback.configurationIdentifier, "full-mix-fallback")
    }

    func testSixSourceSetUsesGuitarPianoOtherComposite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let composite = directory.appendingPathComponent("accompaniment.wav")
        try Data().write(to: composite)
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            guitar: directory.appendingPathComponent("guitar.wav"),
            piano: directory.appendingPathComponent("piano.wav"),
            other: directory.appendingPathComponent("other.wav"),
            accompaniment: composite
        )

        let source = try HarmonyAudioSourceSelector().select(
            recordingURL: directory.appendingPathComponent("recording.wav"),
            stems: stems,
            allowsRecordingFallback: false
        )

        XCTAssertEqual(source.url, composite)
        XCTAssertEqual(source.configurationIdentifier, "accompaniment-guitar-piano-other")
    }
}
