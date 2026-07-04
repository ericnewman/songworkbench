import XCTest

@testable import SongWorkbench

final class LyricPhraseGrouperTests: XCTestCase {
    private func word(_ text: String, start: TimeInterval, end: TimeInterval) -> TimedLyricWord {
        TimedLyricWord(text: text, start: start, end: end, characterRange: 0..<text.count)
    }

    private func line(_ words: [TimedLyricWord]) -> TimedLyricSegment {
        TimedLyricSegment(
            start: words.first!.start,
            end: words.last!.end,
            text: words.map(\.text).joined(separator: " "),
            words: words)
    }

    private func chordEvent(_ chord: String, at time: TimeInterval) -> EditableChordEvent {
        EditableChordEvent(time: time, chord: chord)
    }

    /// A uniform beat grid at `bpm`, spanning `bars` full 4/4 bars from time 0.
    private func uniformBeatTimes(bpm: Double, bars: Int, beatsPerBar: Int = 4) -> [TimeInterval] {
        let beatLength = 60.0 / bpm
        let totalBeats = bars * beatsPerBar
        return (0...totalBeats).map { Double($0) * beatLength }
    }

    /// Builds one 8-bar (2 x 4-bar) chorus-shaped block starting at `startBar`: 8 words, one per
    /// bar, well inside each bar (never touching the bar edges except the last word, which is
    /// forced to reach the following bar's downbeat exactly so `floorDownbeat` includes the full
    /// final bar). `startOffsets` lets a caller apply small per-word jitter (ASR timing noise
    /// between two sung passes of the same chorus) without disturbing the overall shape.
    private func eightBarChorusWords(
        startBar: Int, text: [String], startOffsets: [TimeInterval] = Array(repeating: 0, count: 8)
    ) -> [TimedLyricWord] {
        precondition(text.count == 8 && startOffsets.count == 8)
        return (0..<8).map { i in
            let bar = startBar + i
            let barStart = Double(bar) * 2.0
            if i == 7 {
                // Last word spans the whole final bar so the section's bar range floors to
                // include it completely (see `LyricPhraseGrouper.floorDownbeat`).
                return word(text[i], start: barStart, end: barStart + 2.0)
            }
            let offset = startOffsets[i]
            return word(text[i], start: barStart + 0.2 + offset, end: barStart + 1.2 + offset)
        }
    }

    private func eightBarChords(startBar: Int, pattern: [String] = ["C", "G", "Am", "F"])
        -> [EditableChordEvent]
    {
        (0..<8).map { i in chordEvent(pattern[i % pattern.count], at: Double(startBar + i) * 2.0) }
    }

    // MARK: - No-op guards

    func testNoOpWhenBeatOrTempoOrChordDataIsMissing() {
        let input = [line([word("hello", start: 0, end: 1), word("world", start: 1.5, end: 2)])]

        XCTAssertEqual(
            LyricPhraseGrouper.regroup(
                input, beatTimes: [], tempo: 120, chords: [chordEvent("C", at: 0)]),
            input)
        XCTAssertEqual(
            LyricPhraseGrouper.regroup(
                input, beatTimes: uniformBeatTimes(bpm: 120, bars: 4), tempo: nil,
                chords: [chordEvent("C", at: 0)]),
            input)
        XCTAssertEqual(
            LyricPhraseGrouper.regroup(
                input, beatTimes: uniformBeatTimes(bpm: 120, bars: 4), tempo: 120, chords: []),
            input)
    }

    func testNoOpWhenNoCandidatePeriodClearsConfidenceFloor() {
        // 4 bars, every chord different — no candidate period's bar-label self-similarity can
        // clear the confidence floor, so the section is left completely unchanged.
        let words = [
            word("alpha", start: 0.2, end: 1.2),
            word("beta", start: 2.2, end: 3.2),
            word("gamma", start: 4.2, end: 5.2),
            word("delta", start: 6.2, end: 7.2),
        ]
        let input = [line(words)]
        let chords = [
            chordEvent("Bb", at: 0), chordEvent("Eb", at: 2), chordEvent("Cm", at: 4),
            chordEvent("Gm", at: 6),
        ]

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 4), tempo: 120, chords: chords)

        XCTAssertEqual(result, input)
    }

    // MARK: - Core re-segmentation

    func testResegmentsACleanFourBarPeriodIntoTwoLines() {
        let words = eightBarChorusWords(
            startBar: 0, text: ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        let input = [line(words)]
        let chords = eightBarChords(startBar: 0)

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 8), tempo: 120, chords: chords)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "one two three four")
        XCTAssertEqual(result[1].text, "five six seven eight")
        // Every original word is preserved exactly once — the pass only re-cuts, never drops.
        XCTAssertEqual(result.flatMap(\.words).map(\.text), words.map(\.text))
    }

    func testNeverMergesWordsAcrossASectionBoundary() {
        // Two independent 8-bar/4-bar-period blocks, far enough apart (and with disjoint
        // vocabulary) to form two separate vocal sections. Confirms re-segmentation never
        // produces a cell straddling both.
        let wordsA = eightBarChorusWords(
            startBar: 0, text: ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        let wordsB = eightBarChorusWords(
            startBar: 12,
            text: ["cat", "dog", "bird", "fish", "lion", "wolf", "hawk", "seal"])
        let input = [line(wordsA), line(wordsB)]
        let chords = eightBarChords(startBar: 0) + eightBarChords(startBar: 12)

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 20), tempo: 120, chords: chords)

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(
            result.map(\.text),
            [
                "one two three four", "five six seven eight",
                "cat dog bird fish", "lion wolf hawk seal",
            ])
    }

    // MARK: - Safety fallbacks

    func testFallsBackWhenSectionHasNoPerWordData() {
        // An older analysis without stored per-word timings — the section otherwise has a clean,
        // confident period, but with no words to re-cut at, the whole section must be left alone.
        let noWordsSegment = TimedLyricSegment(
            start: 0.2, end: 16.0, text: "one two three four five six seven eight", words: [])
        let chords = eightBarChords(startBar: 0)

        let result = LyricPhraseGrouper.regroup(
            [noWordsSegment], beatTimes: uniformBeatTimes(bpm: 120, bars: 8), tempo: 120,
            chords: chords)

        XCTAssertEqual(result, [noWordsSegment])
    }

    func testRejectsAResultingCellThatWouldExceedTheLineLengthCaps() {
        let words = eightBarChorusWords(
            startBar: 0, text: ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        let input = [line(words)]
        let chords = eightBarChords(startBar: 0)

        // Each computed cell would hold 4 words, so a cap of 2 must reject the whole section
        // rather than emit an over-long line.
        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 8), tempo: 120, chords: chords,
            configuration: .init(maximumLineTokens: 2))

        XCTAssertEqual(result, input)
    }

    // MARK: - Chorus-determinism regression (PRD §4)

    func testChorusOccurrencesShareOnePeriodAndStayDetectableAsChorusAfterRegrouping() {
        // Two occurrences of the same 8-bar chorus, far apart in time, the second with small
        // per-word ASR timing jitter (as if re-sung/re-transcribed slightly differently). Both
        // must re-segment to the SAME two-line shape with matching text, so
        // `SongStructureAnalyzer`'s word-set-Jaccard chorus detection still recognizes them as
        // the same chorus after regrouping — not two structurally different blocks.
        let text = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        let occurrenceA = eightBarChorusWords(startBar: 4, text: text)
        let jitter: [TimeInterval] = [0.05, -0.03, 0.04, -0.02, 0.03, -0.04, 0.02, 0]
        let occurrenceB = eightBarChorusWords(startBar: 20, text: text, startOffsets: jitter)

        let input = [line(occurrenceA), line(occurrenceB)]
        let chords = eightBarChords(startBar: 4) + eightBarChords(startBar: 20)

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 28), tempo: 120, chords: chords)

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(
            result.map(\.text),
            [
                "one two three four", "five six seven eight",
                "one two three four", "five six seven eight",
            ])

        let sections = SongStructureAnalyzer().vocalSections(for: result)
        let chorusSections = sections.filter { $0.kind == .chorus }
        XCTAssertEqual(
            chorusSections.count, 2,
            "both chorus occurrences must still be recognized as chorus blocks after regrouping")
    }
}
