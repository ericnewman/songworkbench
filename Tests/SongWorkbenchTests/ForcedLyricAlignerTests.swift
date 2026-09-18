import XCTest

@testable import SongWorkbench

final class ForcedLyricAlignerTests: XCTestCase {

    /// A stand-in acoustic model: replays a posteriorgram the test wrote, so the windowing and
    /// word-mapping can be checked without the 24 MB Core ML file.
    private struct ScriptedModel: LyricsAcousticModel {
        let melFramesPerWindow: Int
        /// Class that wins at each OUTPUT frame, for the whole song.
        let winners: [Int]
        /// Records the windows it was asked for, so overlap behaviour is observable.
        final class Calls: @unchecked Sendable {
            var count = 0
        }
        let calls: Calls

        func logProbabilities(melWindow: [[Float]]) throws -> [[Float]] {
            calls.count += 1
            // Identify the window by its first frame's marker value, written by the test. The
            // marker counts MEL frames; the script is indexed by OUTPUT frames, three mel frames
            // to one — conflating them is exactly the off-by-3 splice this test exists to catch.
            let marker = Int(melWindow.first?.first ?? 0) / 3
            let frames = melFramesPerWindow / 3
            return (0..<frames).map { frame in
                let index = marker + frame
                let winner = index < winners.count ? winners[index] : ArpabetVocabulary.blankIndex
                return (0..<ArpabetVocabulary.classCount).map {
                    $0 == winner ? Float(-0.01) : Float(-12)
                }
            }
        }
    }

    /// Mel whose every frame carries its own index, so ScriptedModel can tell windows apart.
    private func markedMel(frames: Int) -> [[Float]] {
        (0..<frames).map { frame in
            var row = [Float](repeating: 0, count: LyricsAlignmentMel.melBands)
            row[0] = Float(frame)
            return row
        }
    }

    private func phonemizer() -> LyricPhonemizer {
        LyricPhonemizer(
            pronunciations: [
                "love": ["L", "AH", "V"].compactMap(ArpabetVocabulary.index(of:)),
                "me": ["M", "IY"].compactMap(ArpabetVocabulary.index(of:)),
            ])
    }

    func testOutputFrameDurationMatchesTheModel() {
        // 3 mel hops per output frame at 22050 Hz -> 34.83 ms, the model's published resolution.
        XCTAssertEqual(ForcedLyricAligner.outputFrameDuration, 0.034829, accuracy: 1e-5)
    }

    // MARK: - Word mapping

    func testWordsTakeTheTimesOfTheirOwnPhonemes() throws {
        let p = phonemizer()
        let love = ["L", "AH", "V"].compactMap(ArpabetVocabulary.index(of:))
        let me = ["M", "IY"].compactMap(ArpabetVocabulary.index(of:))
        let blank = ArpabetVocabulary.blankIndex
        let space = ArpabetVocabulary.separatorIndex
        // silence, then "love", a separator, then "me"
        let winners =
            [blank, blank, blank, blank] + love + [space] + me + [blank, blank]

        let model = ScriptedModel(
            melFramesPerWindow: 3 * winners.count, winners: winners, calls: .init())
        let mel = markedMel(frames: 3 * winners.count)
        let logProbs = try ForcedLyricAligner.posteriorgram(mel: mel, model: model)

        let (tokens, _) = LyricPhonemizer.tokenSequence(for: p.words(for: ["love", "me"]))
        let spans = try CTCForcedAlignment.align(
            logProbs: logProbs, tokens: tokens, blank: blank)

        // "love" occupies frames 4...6, so it must not start at 0 despite four silent frames.
        XCTAssertEqual(spans[0].startFrame, 4)
        XCTAssertGreaterThanOrEqual(spans.last!.startFrame, 8)
    }

    func testUnpronounceableWordGetsNoTimeRatherThanAGuess() throws {
        let p = phonemizer()
        let love = ["L", "AH", "V"].compactMap(ArpabetVocabulary.index(of:))
        let winners = [ArpabetVocabulary.blankIndex] + love + [ArpabetVocabulary.blankIndex]
        let model = ScriptedModel(
            melFramesPerWindow: 3 * winners.count, winners: winners, calls: .init())

        let aligned = try ForcedLyricAligner.align(
            samples: [Float](repeating: 0, count: LyricsAlignmentMel.hop * winners.count * 3),
            words: ["love", "biccuyecle"],
            model: model,
            phonemizer: p)

        XCTAssertEqual(aligned.count, 2)
        XCTAssertNotNil(aligned[0].start)
        XCTAssertNil(aligned[1].start, "no invented time for a word we cannot pronounce")
        XCTAssertNil(aligned[1].end)
        XCTAssertEqual(aligned[1].reason, .unpronounceable)
    }

    func testRejectsEmptyAudioAndUnpronounceableInput() {
        let model = ScriptedModel(melFramesPerWindow: 30, winners: [], calls: .init())
        XCTAssertThrowsError(
            try ForcedLyricAligner.align(samples: [], words: ["love"], model: model)
        ) { XCTAssertEqual($0 as? ForcedLyricAligner.Failure, .noAudio) }

        XCTAssertThrowsError(
            try ForcedLyricAligner.align(
                samples: [Float](repeating: 0, count: 5000), words: ["zzzz"], model: model,
                phonemizer: LyricPhonemizer(pronunciations: [:]))
        ) { XCTAssertEqual($0 as? ForcedLyricAligner.Failure, .noPronounceableWords) }
    }

    // MARK: - Windowing

    /// A song longer than one window must still produce one frame per three mel frames, with no
    /// duplicated or dropped frames at the seams — a splice error shifts every later word.
    func testWindowedPosteriorgramCoversTheSongExactlyOnce() throws {
        let melFrames = 3 * 400
        let winners = (0..<(melFrames / 3)).map { $0 % ArpabetVocabulary.classCount }
        let model = ScriptedModel(melFramesPerWindow: 3 * 120, winners: winners, calls: .init())

        let frames = try ForcedLyricAligner.posteriorgram(
            mel: markedMel(frames: melFrames), model: model)

        XCTAssertEqual(frames.count, melFrames / 3, "one output frame per three mel frames")
        XCTAssertGreaterThan(model.calls.count, 1, "fixture must actually require several windows")

        // Every frame must carry the class the song has at that position — proving the splice
        // preserved order and offset rather than merely producing the right count.
        for (index, row) in frames.enumerated() {
            let winner = row.firstIndex(of: row.max()!)!
            XCTAssertEqual(winner, winners[index], "frame \(index) came from the wrong window")
        }
    }

    func testShorterThanOneWindowIsPaddedAndTrimmed() throws {
        let melFrames = 3 * 20
        let winners = (0..<20).map { $0 % ArpabetVocabulary.classCount }
        let model = ScriptedModel(melFramesPerWindow: 3 * 120, winners: winners, calls: .init())

        let frames = try ForcedLyricAligner.posteriorgram(
            mel: markedMel(frames: melFrames), model: model)

        XCTAssertEqual(frames.count, 20, "padding must not leak into the output")
        XCTAssertEqual(model.calls.count, 1)
    }
}
