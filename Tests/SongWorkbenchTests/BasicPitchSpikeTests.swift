import Foundation
import OnnxRuntimeBindings
import XCTest

@testable import SongWorkbench

/// Spike: can the app's onnxruntime build load and run Spotify's Basic Pitch note-transcription
/// model (`nmp.onnx`, tf2onnx opset 15, ~228 KB)? See tasks/spike-basic-pitch.md for the
/// measured results and the model contract this test pins. Skipped unless
/// `SW_BASIC_PITCH_SPIKE=1`; the model is read from `SW_BASIC_PITCH_MODEL` or, failing that,
/// from the probe venv under tools/basic_pitch_probe (gitignored — `uv venv` + `uv pip install
/// "basic-pitch[onnx]"` puts it there). Nothing here is wired into the app.
final class BasicPitchSpikeTests: XCTestCase {
    // Basic Pitch's contract (basic_pitch/constants.py): 22 050 Hz mono, one window is
    // 2 s minus one FFT hop = 43 844 samples, and every output has 172 frames (86 fps) with
    // 88 note bins from MIDI 21 (A0) — or 264 contour bins at three per semitone.
    static let sampleRate = 22050.0
    static let windowSamples = 43844
    static let frames = 172
    static let noteBins = 88
    static let contourBins = 264
    static let inputName = "serving_default_input_2:0"
    static let contourOutput = "StatefulPartitionedCall:0"
    static let noteOutput = "StatefulPartitionedCall:1"
    static let onsetOutput = "StatefulPartitionedCall:2"

    func testSineAt440HzPeaksAtMIDI69() throws {
        guard ProcessInfo.processInfo.environment["SW_BASIC_PITCH_SPIKE"] == "1" else {
            throw XCTSkip("Set SW_BASIC_PITCH_SPIKE=1 to run the Basic Pitch ONNX spike")
        }
        let modelPath = try Self.modelPath()

        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        let session = try ORTSession(
            env: environment, modelPath: modelPath, sessionOptions: options)
        XCTAssertEqual(try session.inputNames(), [Self.inputName])
        XCTAssertEqual(
            Set(try session.outputNames()),
            [Self.contourOutput, Self.noteOutput, Self.onsetOutput])

        // One window of a 440 Hz sine at half scale: [1, 43844, 1] float32.
        var samples = [Float](repeating: 0, count: Self.windowSamples)
        for index in samples.indices {
            samples[index] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(index) / Self.sampleRate))
        }
        let inputData = NSMutableData(length: samples.count * MemoryLayout<Float>.size)!
        inputData.mutableBytes.bindMemory(to: Float.self, capacity: samples.count)
            .update(from: samples, count: samples.count)
        let input = try ORTValue(
            tensorData: inputData, elementType: .float,
            shape: [1, NSNumber(value: Self.windowSamples), 1])

        let started = Date()
        let outputs = try session.run(
            withInputs: [Self.inputName: input],
            outputNames: [Self.noteOutput, Self.onsetOutput, Self.contourOutput],
            runOptions: nil)
        let elapsed = Date().timeIntervalSince(started)
        print("basic_pitch_spike_window_seconds=\(elapsed)")

        let note = try Self.floats(
            outputs[Self.noteOutput], shape: [1, Self.frames, Self.noteBins])
        _ = try Self.floats(outputs[Self.onsetOutput], shape: [1, Self.frames, Self.noteBins])
        let contour = try Self.floats(
            outputs[Self.contourOutput], shape: [1, Self.frames, Self.contourBins])

        // Time-average the note posterior; the strongest bin must be A4 (MIDI 69 → bin 48).
        var meanPerBin = [Float](repeating: 0, count: Self.noteBins)
        for frame in 0..<Self.frames {
            for bin in 0..<Self.noteBins {
                meanPerBin[bin] += note[frame * Self.noteBins + bin] / Float(Self.frames)
            }
        }
        let peakBin = meanPerBin.indices.max { meanPerBin[$0] < meanPerBin[$1] }!
        let runnerUp =
            meanPerBin.enumerated().filter { $0.offset != peakBin }
            .map(\.element).max() ?? 0
        print(
            "basic_pitch_spike_peak_bin=\(peakBin) midi=\(peakBin + 21) "
                + "posterior=\(meanPerBin[peakBin]) runner_up=\(runnerUp)")
        XCTAssertEqual(peakBin + 21, 69)
        XCTAssertGreaterThan(meanPerBin[peakBin], 0.5)
        XCTAssertGreaterThan(meanPerBin[peakBin], 3 * runnerUp)

        // The contour head (3 bins/semitone) must agree to within a third of a semitone.
        var meanContour = [Float](repeating: 0, count: Self.contourBins)
        for frame in 0..<Self.frames {
            for bin in 0..<Self.contourBins {
                meanContour[bin] += contour[frame * Self.contourBins + bin] / Float(Self.frames)
            }
        }
        let contourPeak = meanContour.indices.max { meanContour[$0] < meanContour[$1] }!
        XCTAssertEqual(Double(contourPeak) / 3 + 21, 69, accuracy: 0.34)
    }

    private static func modelPath() throws -> String {
        if let path = ProcessInfo.processInfo.environment["SW_BASIC_PITCH_MODEL"] {
            return path
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let venv = repo.appendingPathComponent("tools/basic_pitch_probe/.probevenv/lib")
        let libs = (try? FileManager.default.contentsOfDirectory(atPath: venv.path)) ?? []
        for lib in libs where lib.hasPrefix("python") {
            let candidate = venv.appendingPathComponent(
                "\(lib)/site-packages/basic_pitch/saved_models/icassp_2022/nmp.onnx")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        throw XCTSkip("No Basic Pitch model: set SW_BASIC_PITCH_MODEL or create the probe venv")
    }

    private static func floats(_ value: ORTValue?, shape expected: [Int]) throws -> [Float] {
        let value = try XCTUnwrap(value)
        let shape = try value.tensorTypeAndShapeInfo().shape.map(\.intValue)
        XCTAssertEqual(shape, expected)
        let data = try value.tensorData()
        let count = expected.reduce(1, *)
        XCTAssertEqual(data.length, count * MemoryLayout<Float>.size)
        let pointer = data.bytes.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}
