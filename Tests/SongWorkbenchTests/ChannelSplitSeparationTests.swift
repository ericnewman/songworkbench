import AVFoundation
import XCTest

@testable import SongWorkbench

final class ChannelSplitSeparationTests: XCTestCase {
    private let sampleRate = 44_100.0
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeStereo(left: [Float], right: [Float], to url: URL) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2,
            interleaved: false)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
        buffer.frameLength = AVAudioFrameCount(left.count)
        for i in left.indices {
            buffer.floatChannelData![0][i] = left[i]
            buffer.floatChannelData![1][i] = right[i]
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        try file.write(from: buffer)
    }

    private func readStereo(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let data = buffer.floatChannelData!
        return (
            Array(UnsafeBufferPointer(start: data[0], count: n)),
            Array(
                UnsafeBufferPointer(
                    start: data[min(1, Int(file.processingFormat.channelCount) - 1)], count: n))
        )
    }

    private func tone(_ frequency: Double, seconds: Double = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map {
            Float(sin(2 * .pi * frequency * Double($0) / sampleRate) * 0.5)
        }
    }

    /// A separator stand-in: every stem is the input itself, so a pass's stems show which
    /// channel it was given.
    private final class EchoEngine: StemSeparationEngine, @unchecked Sendable {
        var inputs: [URL] = []
        /// Whether each pass's input carried the same signal on both sides.
        var dualMono: [Bool] = []
        func separate(
            request: StemSeparationRequest,
            progress: @escaping @Sendable (StemSeparationProgress) -> Void
        ) async throws -> StemSeparationResult {
            inputs.append(request.inputURL)
            let file = try AVAudioFile(forReading: request.inputURL)
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let data = buffer.floatChannelData!
            dualMono.append(
                file.processingFormat.channelCount == 2
                    && (0..<Int(buffer.frameLength)).allSatisfy { data[0][$0] == data[1][$0] })
            var urls: [String: URL] = [:]
            for name in ["vocals", "drums", "bass", "other"] {
                let url = request.outputDirectory.appendingPathComponent("\(name).wav")
                try FileManager.default.copyItem(at: request.inputURL, to: url)
                urls[name] = url
            }
            let stems = StemFiles(
                vocals: urls["vocals"]!, drums: urls["drums"]!, bass: urls["bass"]!,
                other: urls["other"]!)
            return StemSeparationResult(stems: stems, processingDuration: .zero)
        }
    }

    func testWidthTellsACentredMixFromAWideOne() throws {
        let centred = root.appendingPathComponent("centred.wav")
        try writeStereo(left: tone(110), right: tone(110), to: centred)
        XCTAssertEqual(try StereoWidth.correlation(url: centred), 1, accuracy: 0.01)
        XCTAssertFalse(StereoWidth.isWide(url: centred))
        // Bass on the left, a guitar on the right: nothing in common.
        let wide = root.appendingPathComponent("wide.wav")
        try writeStereo(left: tone(55), right: tone(330), to: wide)
        XCTAssertTrue(StereoWidth.isWide(url: wide))
    }

    func testACentredMixGoesStraightThrough() async throws {
        let source = root.appendingPathComponent("centred.wav")
        try writeStereo(left: tone(110), right: tone(110), to: source)
        let echo = EchoEngine()
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = try await ChannelSplitStemEngine(base: echo).separate(
            request: StemSeparationRequest(inputURL: source, outputDirectory: output)
        ) { _ in }
        XCTAssertEqual(echo.inputs, [source])
        XCTAssertFalse(
            result.stemSet.assets.contains {
                $0.producerID.hasSuffix(ChannelSplitStemEngine.producerSuffix)
            })
    }

    func testAWideMixIsSeparatedPerChannelAndPutBackInStereo() async throws {
        let source = root.appendingPathComponent("wide.wav")
        let left = tone(55)
        let right = tone(330)
        try writeStereo(left: left, right: right, to: source)
        let echo = EchoEngine()
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let result = try await ChannelSplitStemEngine(base: echo).separate(
            request: StemSeparationRequest(inputURL: source, outputDirectory: output)
        ) { _ in }

        XCTAssertEqual(echo.inputs.count, 2, "one pass per channel")
        // Each pass got one channel on both sides.
        XCTAssertEqual(echo.dualMono, [true, true])
        // The bass stem holds the left pass on the left and the right pass on the right.
        let bass = try readStereo(result.stems.bass)
        XCTAssertEqual(bass.left.count, left.count)
        for i in stride(from: 0, to: left.count, by: 997) {
            XCTAssertEqual(bass.left[i], left[i], accuracy: 1e-4)
            XCTAssertEqual(bass.right[i], right[i], accuracy: 1e-4)
        }
        XCTAssertEqual(
            result.stems.bass.deletingLastPathComponent().standardizedFileURL,
            output.standardizedFileURL)
        XCTAssertTrue(
            result.stemSet.assets.allSatisfy {
                $0.producerID.hasSuffix(ChannelSplitStemEngine.producerSuffix)
            })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent(".channel-split").path),
            "the per-channel work files are removed")

        // Stems made this way are current; the same wide song with stereo-pass stems is not.
        XCTAssertFalse(
            ChannelSplitStemEngine.needsResplit(
                sourceURL: source, storedStemSet: StoredStemSetManifest(manifest: result.stemSet)))
        let stereoPass = StemFiles(
            vocals: result.stems.vocals, drums: result.stems.drums, bass: result.stems.bass,
            other: result.stems.other
        ).stemSetManifest
        XCTAssertTrue(
            ChannelSplitStemEngine.needsResplit(
                sourceURL: source, storedStemSet: StoredStemSetManifest(manifest: stereoPass)))
    }
}
