import AVFoundation
import XCTest

@testable import SongWorkbench

/// Measures the REAL 6-stem ONNX CPU separation path end to end on one song.
///
/// This exists because every stem-source experiment so far reused stems that were already on
/// disk, so the project still had no measured timing for the separator actually in use — the
/// only recorded benchmark (`Benchmarks/STEM_SEPARATION.md`) is an older 4-stem Core ML FP16
/// engine, a different model, runtime, and execution provider.
///
/// Manual harness: skipped unless `SW_STEM_SEPARATE=1`, because it loads a 235 MB model and
/// runs multi-minute inference.
final class StemSeparationTimingTests: XCTestCase {
    func testSeparateSongForTiming() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SW_STEM_SEPARATE"] == "1" else {
            throw XCTSkip(
                "manual harness; set SW_STEM_SEPARATE=1 plus SW_SEP_MODEL, SW_SEP_INPUT, "
                    + "SW_SEP_OUTDIR to measure a real separation"
            )
        }
        guard let modelPath = environment["SW_SEP_MODEL"],
            let inputPath = environment["SW_SEP_INPUT"],
            let outputPath = environment["SW_SEP_OUTDIR"]
        else {
            throw XCTSkip("SW_SEP_MODEL, SW_SEP_INPUT, and SW_SEP_OUTDIR are all required")
        }
        let modelURL = URL(fileURLWithPath: modelPath)
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let audioDuration = Self.duration(of: inputURL) ?? 0
        print("sep_model=\(modelURL.lastPathComponent)")
        print("sep_input=\(inputURL.lastPathComponent)")
        print("sep_audio_duration_s=\(String(format: "%.1f", audioDuration))")
        print("sep_segment_frames=\(ONNXSixStemSeparationEngine.defaultSegmentFrames)")

        // Time model construction separately from inference: model load is a fixed cost paid
        // once per run, while inference scales with song length. Reporting them together would
        // make short songs look disproportionately slow.
        let loadStart = ContinuousClock.now
        let engine = try ONNXSixStemSeparationEngine(modelURL: modelURL)
        let loadSeconds = Self.seconds(loadStart.duration(to: .now))
        print("sep_model_load_s=\(String(format: "%.2f", loadSeconds))")

        // The progress callback is @Sendable, so phase de-duplication state has to live in a
        // reference type rather than a captured var.
        let phases = PhaseTracker()
        let separateStart = ContinuousClock.now
        let result = try await engine.separate(
            request: StemSeparationRequest(inputURL: inputURL, outputDirectory: outputURL)
        ) { progress in
            phases.noteIfChanged(progress.phase.rawValue)
        }
        let separateSeconds = Self.seconds(separateStart.duration(to: .now))

        print("sep_wall_s=\(String(format: "%.1f", separateSeconds))")
        print("sep_total_s=\(String(format: "%.1f", loadSeconds + separateSeconds))")
        if audioDuration > 0 {
            // Realtime factor > 1 means faster than playback.
            print(
                "sep_realtime_factor=\(String(format: "%.2f", audioDuration / separateSeconds))x")
            print(
                "sep_minutes_per_audio_minute="
                    + String(format: "%.2f", (separateSeconds / 60) / (audioDuration / 60)))
        }
        print("sep_engine=\(result.stems.isSixSource ? "six-source" : "four-source")")

        for kind in StemKind.allCases {
            guard let url = result.stems[kind] else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? Int) ?? 0
            print("sep_stem=\(kind.rawValue) bytes=\(bytes)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertTrue(result.stems.isSixSource, "expected a six-source stem set")
    }

    /// Prints each separation phase once, from the `@Sendable` progress callback.
    private final class PhaseTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var last = ""

        func noteIfChanged(_ phase: String) {
            lock.lock()
            defer { lock.unlock() }
            guard phase != last else { return }
            last = phase
            print("sep_phase=\(phase)")
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
