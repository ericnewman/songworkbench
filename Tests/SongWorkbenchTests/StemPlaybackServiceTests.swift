import AVFoundation
import XCTest

@testable import SongWorkbench

@MainActor
final class StemPlaybackServiceTests: XCTestCase {
    func testLoadPublishesDurationAndSupportsSeekPitchAndTempo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StemPlaybackService()
        try service.load(try makeStemFiles(in: directory), mixer: StemMixerModel())
        service.seek(to: 0.5)
        service.setPitch(semitones: 3)
        service.setTempo(rate: 0.8)

        XCTAssertEqual(service.duration, 1, accuracy: 0.01)
        XCTAssertEqual(service.currentTime, 0.5, accuracy: 0.01)
        XCTAssertEqual(service.pitchSemitones, 3)
        XCTAssertEqual(service.tempoRate, 0.8, accuracy: 0.001)
    }

    func testPlaybackPublishesProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StemPlaybackService()
        try service.load(try makeStemFiles(in: directory), mixer: StemMixerModel())
        service.play()
        try await Task.sleep(for: .milliseconds(180))
        service.pause()

        XCTAssertGreaterThan(service.currentTime, 0.05)
        XCTAssertLessThan(service.currentTime, service.duration)
    }

    func testFailedReloadClearsPreviouslyLoadedState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validFiles = try makeStemFiles(in: directory)
        let service = StemPlaybackService()
        try service.load(validFiles, mixer: StemMixerModel())
        XCTAssertTrue(service.isLoaded)

        let missingBass = StemFiles(
            vocals: validFiles.vocals,
            drums: validFiles.drums,
            bass: directory.appendingPathComponent("missing.wav"),
            other: validFiles.other
        )
        XCTAssertThrowsError(try service.load(missingBass, mixer: StemMixerModel()))
        XCTAssertFalse(service.isLoaded)
        XCTAssertFalse(service.isPlaying)
    }

    private func makeStemFiles(in directory: URL) throws -> StemFiles {
        var urls: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let url = directory.appendingPathComponent("\(kind.rawValue).wav")
            try writeSilence(to: url)
            urls[kind] = url
        }
        return StemFiles(
            vocals: urls[.vocals]!,
            drums: urls[.drums]!,
            bass: urls[.bass]!,
            guitar: urls[.guitar]!,
            piano: urls[.piano]!,
            other: urls[.other]!
        )
    }

    private func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        try file.write(from: buffer)
    }
}
