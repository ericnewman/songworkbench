import AVFoundation
import Foundation
import XCTest

@testable import SongWorkbench

final class StemMixerTests: XCTestCase {
    func testEffectiveGainsRespectGainMuteAndSolo() {
        var mixer = StemMixerModel()
        mixer.setGain(0.75, for: .vocals)
        mixer.setGain(0.5, for: .drums)
        mixer.setMuted(true, for: .drums)

        XCTAssertEqual(mixer.effectiveGain(for: .vocals), 0.75)
        XCTAssertEqual(mixer.effectiveGain(for: .drums), 0)
        XCTAssertEqual(mixer.effectiveGain(for: .bass), 1)

        mixer.setSoloed(true, for: .vocals)
        XCTAssertEqual(mixer.effectiveGain(for: .vocals), 0.75)
        XCTAssertEqual(mixer.effectiveGain(for: .drums), 0)
        XCTAssertEqual(mixer.effectiveGain(for: .bass), 0)
        XCTAssertEqual(mixer.effectiveGain(for: .other), 0)

        mixer.setMuted(true, for: .vocals)
        XCTAssertEqual(mixer.effectiveGain(for: .vocals), 0)
    }

    func testGainIsClampedAndStemOrderIsStable() {
        var mixer = StemMixerModel()
        mixer.setGain(-1, for: .vocals)
        mixer.setGain(1.5, for: .other)
        mixer.setGain(5, for: .drums)

        XCTAssertEqual(mixer[.vocals].gain, 0)
        XCTAssertEqual(mixer[.other].gain, 1.5)  // boost above unity is allowed
        XCTAssertEqual(mixer[.drums].gain, StemMixState.maximumGain)  // clamped to the ceiling
        XCTAssertEqual(StemKind.allCases, [.vocals, .drums, .bass, .guitar, .piano, .other])
    }

    func testPanIsClampedPersistedAndDefaultsToCenter() throws {
        var mixer = StemMixerModel()
        XCTAssertEqual(mixer[.vocals].pan, 0)  // default center

        mixer.setPan(-0.6, for: .vocals)
        mixer.setPan(3, for: .drums)
        XCTAssertEqual(mixer[.vocals].pan, -0.6)
        XCTAssertEqual(mixer[.drums].pan, 1)  // clamped

        // Round-trips through Codable (the analysis-document persistence path).
        let data = try JSONEncoder().encode(mixer)
        let decoded = try JSONDecoder().decode(StemMixerModel.self, from: data)
        XCTAssertEqual(decoded[.vocals].pan, -0.6)

        // Pre-pan documents (no `pan` key) decode to center rather than failing.
        let legacy = #"{"gain":1.5,"isMuted":false,"isSoloed":true}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(StemMixState.self, from: legacy)
        XCTAssertEqual(state.pan, 0)
        XCTAssertEqual(state.gain, 1.5)
        XCTAssertTrue(state.isSoloed)
    }

    @MainActor
    func testPanGainsFollowConstantPowerLaw() {
        let center = StemPlaybackService.panGains(for: 0)
        XCTAssertEqual(center.left, 0.7071, accuracy: 0.001)
        XCTAssertEqual(center.right, 0.7071, accuracy: 0.001)

        let hardLeft = StemPlaybackService.panGains(for: -1)
        XCTAssertEqual(hardLeft.left, 1, accuracy: 0.001)
        XCTAssertEqual(hardLeft.right, 0, accuracy: 0.001)

        let hardRight = StemPlaybackService.panGains(for: 1)
        XCTAssertEqual(hardRight.left, 0, accuracy: 0.001)
        XCTAssertEqual(hardRight.right, 1, accuracy: 0.001)

        // Constant power: L² + R² stays 1 across the sweep.
        for pan in stride(from: Float(-1), through: 1, by: 0.25) {
            let gains = StemPlaybackService.panGains(for: pan)
            XCTAssertEqual(gains.left * gains.left + gains.right * gains.right, 1, accuracy: 0.001)
        }
    }

    @MainActor
    func testStereoMeterLevelSplitsChannelsAndDuplicatesMono() {
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2)!
        let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 512)!
        stereo.frameLength = 512
        for frame in 0..<512 {
            stereo.floatChannelData![0][frame] = 0.5  // left
            stereo.floatChannelData![1][frame] = 0.1  // right
        }
        let split = StemPlaybackService.stereoMeterLevel(from: stereo)
        XCTAssertEqual(split.left, 0.5, accuracy: 0.001)
        XCTAssertEqual(split.right, 0.1, accuracy: 0.001)

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 512)!
        mono.frameLength = 512
        for frame in 0..<512 { mono.floatChannelData![0][frame] = 0.3 }
        let duplicated = StemPlaybackService.stereoMeterLevel(from: mono)
        XCTAssertEqual(duplicated.left, 0.3, accuracy: 0.001)
        XCTAssertEqual(duplicated.right, duplicated.left)
    }

    func testExporterAppliesPanToTheRenderedMix() async throws {
        // One mono stem panned hard LEFT: the exported stereo file must carry its signal
        // on the left channel and (near) silence on the right.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            other: directory.appendingPathComponent("other.wav")
        )
        try writeConstantWAV(to: stems.vocals, value: 0.4, frames: 8_000, sampleRate: 8_000)
        for kind in [StemKind.drums, .bass, .other] {
            try writeConstantWAV(to: stems[kind]!, value: 0.3, frames: 8_000, sampleRate: 8_000)
        }

        var mixer = StemMixerModel()
        mixer.setPan(-1, for: .vocals)
        for kind in [StemKind.drums, .bass, .other] {
            mixer.setMuted(true, for: kind)
        }

        let destination = directory.appendingPathComponent("panned.wav")
        try await StemMixExporter().export(stems: stems, to: destination, mixer: mixer)

        let output = try AVAudioFile(forReading: destination)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat,
            frameCapacity: AVAudioFrameCount(output.length)
        )!
        try output.read(into: buffer)
        let left = abs(buffer.floatChannelData![0][4_000])
        let right = abs(buffer.floatChannelData![1][4_000])
        XCTAssertGreaterThan(left, 0.2, "panned-left stem must land on the left channel")
        XCTAssertLessThan(right, left * 0.2, "right channel should carry (near) silence")
    }

    func testExporterMixesToStereoAndReportsProgress() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sampleRate = 8_000.0
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            other: directory.appendingPathComponent("other.wav")
        )
        try writeConstantWAV(to: stems.vocals, value: 0.2, frames: 8_000, sampleRate: sampleRate)
        try writeConstantWAV(to: stems.drums, value: 0.2, frames: 4_000, sampleRate: sampleRate)
        try writeConstantWAV(to: stems.bass, value: 0.6, frames: 8_000, sampleRate: sampleRate)
        try writeConstantWAV(to: stems.other, value: 0.6, frames: 8_000, sampleRate: sampleRate)

        var mixer = StemMixerModel()
        mixer.setGain(0.5, for: .drums)
        mixer.setMuted(true, for: .bass)
        mixer.setMuted(true, for: .other)

        let progress = ProgressRecorder()
        let destination = directory.appendingPathComponent("mix.wav")
        try await StemMixExporter().export(
            stems: stems,
            to: destination,
            mixer: mixer,
            progress: { progress.append($0) }
        )

        let output = try AVAudioFile(forReading: destination)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertEqual(output.length, 8_000, accuracy: 2)
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertTrue(zip(progress.values, progress.values.dropFirst()).allSatisfy(<=))

        let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat,
            frameCapacity: AVAudioFrameCount(output.length)
        )!
        try output.read(into: buffer)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        XCTAssertEqual(left[1_000], 0.3, accuracy: 0.02)
        XCTAssertEqual(right[1_000], 0.3, accuracy: 0.02)
        XCTAssertEqual(left[6_000], 0.2, accuracy: 0.02)
        XCTAssertEqual(right[6_000], 0.2, accuracy: 0.02)
    }

    func testCancelledExportDoesNotCreateDestination() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            guitar: directory.appendingPathComponent("guitar.wav"),
            piano: directory.appendingPathComponent("piano.wav"),
            other: directory.appendingPathComponent("other.wav")
        )
        for kind in stems.availableKinds {
            try writeConstantWAV(to: stems[kind]!, value: 0.1, frames: 8_000, sampleRate: 8_000)
        }
        let destination = directory.appendingPathComponent("cancelled.wav")

        let task = Task {
            try await StemMixExporter().export(
                stems: stems,
                to: destination,
                mixer: StemMixerModel()
            )
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeConstantWAV(
        to url: URL,
        value: Float,
        frames: AVAudioFrameCount,
        sampleRate: Double
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = value
        }
        try file.write(from: buffer)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func append(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}
