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
        XCTAssertEqual(source.configurationIdentifier, "harmony-other-stem")
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

    func testSixSourceSetPrefersGuitarStemForHarmony() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let composite = directory.appendingPathComponent("accompaniment.wav")
        try Data().write(to: composite)
        let guitar = directory.appendingPathComponent("guitar.wav")
        try Data().write(to: guitar)
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            guitar: guitar,
            piano: directory.appendingPathComponent("piano.wav"),
            other: directory.appendingPathComponent("other.wav"),
            accompaniment: composite
        )
        try Data().write(to: stems.piano!)
        try Data().write(to: stems.other)

        let source = try HarmonyAudioSourceSelector().select(
            recordingURL: directory.appendingPathComponent("recording.wav"),
            stems: stems,
            allowsRecordingFallback: false
        )

        XCTAssertEqual(source.url, guitar)
        XCTAssertEqual(source.configurationIdentifier, "harmony-guitar-stem")
    }

    func testFallsBackToPianoThenAccompanimentThenOther() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let piano = directory.appendingPathComponent("piano.wav")
        let composite = directory.appendingPathComponent("accompaniment.wav")
        try Data().write(to: piano)
        try Data().write(to: composite)
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            piano: piano,
            other: directory.appendingPathComponent("other.wav"),
            accompaniment: composite
        )
        try Data().write(to: stems.other)

        let source = try HarmonyAudioSourceSelector().select(
            recordingURL: directory.appendingPathComponent("recording.wav"),
            stems: stems,
            allowsRecordingFallback: false
        )

        XCTAssertEqual(source.url, piano)
        XCTAssertEqual(source.configurationIdentifier, "harmony-piano-stem")
    }
}
