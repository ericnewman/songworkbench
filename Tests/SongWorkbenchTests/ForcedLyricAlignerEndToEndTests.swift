import AVFoundation
import CoreML
import XCTest

@testable import SongWorkbench

/// MANUAL end-to-end check: runs the REAL bundled acoustic model over a REAL vocal stem and
/// verifies the Swift pipeline reproduces the Python reference implementation.
///
/// Every layer below has unit tests against fixtures; this is the one that proves they compose —
/// mel, Core ML, window splicing, phonemes and Viterbi together, on a whole song. It is skipped
/// unless the model and a stem are present, because neither is in the repository.
///
///     SW_ALIGN_E2E=1 SW_ALIGN_STEM=/path/to/vocals.wav SW_ALIGN_WORDS=/path/to/words.txt \
///       swift test --filter ForcedLyricAlignerEndToEndTests
///
/// `SW_ALIGN_EXPECT` optionally points at the JSON `align_song.py` writes, and the test then
/// asserts the Swift onsets match Python's within a frame.
final class ForcedLyricAlignerEndToEndTests: XCTestCase {

    private struct PythonAlignment: Decodable {
        struct Word: Decodable {
            let word: String
            let start: Double
        }
        let words: [Word]
    }

    /// Bundle.main is the test runner, not the app, so resources come from the source tree.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SongWorkbenchTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func loadPhonemizer() throws -> LyricPhonemizer {
        let url = repositoryRoot.appendingPathComponent("Resources/cmudict-arpabet.txt")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Resources/cmudict-arpabet.txt missing")
        return LyricPhonemizer(
            pronunciations: LyricPhonemizer.parse(try String(contentsOf: url, encoding: .utf8)))
    }

    private func loadModel() throws -> CoreMLLyricsAcousticModel {
        let root = repositoryRoot
        let url = root.appendingPathComponent("BundledModels/LyricsAlignmentMTL.mlpackage")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "BundledModels/LyricsAlignmentMTL.mlpackage not built")
        let compiled = try MLModel.compileModel(at: url)
        return CoreMLLyricsAcousticModel(model: try MLModel(contentsOf: compiled))
    }

    /// Mono samples at the rate the model expects.
    ///
    /// Channels are averaged BEFORE resampling, matching what librosa's `mono=True` does, because
    /// the reference alignment this test compares against was produced that way. Letting the
    /// converter do both at once gave a measurably different signal (rms 0.161 against 0.145) and
    /// moved a minority of word onsets.
    private func samples(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let sourceFormat = file.processingFormat
        guard
            let monoSource = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate,
                channels: 1, interleaved: false),
            let readBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw XCTSkip("cannot allocate for this stem") }
        try file.read(into: readBuffer)

        guard let channels = readBuffer.floatChannelData else { throw XCTSkip("no samples") }
        let frameCount = Int(readBuffer.frameLength)
        let channelCount = Int(sourceFormat.channelCount)
        guard
            let mono = AVAudioPCMBuffer(
                pcmFormat: monoSource, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw XCTSkip("cannot allocate mono buffer") }
        mono.frameLength = AVAudioFrameCount(frameCount)
        let destination = mono.floatChannelData![0]
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            destination[frame] = sum / Float(channelCount)
        }

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: LyricsAlignmentMel.sampleRate,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: monoSource, to: format)
        else { throw XCTSkip("cannot build a converter for this stem") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let ratio = LyricsAlignmentMel.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw XCTSkip("cannot allocate output buffer")
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// The pipeline seam: `MeasuredLyricTiming` is what the analysis stage calls, so this checks
    /// that lyric SEGMENTS come back re-timed — not just that the aligner works in isolation.
    func testMeasuredLyricTimingRetimesRealSegments() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SW_ALIGN_E2E"] == "1", "manual; set SW_ALIGN_E2E=1")
        let stemPath = try XCTUnwrap(environment["SW_ALIGN_STEM"])
        let wordsPath = try XCTUnwrap(environment["SW_ALIGN_WORDS"])

        let model = try loadModel()
        let text = try String(contentsOfFile: wordsPath, encoding: .utf8)
        let words = text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)

        // Rebuild the failure: every word claiming a time from 0, evenly spread, as the ASR gave.
        var timed: [TimedLyricWord] = []
        var built = ""
        for (index, word) in words.enumerated() {
            if !built.isEmpty { built += " " }
            let lower = built.count
            built += word
            let start = Double(index) * 0.5
            timed.append(
                TimedLyricWord(
                    text: word, start: start, end: start + 0.4, characterRange: lower..<built.count)
            )
        }
        let before = [
            TimedLyricSegment(
                start: 0, end: timed.last?.end ?? 0, text: built, words: timed)
        ]

        let result = MeasuredLyricTiming.applied(
            to: before, stemURL: URL(fileURLWithPath: stemPath), onsets: [],
            model: model, phonemizer: try loadPhonemizer())

        XCTAssertTrue(result.outcome.ran, "alignment did not run")
        print(
            "measured \(result.outcome.measured), from onsets \(result.outcome.filledFromOnsets), "
                + "kept transcriber time \(result.outcome.keptTranscriberTime)")

        let after = result.lyrics.flatMap(\.words)
        XCTAssertEqual(after.count, timed.count, "no word may be added or lost")
        XCTAssertEqual(after.map(\.text), timed.map(\.text), "text must be untouched")

        let firstStart = try XCTUnwrap(after.first?.start)
        print("first word: \(timed[0].start)s -> \(firstStart)s")
        XCTAssertGreaterThan(
            firstStart, 5.0,
            "the opening word must move off 0 onto where it is actually sung")
        XCTAssertEqual(
            result.lyrics[0].start, firstStart, accuracy: 1e-6,
            "the line must start where its first word does")
    }

    func testAlignsARealStemAndMatchesThePythonReference() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SW_ALIGN_E2E"] == "1", "manual; set SW_ALIGN_E2E=1")
        let stemPath = try XCTUnwrap(environment["SW_ALIGN_STEM"], "set SW_ALIGN_STEM")
        let wordsPath = try XCTUnwrap(environment["SW_ALIGN_WORDS"], "set SW_ALIGN_WORDS")

        let model = try loadModel()
        let audio = try samples(at: stemPath)
        XCTAssertGreaterThan(audio.count, 0, "stem decoded to no samples")

        let text = try String(contentsOfFile: wordsPath, encoding: .utf8)
        let words = text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        XCTAssertGreaterThan(words.count, 20, "expected a song's worth of words")

        let clock = Date()
        let aligned = try ForcedLyricAligner.align(
            samples: audio, words: words, model: model, phonemizer: try loadPhonemizer())
        let elapsed = Date().timeIntervalSince(clock)

        let duration = Double(audio.count) / LyricsAlignmentMel.sampleRate
        let measured = aligned.compactMap(\.start)
        print(
            "audio \(String(format: "%.1f", duration))s, aligned in "
                + "\(String(format: "%.1f", elapsed))s "
                + "(\(String(format: "%.1f", duration / elapsed))x realtime)")
        print(
            "words \(aligned.count), measured \(measured.count), "
                + "unmeasured \(aligned.count - measured.count)")
        for word in aligned.prefix(8) {
            print(String(format: "  %8.2f  ", word.start ?? -1) + word.text)
        }

        XCTAssertEqual(aligned.count, words.count, "one result per input word, holes included")
        XCTAssertGreaterThan(
            Double(measured.count) / Double(aligned.count), 0.9,
            "over 10% of words unmeasured suggests a vocabulary or windowing fault")
        XCTAssertEqual(measured, measured.sorted(), "word onsets must ascend")
        XCTAssertLessThanOrEqual(measured.last ?? 0, duration, "a word past the end of the audio")

        // The song's first word must not land at 0 when the singing starts later — the exact
        // failure that motivated this work.
        if let first = measured.first, duration > 30 {
            XCTAssertGreaterThan(first, 0.5, "first word at the very start of a long stem")
        }

        // Optional: write the result out so the same onset metric the Python harness uses can
        // score it. Agreement with Python is not the bar — being as good as Python is.
        if let dump = environment["SW_ALIGN_DUMP"] {
            struct Out: Encodable {
                struct W: Encodable {
                    let index: Int
                    let word: String
                    let start: Double
                    let end: Double
                }
                let method: String
                let duration: Double
                let seconds: Double
                let words: [W]
            }
            let payload = Out(
                method: "SWIFT-MTL", duration: duration, seconds: elapsed,
                words: aligned.enumerated().compactMap { index, word in
                    guard let start = word.start, let end = word.end else { return nil }
                    return Out.W(index: index, word: word.text, start: start, end: end)
                })
            try JSONEncoder().encode(payload).write(to: URL(fileURLWithPath: dump))
            print("wrote \(dump)")
        }

        guard let expectedPath = environment["SW_ALIGN_EXPECT"] else { return }
        let reference = try JSONDecoder().decode(
            PythonAlignment.self, from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
        XCTAssertEqual(reference.words.count, aligned.count, "reference covers different words")

        var worst = 0.0
        var disagreements = 0
        for (mine, theirs) in zip(aligned, reference.words) {
            guard let start = mine.start else { continue }
            let delta = abs(start - theirs.start)
            worst = max(worst, delta)
            if delta > ForcedLyricAligner.outputFrameDuration { disagreements += 1 }
        }
        print(
            "vs python: worst \(String(format: "%.3f", worst))s, "
                + "\(disagreements)/\(aligned.count) beyond one frame")
        // Not bit-equality: Swift decodes through AVAudioConverter and Python through librosa's
        // kaiser_fast, so the two align genuinely different signals and the Viterbi may pick a
        // different path where the audio is ambiguous. Averaging channels before resampling took
        // this from 35/249 to 12/249. What must hold is that the implementations agree on the
        // overwhelming majority; whether Swift is as ACCURATE as Python is settled by scoring its
        // output against measured stem onsets (SW_ALIGN_DUMP + tools/lyrics_align_spike).
        XCTAssertLessThanOrEqual(
            Double(disagreements) / Double(aligned.count), 0.08,
            "Swift and Python diverged on more words than decode differences explain")
    }
}
