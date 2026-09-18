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

    // MARK: - Filling holes from measured onsets

    private func word(_ text: String, _ start: Double?, _ end: Double?)
        -> ForcedLyricAligner
        .AlignedWord
    {
        ForcedLyricAligner.AlignedWord(
            text: text, start: start, end: end, reason: start == nil ? .unpronounceable : nil)
    }

    /// One unmeasured word, one onset in the gap: the audio says where it is, so take it.
    func testFillsAHoleWhenTheGapHoldsExactlyOneOnset() {
        let words = [word("a", 1.0, 1.5), word("zzz", nil, nil), word("b", 3.0, 3.5)]
        let filled = ForcedLyricAligner.filledFromOnsets(words, onsets: [1.0, 2.1, 3.0])

        XCTAssertEqual(
            filled[1].start, 2.1, "the onset inside the gap is the word's measured start")
        XCTAssertEqual(filled[1].end, 3.0, "it lasts until the next measured event")
        XCTAssertNil(filled[1].reason)
    }

    func testFillsARunWhenOnsetCountMatchesWordCount() {
        let words = [
            word("a", 1.0, 1.5), word("x", nil, nil), word("y", nil, nil), word("b", 4.0, 4.5),
        ]
        let filled = ForcedLyricAligner.filledFromOnsets(words, onsets: [1.0, 2.0, 3.0, 4.0])

        XCTAssertEqual(filled[1].start, 2.0)
        XCTAssertEqual(filled[2].start, 3.0)
        XCTAssertEqual(filled[1].end, 3.0, "each word ends at the next measured onset")
    }

    /// The refusal that keeps this measurement rather than guesswork: with more onsets than words
    /// we would be CHOOSING which onset belongs to the word.
    func testLeavesHoleUnmeasuredWhenTheGapIsAmbiguous() {
        let words = [word("a", 1.0, 1.5), word("zzz", nil, nil), word("b", 5.0, 5.5)]

        let tooMany = ForcedLyricAligner.filledFromOnsets(
            words, onsets: [1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertNil(tooMany[1].start, "three candidate onsets, one word — do not pick one")

        let none = ForcedLyricAligner.filledFromOnsets(words, onsets: [1.0, 5.0])
        XCTAssertNil(none[1].start, "no onset in the gap means the audio does not say")
    }

    func testNeverInterpolatesBetweenNeighbours() {
        let words = [word("a", 1.0, 1.5), word("zzz", nil, nil), word("b", 5.0, 5.5)]
        let filled = ForcedLyricAligner.filledFromOnsets(words, onsets: [1.0, 5.0])
        // The midpoint 3.25 is exactly the plausible-looking answer this must never produce.
        XCTAssertNil(filled[1].start)
        XCTAssertNotEqual(filled[1].start, 3.25)
    }

    func testMeasuredWordsAreNeverDisturbed() {
        let words = [word("a", 1.0, 1.5), word("zzz", nil, nil), word("b", 3.0, 3.5)]
        let filled = ForcedLyricAligner.filledFromOnsets(words, onsets: [1.0, 2.1, 3.0])
        XCTAssertEqual(filled[0], words[0])
        XCTAssertEqual(filled[2], words[2])
    }

    func testHandlesHolesAtTheStartAndEnd() {
        let words = [word("first", nil, nil), word("a", 2.0, 2.5), word("last", nil, nil)]
        let filled = ForcedLyricAligner.filledFromOnsets(words, onsets: [0.5, 2.0, 9.0])
        XCTAssertEqual(filled[0].start, 0.5, "a leading hole is measurable from an onset before it")
        XCTAssertEqual(filled[2].start, 9.0, "so is a trailing one")
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
