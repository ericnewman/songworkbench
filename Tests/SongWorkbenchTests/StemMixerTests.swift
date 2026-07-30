import AVFoundation
import Foundation
import XCTest

@testable import SongWorkbench

final class StemMixerTests: XCTestCase {
    func testMixerChannelsExposeRefinedChildrenInsteadOfTheirParent() {
        let root = URL(fileURLWithPath: "/tmp/refined-stems")
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.drums.id,
                    role: .source,
                    displayName: "Drums",
                    order: 1
                ),
                StemDescriptor(
                    id: .drumKick,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Kick",
                    order: 2
                ),
                StemDescriptor(
                    id: .drumSnare,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Snare",
                    order: 3
                ),
                StemDescriptor(
                    id: StemKind.bass.id,
                    role: .source,
                    displayName: "Bass",
                    order: 4
                ),
            ],
            assets: [
                StemAsset(
                    id: StemKind.drums.id,
                    audioURL: root.appendingPathComponent("drums.wav"),
                    producerID: "base"
                ),
                StemAsset(
                    id: .drumKick,
                    audioURL: root.appendingPathComponent("kick.wav"),
                    producerID: "refiner"
                ),
                StemAsset(
                    id: .drumSnare,
                    audioURL: root.appendingPathComponent("snare.wav"),
                    producerID: "refiner"
                ),
                StemAsset(
                    id: StemKind.bass.id,
                    audioURL: root.appendingPathComponent("bass.wav"),
                    producerID: "base"
                ),
            ]
        )

        XCTAssertEqual(
            StemMixerChannelProjector.channels(for: manifest),
            [
                StemMixerChannel(id: .drumKick, displayName: "Kick", order: 2),
                StemMixerChannel(id: .drumSnare, displayName: "Snare", order: 3),
                StemMixerChannel(id: StemKind.bass.id, displayName: "Bass", order: 4),
            ]
        )
    }

    func testWaveformLaneTargetsMatchMixerFrontierIncludingDrumChildren() {
        let root = URL(fileURLWithPath: "/tmp/refined-waveforms")
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.vocals.id,
                    role: .source,
                    displayName: "Vocals",
                    order: 0
                ),
                StemDescriptor(
                    id: StemKind.drums.id,
                    role: .source,
                    displayName: "Drums",
                    order: 1
                ),
                StemDescriptor(
                    id: .drumKick,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Kick",
                    order: 2
                ),
                StemDescriptor(
                    id: .drumSnare,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Snare",
                    order: 3
                ),
                StemDescriptor(
                    id: .drumCymbals,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Cymbals",
                    order: 4
                ),
                StemDescriptor(
                    id: .drumToms,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Toms",
                    order: 5
                ),
                StemDescriptor(
                    id: StemKind.bass.id,
                    role: .source,
                    displayName: "Bass",
                    order: 6
                ),
            ],
            assets: [
                StemAsset(
                    id: StemKind.vocals.id,
                    audioURL: root.appendingPathComponent("vocals.wav"),
                    producerID: "base"
                ),
                StemAsset(
                    id: StemKind.drums.id,
                    audioURL: root.appendingPathComponent("drums.wav"),
                    producerID: "base"
                ),
                StemAsset(
                    id: .drumKick,
                    audioURL: root.appendingPathComponent("kick.wav"),
                    producerID: "drumsep"
                ),
                StemAsset(
                    id: .drumSnare,
                    audioURL: root.appendingPathComponent("snare.wav"),
                    producerID: "drumsep"
                ),
                StemAsset(
                    id: .drumCymbals,
                    audioURL: root.appendingPathComponent("cymbals.wav"),
                    producerID: "drumsep"
                ),
                StemAsset(
                    id: .drumToms,
                    audioURL: root.appendingPathComponent("toms.wav"),
                    producerID: "drumsep"
                ),
                StemAsset(
                    id: StemKind.bass.id,
                    audioURL: root.appendingPathComponent("bass.wav"),
                    producerID: "base"
                ),
            ]
        )

        let targets = StemWaveformLaneProjector.targets(for: manifest)
        XCTAssertEqual(
            targets.map(\.id),
            [
                StemKind.vocals.id, .drumKick, .drumSnare, .drumCymbals, .drumToms,
                StemKind.bass.id,
            ])
        XCTAssertEqual(
            targets.map(\.displayName),
            [
                "Vocals", "Kick", "Snare", "Cymbals", "Toms", "Bass",
            ])
        XCTAssertFalse(targets.contains { $0.id == StemKind.drums.id })
        XCTAssertEqual(
            StemMixerChannelProjector.channels(for: manifest).map(\.id), targets.map(\.id))
        XCTAssertEqual(StemID.drumKick.laneColor, StemKind.drums.laneColor)
    }

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

    func testMasterGainDefaultsToUnityIsClampedAndPersists() throws {
        var mixer = StemMixerModel()
        XCTAssertEqual(mixer.masterGain, 1)

        mixer.setMasterGain(0.4)
        XCTAssertEqual(mixer.masterGain, 0.4)

        mixer.setMasterGain(-1)
        XCTAssertEqual(mixer.masterGain, 0)  // clamped to the floor

        mixer.setMasterGain(5)
        XCTAssertEqual(mixer.masterGain, StemMixerModel.maximumMasterGain)  // clamped to unity

        mixer.setMasterGain(0.6)
        let data = try JSONEncoder().encode(mixer)
        let decoded = try JSONDecoder().decode(StemMixerModel.self, from: data)
        XCTAssertEqual(decoded.masterGain, 0.6)

        // Pre-master documents (no `masterGain` key) decode to unity rather than failing, and
        // still carry every stem's own state. `states` is `[StemKind: StemMixState]`, which
        // Codable's synthesized Dictionary support encodes as a flat alternating-pairs array
        // (StemKind isn't literally `String`, so it doesn't get the keyed-object shortcut) —
        // matching what `JSONEncoder().encode(StemMixerModel())` actually produces.
        let legacy = """
            {"states":["vocals",{"gain":0.8,"isMuted":false,"isSoloed":false,"pan":0}]}
            """.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode(StemMixerModel.self, from: legacy)
        XCTAssertEqual(legacyDecoded.masterGain, 1)
        XCTAssertEqual(legacyDecoded[.vocals].gain, 0.8)
    }

    func testMasterGainIsIncludedInModifiedComparison() {
        var mixer = StemMixerModel()
        XCTAssertEqual(mixer, StemMixerModel())

        mixer.setMasterGain(0.5)
        XCTAssertNotEqual(mixer, StemMixerModel())
    }

    func testMixerPersistsUnknownStemIDs() throws {
        var mixer = StemMixerModel()
        let leadID: StemID = "guitar.lead"
        mixer.setGain(0.4, for: leadID)
        mixer.setMuted(true, for: leadID)
        mixer.setPan(0.75, for: leadID)

        let data = try JSONEncoder().encode(mixer)
        let decoded = try JSONDecoder().decode(StemMixerModel.self, from: data)

        XCTAssertEqual(decoded[leadID].gain, 0.4)
        XCTAssertTrue(decoded[leadID].isMuted)
        XCTAssertEqual(decoded[leadID].pan, 0.75)
        XCTAssertEqual(decoded[StemKind.vocals].gain, 1)
    }

    func testExporterAppliesMasterGainToTheWholeRenderedMix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stems = StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            other: directory.appendingPathComponent("other.wav")
        )
        for kind in [StemKind.vocals, .drums, .bass, .other] {
            try writeConstantWAV(to: stems[kind]!, value: 0.4, frames: 8_000, sampleRate: 8_000)
        }
        var mixer = StemMixerModel()
        for kind in [StemKind.drums, .bass, .other] {
            mixer.setMuted(true, for: kind)
        }
        mixer.setMasterGain(0.5)

        let destination = directory.appendingPathComponent("master-halved.wav")
        try await StemMixExporter().export(stems: stems, to: destination, mixer: mixer)

        let output = try AVAudioFile(forReading: destination)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat,
            frameCapacity: AVAudioFrameCount(output.length)
        )!
        try output.read(into: buffer)
        // A solo 0.4-amplitude mono stem at center pan lands unattenuated on both channels
        // (see `testExporterMixesToStereoAndReportsProgress`); halving the master should
        // halve that to ~0.2.
        let left = abs(buffer.floatChannelData![0][4_000])
        let right = abs(buffer.floatChannelData![1][4_000])
        XCTAssertEqual(left, 0.2, accuracy: 0.02)
        XCTAssertEqual(right, 0.2, accuracy: 0.02)
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

    func testHierarchicalExportDoesNotRenderParentAndChildrenTogether() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentURL = directory.appendingPathComponent("drums.wav")
        let kickURL = directory.appendingPathComponent("kick.wav")
        try writeConstantWAV(to: parentURL, value: 0.5, frames: 8_000, sampleRate: 8_000)
        try writeConstantWAV(to: kickURL, value: 0.25, frames: 8_000, sampleRate: 8_000)
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.drums.id, role: .source, displayName: "Drums", order: 1),
                StemDescriptor(
                    id: .drumKick,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Kick",
                    order: 2
                ),
            ],
            assets: [
                StemAsset(id: StemKind.drums.id, audioURL: parentURL, producerID: "base"),
                StemAsset(id: .drumKick, audioURL: kickURL, producerID: "drum-refiner"),
            ]
        )

        let destination = directory.appendingPathComponent("hierarchical.wav")
        try await StemMixExporter().export(
            manifest: manifest,
            to: destination,
            mixer: StemMixerModel()
        )

        let output = try AVAudioFile(forReading: destination)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat,
            frameCapacity: AVAudioFrameCount(output.length)
        )!
        try output.read(into: buffer)
        let left = abs(buffer.floatChannelData![0][4_000])
        let right = abs(buffer.floatChannelData![1][4_000])
        XCTAssertEqual(left, 0.25, accuracy: 0.02)
        XCTAssertEqual(right, 0.25, accuracy: 0.02)
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
