import AVFoundation
import XCTest

@testable import SongWorkbench

final class ONNXSixStemSeparationEngineTests: XCTestCase {
    func testInstalledModelReturnsSixFiniteStereoSourcesWhenConfigured() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["CCS_HTDEMUCS_6S_MODEL"] else {
            throw XCTSkip("Set CCS_HTDEMUCS_6S_MODEL for production six-source validation.")
        }
        let frameCount = 343_980
        let left = (0..<frameCount).map { sin(Float($0) * 0.01) * 0.1 }
        let right = (0..<frameCount).map { cos(Float($0) * 0.013) * 0.1 }
        let predictor = try ONNXSixStemChunkPredictor(
            modelURL: URL(fileURLWithPath: modelPath),
            usesCoreMLExecutionProvider: shouldUseCoreMLExecutionProvider()
        )

        let prediction = try await predictor.predict(
            StereoAudioChunk(left: left, right: right)
        )

        XCTAssertEqual(Set(prediction.samplesByStem.keys), Set(StemKind.allCases))
        for kind in StemKind.allCases {
            let channels = try XCTUnwrap(prediction.samplesByStem[kind])
            XCTAssertEqual(channels.count, 2)
            XCTAssertEqual(channels[0].count, frameCount)
            XCTAssertTrue(channels.joined().allSatisfy(\.isFinite))
        }
    }

    func testInstalledEngineWritesSixReadableStemFilesWhenConfigured() async throws {
        guard
            let modelPath = ProcessInfo.processInfo.environment["CCS_HTDEMUCS_6S_MODEL"],
            let audioPath = ProcessInfo.processInfo.environment["CCS_STEM_AUDIO"]
        else {
            throw XCTSkip("Set CCS_HTDEMUCS_6S_MODEL and CCS_STEM_AUDIO for end-to-end validation.")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccs-six-stem-validation", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        let keepsOutput = ProcessInfo.processInfo.environment["CCS_KEEP_STEM_TEST_OUTPUT"] == "1"
        defer {
            if !keepsOutput {
                try? FileManager.default.removeItem(at: output)
            }
        }
        let engine = try ONNXSixStemSeparationEngine(
            modelURL: URL(fileURLWithPath: modelPath),
            usesCoreMLExecutionProvider: shouldUseCoreMLExecutionProvider()
        )

        let result = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: URL(fileURLWithPath: audioPath),
                outputDirectory: output
            )
        ) { _ in }

        XCTAssertTrue(result.stems.isSixSource)
        for kind in StemKind.allCases {
            let url = try XCTUnwrap(result.stems[kind])
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.length, 0)
            XCTAssertEqual(file.processingFormat.channelCount, 2)
        }
        let accompaniment = try XCTUnwrap(result.stems.accompaniment)
        XCTAssertGreaterThan(try AVAudioFile(forReading: accompaniment).length, 0)
        try assertStemSumReconstructsInput(
            sourceURL: URL(fileURLWithPath: audioPath),
            stems: result.stems
        )
    }

    private func shouldUseCoreMLExecutionProvider() -> Bool {
        ProcessInfo.processInfo.environment["CCS_HTDEMUCS_ENABLE_COREML"] == "1"
    }

    private func assertStemSumReconstructsInput(
        sourceURL: URL,
        stems: StemFiles,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try readStereoSamples(sourceURL)
        let stemSamples = try StemKind.allCases.map { kind in
            try readStereoSamples(XCTUnwrap(stems[kind], file: file, line: line))
        }
        let frameCount = min(source[0].count, stemSamples.map { $0[0].count }.min() ?? 0)
        XCTAssertGreaterThan(frameCount, 0, file: file, line: line)

        var sourceEnergy = Double(0)
        var residualEnergy = Double(0)
        for channel in 0..<2 {
            for frame in 0..<frameCount {
                let expected = Double(source[channel][frame])
                let actual = stemSamples.reduce(Double(0)) { total, stem in
                    total + Double(stem[channel][frame])
                }
                let residual = expected - actual
                sourceEnergy += expected * expected
                residualEnergy += residual * residual
            }
        }
        let sourceRMS = sqrt(sourceEnergy / Double(frameCount * 2))
        let residualRMS = sqrt(residualEnergy / Double(frameCount * 2))

        XCTAssertGreaterThan(sourceRMS, 1e-6, file: file, line: line)
        XCTAssertLessThan(
            residualRMS,
            sourceRMS * 0.35,
            "Stem sum residual is too high; source RMS \(sourceRMS), residual RMS \(residualRMS).",
            file: file,
            line: line
        )
    }

    private func readStereoSamples(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw CoreMLStemSeparationError.unsupportedAudio
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let left = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        let right =
            channelCount > 1
            ? Array(UnsafeBufferPointer(start: channelData[1], count: frameCount))
            : left
        return [left, right]
    }
}
