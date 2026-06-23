import AVFoundation
import XCTest

@testable import SongWorkbench

@MainActor
final class AudioPlaybackServiceTests: XCTestCase {
    func testLoadingAudioReportsItsDuration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate = 44_100.0
        try writeSilentWAV(to: url, sampleRate: sampleRate, duration: 1)

        let playback = AudioPlaybackService()
        playback.load(url)

        XCTAssertEqual(playback.loadedURL, url)
        XCTAssertEqual(playback.duration, 1, accuracy: 0.001)
        XCTAssertNil(playback.errorMessage)
    }

    func testPlaybackCompletionClearsPlayingState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilentWAV(to: url, sampleRate: 8_000, duration: 0.05)
        let playback = AudioPlaybackService()
        playback.load(url)

        playback.play()
        XCTAssertTrue(playback.isPlaying)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.01)
    }

    private func writeSilentWAV(
        to url: URL,
        sampleRate: Double,
        duration: TimeInterval
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!
        buffer.frameLength = buffer.frameCapacity
        try file?.write(from: buffer)
        file = nil
    }
}
