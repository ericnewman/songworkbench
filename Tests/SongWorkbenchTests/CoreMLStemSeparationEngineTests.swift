import AVFoundation
import XCTest

@testable import SongWorkbench

final class CoreMLStemSeparationEngineTests: XCTestCase {
    func testHalfPrecisionFloatValueDecodesCommonModelOutputs() {
        XCTAssertEqual(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x0000), 0)
        XCTAssertEqual(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x8000), -0)
        XCTAssertEqual(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x3C00), 1)
        XCTAssertEqual(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0xBC00), -1)
        XCTAssertEqual(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x3800), 0.5)
        XCTAssertEqual(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0xC000), -2)
        XCTAssertEqual(
            CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x0001),
            pow(2, -24),
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x7C00),
            .infinity
        )
        XCTAssertTrue(CoreMLStemChunkPredictor.halfPrecisionFloatValue(bitPattern: 0x7E00).isNaN)
    }

    func testSeparationPublishesAlignedSixStemSetWithMonotonicProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.wav")
        try writeStereoFixture(to: sourceURL, frameCount: 2_200)
        let outputURL = directory.appendingPathComponent("stems", isDirectory: true)
        let progress = ProgressRecorder<StemSeparationProgress>()
        let engine = CoreMLStemSeparationEngine(
            predictor: QuarterMixStemPredictor(),
            segmentFrames: 1_000,
            overlapFrames: 100
        )

        let result = try await engine.separate(
            request: StemSeparationRequest(inputURL: sourceURL, outputDirectory: outputURL)
        ) { update in
            progress.record(update)
        }

        let stemURLs = result.stems.availableKinds.compactMap { result.stems[$0] }
        XCTAssertEqual(
            Set(stemURLs.map(\.lastPathComponent)),
            Set([
                "vocals.wav", "drums.wav", "bass.wav", "guitar.wav", "piano.wav", "other.wav",
            ]))
        for stemURL in stemURLs {
            let file = try AVAudioFile(forReading: stemURL)
            XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
            XCTAssertEqual(file.fileFormat.channelCount, 2)
            XCTAssertEqual(file.length, 2_200)
        }
        let updates = progress.values
        XCTAssertEqual(updates.first?.phase, .preparingAudio)
        XCTAssertEqual(updates.last?.phase, .writingOutputs)
        XCTAssertEqual(updates.last?.fractionCompleted, 1)
        XCTAssertTrue(
            zip(updates, updates.dropFirst()).allSatisfy {
                $0.fractionCompleted <= $1.fractionCompleted
            })
    }

    private func writeStereoFixture(to url: URL, frameCount: Int) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.01) * 0.4
            buffer.floatChannelData![1][frame] = cos(Float(frame) * 0.01) * 0.3
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

private struct QuarterMixStemPredictor: StemChunkPredicting {
    let supportedStems = StemKind.allCases

    func predict(_ chunk: StereoAudioChunk) async throws -> StemChunkPrediction {
        StemChunkPrediction(
            samplesByStem: Dictionary(
                uniqueKeysWithValues: StemKind.allCases.map { kind in
                    (kind, chunk.channels.map { $0.map { $0 / 4 } })
                })
        )
    }
}

private final class ProgressRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func record(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}
