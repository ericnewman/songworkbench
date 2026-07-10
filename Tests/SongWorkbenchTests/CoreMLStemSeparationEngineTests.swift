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

    /// Regression test for a real bug: `loadStereoFloatAudio`'s resample path used to call
    /// `AVAudioConverter.convert(to:error:withInputFrom:)` exactly once and treat that single
    /// call's output as the whole answer. A resample is not guaranteed to fully drain in one
    /// pull (internal priming/latency), so the separated stem could come out measurably SHORTER
    /// than the source with no error — reproduced on a real 225.6s song whose separated vocals
    /// stem measured only ~205s, silently truncating the last ~20s of every transcription pass.
    /// This fixture is written at 48kHz (source formats are rarely already 44.1kHz stereo
    /// Float32, so nearly every real separation goes through the resample path this exercises)
    /// and asserts the 44.1kHz output stem is NOT short of its expected duration.
    func testSeparationOfNonMatchingSampleRateDoesNotTruncateTheTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.wav")
        let sourceFrameCount = 96_000
        try writeStereoFixture(to: sourceURL, frameCount: sourceFrameCount, sampleRate: 48_000)
        let outputURL = directory.appendingPathComponent("stems", isDirectory: true)
        let engine = CoreMLStemSeparationEngine(
            predictor: QuarterMixStemPredictor(),
            segmentFrames: 4_000,
            overlapFrames: 400
        )

        let result = try await engine.separate(
            request: StemSeparationRequest(inputURL: sourceURL, outputDirectory: outputURL)
        ) { _ in }

        // 96,000 frames @ 48kHz is exactly 2.0s; the 44.1kHz equivalent is exactly 88,200 frames.
        let expectedFrames: AVAudioFramePosition = 88_200
        let tolerance: AVAudioFramePosition = 50
        for kind in result.stems.availableKinds {
            guard let stemURL = result.stems[kind] else { continue }
            let file = try AVAudioFile(forReading: stemURL)
            XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
            let length: AVAudioFramePosition = file.length
            let lowerBound = expectedFrames - tolerance
            let upperBound = expectedFrames + tolerance
            // A handful of frames of edge/rounding slack is fine; the bug this guards against
            // dropped roughly 10% of the audio (thousands of frames on a real song), not a few.
            let message =
                "\(kind.rawValue) stem length \(length) not within "
                + "\(lowerBound)...\(upperBound) of the expected \(expectedFrames) frames"
            XCTAssertGreaterThan(length, lowerBound, message)
            XCTAssertLessThan(length, upperBound, message)
        }
    }

    /// The streaming writer replaced a whole-song accumulation buffer with an incremental
    /// cross-fade. `QuarterMixStemPredictor` returns `input / 4` for every stem, so a correct
    /// overlap-add must reconstruct exactly `input / 4` sample-for-sample across chunk seams —
    /// this catches any off-by-one or weight error in the carry/finalize boundaries.
    func testStreamingOverlapAddReconstructsQuarterMixExactly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.wav")
        let frameCount = 5_000
        try writeStereoFixture(to: sourceURL, frameCount: frameCount)
        let outputURL = directory.appendingPathComponent("stems", isDirectory: true)
        // Segment/overlap chosen so the song spans several chunks with real overlap seams.
        let engine = CoreMLStemSeparationEngine(
            predictor: QuarterMixStemPredictor(),
            segmentFrames: 1_000,
            overlapFrames: 250
        )

        let result = try await engine.separate(
            request: StemSeparationRequest(inputURL: sourceURL, outputDirectory: outputURL)
        ) { _ in }

        for kind in [StemKind.vocals, .drums, .bass, .guitar, .piano, .other] {
            guard let url = result.stems[kind] else {
                XCTFail("missing \(kind.rawValue) stem")
                continue
            }
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )!
            try file.read(into: buffer)
            XCTAssertEqual(Int(buffer.frameLength), frameCount, "\(kind.rawValue) length")
            let left = buffer.floatChannelData![0]
            let right = buffer.floatChannelData![1]
            for frame in 0..<frameCount {
                XCTAssertEqual(
                    left[frame], sin(Float(frame) * 0.01) * 0.4 / 4, accuracy: 1e-4,
                    "\(kind.rawValue) L @\(frame)")
                XCTAssertEqual(
                    right[frame], cos(Float(frame) * 0.01) * 0.3 / 4, accuracy: 1e-4,
                    "\(kind.rawValue) R @\(frame)")
            }
        }
    }

    private func writeStereoFixture(
        to url: URL, frameCount: Int, sampleRate: Double = 44_100
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
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
