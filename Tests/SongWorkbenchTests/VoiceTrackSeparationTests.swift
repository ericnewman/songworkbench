import AVFoundation
import XCTest

@testable import SongWorkbench

final class VoiceTrackSeparationTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// A sung-like tone: five decaying partials of `midi`.
    private func tone(midi: Int, seconds: Double) -> [Float] {
        let f0 = 440 * pow(2, Double(midi - 69) / 12)
        return (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            return Float(
                (1...5).reduce(0.0) { $0 + sin(2 * .pi * f0 * Double($1) * t) / Double($1) })
                * 0.2
        }
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        var ab = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in 0..<n {
            ab += Double(a[i] * b[i])
            aa += Double(a[i] * a[i])
            bb += Double(b[i] * b[i])
        }
        return ab / max((aa * bb).squareRoot(), 1e-12)
    }

    func testTheMaskKeepsOneVoiceAndRejectsAThirdAbove() {
        let low = tone(midi: 57, seconds: 1)  // A3
        let high = tone(midi: 61, seconds: 1)  // C#4, a major third up
        let mix = zip(low, high).map { $0 + $1 }
        let keep = [VoiceTrackRenderer.Note(start: 0, end: 1, midiNote: 57)]
        let compete = [VoiceTrackRenderer.Note(start: 0, end: 1, midiNote: 61)]

        let isolated = VoiceTrackRenderer.isolate(
            samples: mix, sampleRate: sampleRate, keep: keep, compete: compete)

        // Away from the edges, the output follows the kept voice and not the other one.
        let middle = 4_410..<39_690
        let out = Array(isolated[middle])
        XCTAssertGreaterThan(correlation(out, Array(low[middle])), 0.9)
        XCTAssertLessThan(abs(correlation(out, Array(high[middle]))), 0.3)
    }

    func testALoneNotePassesAtItsOwnLevel() {
        let alone = tone(midi: 64, seconds: 1)
        let isolated = VoiceTrackRenderer.isolate(
            samples: alone, sampleRate: sampleRate,
            keep: [VoiceTrackRenderer.Note(start: 0, end: 1, midiNote: 64)], compete: [])
        let middle = 4_410..<39_690
        let ratio =
            isolated[middle].reduce(0) { $0 + Double($1 * $1) }
            / alone[middle].reduce(0) { $0 + Double($1 * $1) }
        XCTAssertEqual(ratio, 1, accuracy: 0.15, "the mask must not change a lone voice's level")
        // Outside the note there is nothing to keep.
        let silent = VoiceTrackRenderer.isolate(
            samples: alone, sampleRate: sampleRate,
            keep: [VoiceTrackRenderer.Note(start: 2, end: 3, midiNote: 64)], compete: [])
        XCTAssertLessThan(silent.map(abs).max() ?? 1, 1e-4)
    }

    private func manifest(root: URL, voices: [Int], split: Bool) -> StemSetManifest {
        var descriptors = [
            StemDescriptor(id: StemKind.vocals.id, role: .source, displayName: "Vocals", order: 0)
        ]
        var assets = [
            StemAsset(
                id: StemKind.vocals.id, audioURL: root.appendingPathComponent("vocals.wav"),
                producerID: "base")
        ]
        if split {
            for (id, order) in [(StemID.vocalLead, 200), (StemID.vocalBacking, 201)] {
                descriptors.append(
                    StemDescriptor(
                        id: id, parentID: StemKind.vocals.id, role: .refinement,
                        displayName: id.rawValue, order: order))
                assets.append(
                    StemAsset(
                        id: id, audioURL: root.appendingPathComponent("\(id.rawValue).wav"),
                        producerID: "karaoke"))
            }
        }
        for voice in voices {
            let id = VoiceTrackPass.stemID(forVoice: voice)
            descriptors.append(
                StemDescriptor(
                    id: id, parentID: StemKind.vocals.id, role: .derived,
                    displayName: "Voice \(voice + 1)", order: 300 + voice))
            assets.append(
                StemAsset(
                    id: id, audioURL: root.appendingPathComponent("\(id.rawValue).wav"),
                    producerID: "voices"))
        }
        return StemSetManifest(descriptors: descriptors, assets: assets)
    }

    func testVoiceTracksNeverHideTheVocalsTheyCameFrom() {
        let root = URL(fileURLWithPath: "/tmp/voices")
        // Without a lead/backing split the vocals still play beside their voice tracks.
        let unsplit = StemMixGraph(manifest: manifest(root: root, voices: [0, 2], split: false))
        XCTAssertEqual(
            unsplit.activeNodes.map(\.id.rawValue),
            ["vocals", "vocals.voice.1", "vocals.voice.3"])
        // With the split, lead and backing replace the vocals as before.
        let split = StemMixGraph(manifest: manifest(root: root, voices: [0], split: true))
        XCTAssertEqual(
            split.activeNodes.map(\.id.rawValue),
            ["vocals.lead", "vocals.backing", "vocals.voice.1"])
    }

    func testVocalStripsAreNamedLeadBackingAndByVoiceNumber() {
        let channels = StemMixerChannelProjector.channels(
            for: manifest(root: URL(fileURLWithPath: "/tmp/voices"), voices: [0, 2], split: true))
        XCTAssertEqual(
            channels.first?.children.map(\.displayName),
            ["Lead", "Backing", "Voice 1", "Voice 3"],
            "voice strips use the Review chart's voice number, even with a voice missing")
    }

    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        try file.write(from: buffer)
    }

    func testThePassWritesEnabledVoiceStripsAndRerunsOnlyWhenTheNotesChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vocals = zip(tone(midi: 57, seconds: 1), tone(midi: 61, seconds: 1)).map { $0 + $1 }
        try writeWAV(vocals, to: root.appendingPathComponent("vocals.wav"))

        var document = SongAnalysisDocument()
        document.stemSet = StoredStemSetManifest(
            manifest: manifest(root: root, voices: [], split: false))
        document.vocalHarmonyNotes = [
            VocalHarmonyObservation(
                timestamp: 0, duration: 1, midiNote: 57, confidence: 1, voiceIndex: 0),
            VocalHarmonyObservation(
                timestamp: 0, duration: 1, midiNote: 61, confidence: 1, voiceIndex: 1),
        ]

        VoiceTrackPass.apply(to: &document)
        let first = try XCTUnwrap(document.stemSet?.resolved())
        let voiceAssets = first.assets.filter { VoiceTrackPass.isVoiceTrack($0.id) }
        XCTAssertEqual(
            voiceAssets.map(\.id.rawValue).sorted(), ["vocals.voice.1", "vocals.voice.2"])
        for asset in voiceAssets {
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.audioURL.path))
            XCTAssertFalse(document.stemMixer[asset.id].isMuted, "voice strips start enabled")
            XCTAssertEqual(first.descriptorsByID[asset.id]?.role, .derived)
        }

        // Unchanged notes: nothing is rewritten, and the user's mute survives.
        document.stemMixer.setMuted(true, for: VoiceTrackPass.stemID(forVoice: 0))
        let written =
            try FileManager.default.attributesOfItem(
                atPath: voiceAssets[0].audioURL.path)[.modificationDate] as? Date
        VoiceTrackPass.apply(to: &document)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: voiceAssets[0].audioURL.path)[.modificationDate] as? Date,
            written)
        XCTAssertTrue(document.stemMixer[VoiceTrackPass.stemID(forVoice: 0)].isMuted)

        // A voice disappears from the harmony notes: its strip goes.
        document.vocalHarmonyNotes.removeLast()
        VoiceTrackPass.apply(to: &document)
        XCTAssertEqual(
            try XCTUnwrap(document.stemSet?.resolved()).assets
                .filter { VoiceTrackPass.isVoiceTrack($0.id) }.map(\.id.rawValue),
            ["vocals.voice.1"])
    }

    func testDerivedVoiceTracksAreNotNoteSources() throws {
        var document = SongAnalysisDocument()
        document.stemSet = StoredStemSetManifest(
            manifest: manifest(root: URL(fileURLWithPath: "/tmp/voices"), voices: [0], split: true))
        let ids = BucketNotePass.stemAudio(for: document, gated: false).map(\.id)
        XCTAssertFalse(ids.contains { VoiceTrackPass.isVoiceTrack($0) })
    }
}
