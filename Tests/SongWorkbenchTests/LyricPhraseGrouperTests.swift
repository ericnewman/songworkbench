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

    func testNoOpWhenConstantHarmonyProvidesNoPeriodEvidence() {
        let words = eightBarChorusWords(
            startBar: 0,
            text: ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        let input = [line(words)]

        let result = LyricPhraseGrouper.regroup(
            input,
            beatTimes: uniformBeatTimes(bpm: 120, bars: 8),
            tempo: 120,
            chords: [chordEvent("C", at: 0)])

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

    /// Regression (Key West Bar field case): a genuinely NEW section (a chorus repeat, elsewhere
    /// Jaccard-matching an earlier chorus occurrence) that starts only a SHORT time (well under
    /// `SongStructureAnalyzer`'s 4s `sectionGap`) after the previous section's last line must
    /// still get its OWN section boundary — via the chorus/verse classification mismatch, not the
    /// gap — so `LyricPhraseGrouper`'s bar-period re-cut never pools the new section's words in
    /// with the previous section's, and can never steal the new section's first word onto the
    /// tail of the previous section's last re-cut line. Mirrors the real bug: "...and enjoy the
    /// vibe" (end of a verse-ish block) immediately followed, after only a couple of seconds, by
    /// "There's a place..." (the start of a chorus repeated verbatim later in the song).
    func testShortGapBeforeANewChorusOccurrenceNeverStealsItsFirstWordIntoThePreviousSection() {
        let versePart = eightBarChorusWords(
            startBar: 0, text: ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        // The chorus text also appears, verbatim, far later in the song (bar 40) so
        // `SongStructureAnalyzer`'s word-set Jaccard reliably classifies BOTH occurrences as
        // chorus — the classification-mismatch split does not depend on the gap being large.
        let chorusText = ["there's", "a", "place", "with", "no", "worries", "no", "racing"]
        // Starts at bar 8 -- i.e. immediately after the verse's 8 bars end, only the ~1.8s
        // still-inside-the-bar-grid gap between the verse's last word and the chorus's first
        // word (well under the analyzer's 4s `sectionGap`).
        let chorusOccurrenceA = eightBarChorusWords(startBar: 8, text: chorusText)
        let chorusOccurrenceB = eightBarChorusWords(startBar: 40, text: chorusText)
        let input = [line(versePart), line(chorusOccurrenceA), line(chorusOccurrenceB)]
        let chords =
            eightBarChords(startBar: 0) + eightBarChords(startBar: 8) + eightBarChords(startBar: 40)

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 48), tempo: 120, chords: chords)

        // The verse's re-cut lines must end on "four" / "eight" — never picking up "there's",
        // the chorus's first word — and the chorus's own first re-cut line must start cleanly on
        // "there's", never missing it to the verse above.
        XCTAssertTrue(
            result.contains { $0.text == "one two three four" }, "\(result.map(\.text))")
        XCTAssertTrue(
            result.contains { $0.text == "five six seven eight" }, "\(result.map(\.text))")
        XCTAssertFalse(
            result.contains { $0.text.hasSuffix("there's") && $0.text != "there's" },
            "verse line stole the chorus's first word: \(result.map(\.text))")
        XCTAssertTrue(
            result.contains { $0.text == "there's a place with" }, "\(result.map(\.text))")

        // And the section boundary itself must be genuinely there: both chorus occurrences are
        // recognized as chorus, the verse is not, confirming the split is real, not incidental.
        let sections = SongStructureAnalyzer().vocalSections(for: result)
        XCTAssertEqual(sections.filter { $0.kind == .chorus }.count, 2, "\(sections)")
        XCTAssertEqual(sections.filter { $0.kind == .verse }.count, 1, "\(sections)")
    }

    // MARK: - Cross-section pooling (Task #39 Phase B2)

    /// Two confidently-periodic 8-bar verses (period 4, clean `C G Am F` chords, distinct lyrics
    /// so `SongStructureAnalyzer` reads them as verse, not a repeated chorus) plus a THIRD, lone
    /// 8-bar verse occurrence whose own chords only coincidentally repeat at lag 4 in 2 of 4 bar
    /// pairs (confidence 0.5 alone — well under `minimumConfidence` 0.75, so `detectPeriod` could
    /// never apply period 4 to it by itself). Pooled across all three verse occurrences the
    /// aggregate clears the confidence floor (10 matches / 12 pairs = 0.833), so the lone verse
    /// must still get re-cut at the period-4 boundary — the literal "Verse 2 borrows the phrase
    /// period its sibling verses establish" case from tasks/todo.md Task #39, and the OLD
    /// per-occurrence-only logic would have left this section as one unsplit 8-word line.
    func testLoneVerseBorrowsThePeriodItsConfidentSiblingVersesEstablish() {
        let occurrenceA = eightBarChorusWords(
            startBar: 0, text: ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        // Disjoint vocabulary from A (and from the lone verse below) so none of the three read as
        // a Jaccard-matching chorus repeat of one another — all three classify as plain verse.
        let occurrenceB = eightBarChorusWords(
            startBar: 20,
            text: ["north", "star", "guides", "sailors", "through", "the", "dark", "water"])
        let lonelyWords = eightBarChorusWords(
            startBar: 400,
            text: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"])
        // Lag-4 pairs: (Bb,Bb) match, (Eb,Eb) match, (Cm,Fm) no, (Gm,Cdim) no -> 2/4 alone
        // (confidence 0.5, below the 0.75 floor) but pooled with A's and B's clean 4/4 each, the
        // aggregate is (4+4+2)/(4+4+4) = 10/12 = 0.833, clearing the floor.
        let lonelyChords = eightBarChords(
            startBar: 400, pattern: ["Bb", "Eb", "Cm", "Gm", "Bb", "Eb", "Fm", "Cdim"])

        let input = [line(occurrenceA), line(occurrenceB), line(lonelyWords)]
        let chords = eightBarChords(startBar: 0) + eightBarChords(startBar: 20) + lonelyChords

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 28), tempo: 120, chords: chords)

        let sections = SongStructureAnalyzer().vocalSections(for: result)
        XCTAssertEqual(sections.filter { $0.kind == .verse }.count, 3, "\(sections)")

        // The two confident occurrences still re-segment into 2 lines each, same as always.
        XCTAssertTrue(result.contains { $0.text == "one two three four" }, "\(result.map(\.text))")
        XCTAssertTrue(
            result.contains { $0.text == "five six seven eight" }, "\(result.map(\.text))")

        // The lone verse, isolated, could never prove period 4 on its own (0.5 confidence is below
        // `minimumConfidence`) — pooling must still apply the siblings' period 4 and re-cut it into
        // two 4-word cells rather than leaving the 8-word line untouched.
        XCTAssertTrue(
            result.contains { $0.text == "alpha beta gamma delta" }, "\(result.map(\.text))")
        XCTAssertTrue(
            result.contains { $0.text == "epsilon zeta eta theta" }, "\(result.map(\.text))")
    }

    // MARK: - Stage 2: rhyme/syllable nudge (PRD §3.4)

    /// A 12-bar/3-cell section (period 4 bars) where the globally-nearest word gap to the SECOND
    /// boundary (16s) would end the middle cell on "quickly" (no rhyme with either sibling, wrong
    /// syllable count), but a real word gap 0.2s farther away — still well inside the 1-beat (0.5s)
    /// nudge window — ends it on "night" instead, which rhymes with both the first cell's "light"
    /// and the trailing cell's "sight" and matches their syllable count. Hand-timed (not built from
    /// `eightBarChorusWords`) specifically to engineer that ordering.
    private func nudgeFixtureWords() -> [TimedLyricWord] {
        [
            word("morning", start: 0.2, end: 1.2),
            word("comes", start: 2.2, end: 3.2),
            word("with", start: 4.2, end: 5.2),
            word("light", start: 6.2, end: 7.2),
            word("singing", start: 8.2, end: 9.2),
            word("every", start: 10.2, end: 11.2),
            word("single", start: 12.2, end: 13.2),
            word("quickly", start: 15.0, end: 15.7),
            word("night", start: 16.0, end: 16.3),
            word("day", start: 16.4, end: 17.0),
            word("breaks", start: 18.2, end: 19.2),
            word("the", start: 20.2, end: 21.2),
            word("sight", start: 22.2, end: 23.2),
        ]
    }

    private func nudgeFixtureChords() -> [EditableChordEvent] {
        let pattern = ["C", "G", "Am", "F"]
        return (0..<12).map { i in chordEvent(pattern[i % 4], at: Double(i) * 2.0) }
    }

    /// Rhyme table for the fixture: "light"/"night"/"sight" share a rhyme key, "quickly" does not
    /// (and isn't given a competing match to anything).
    private func nudgeFixtureRhymeDetector() -> RhymeDetector {
        RhymeDetector(
            table: RhymeDetector.parseTable(
                """
                light\tAY T
                night\tAY T
                sight\tAY T
                quickly\tIH K L IY
                """))
    }

    func testStage2NudgesTheBoundaryToABetterRhymingSyllableMatchingWordGap() {
        let input = [line(nudgeFixtureWords())]

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 12), tempo: 120,
            chords: nudgeFixtureChords(), rhymeDetector: nudgeFixtureRhymeDetector())

        XCTAssertEqual(result.count, 3, "expected 3 phrase cells (2 boundaries)")
        XCTAssertEqual(result[0].text, "morning comes with light")
        XCTAssertEqual(
            result[1].text, "singing every single quickly night",
            "nudged to end on the rhyming/syllable-matching \"night\", not the nearer \"quickly\"")
        XCTAssertEqual(result[2].text, "day breaks the sight")
        // Every original word preserved exactly once — a nudge only relocates the cut, never drops
        // or duplicates a word.
        XCTAssertEqual(
            result.flatMap(\.words).map(\.text), nudgeFixtureWords().map(\.text))
    }

    func testStage2DisabledKeepsStage1sNearestInTimeBoundaryUnchanged() {
        let input = [line(nudgeFixtureWords())]

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 12), tempo: 120,
            chords: nudgeFixtureChords(), configuration: .init(refinementEnabled: false),
            rhymeDetector: nudgeFixtureRhymeDetector())

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(
            result[1].text, "singing every single quickly",
            "with Stage 2 disabled, the middle cell keeps Stage 1's nearest-in-time cut")
        XCTAssertEqual(result[2].text, "night day breaks the sight")
    }

    func testStage2KeepsBaselineWhenOnlySyllableEvidenceIsAvailable() {
        // Empty rhyme table: with no rhyme signal, whole-LINE syllable-count similarity to the
        // sibling median is the only thing left to judge candidates by — and extending the cut to
        // include "night" makes the line LONGER (9 -> 10 syllables), moving it FARTHER from the
        // sibling median (6, from the 6- and 4-syllable "light"/"sight" cells) than the shorter
        // baseline cut already sits. So syllable evidence alone does NOT favor this particular
        // nudge — confirming the main nudge test's result is driven by the RHYME signal, not an
        // accidental syllable-count coincidence.
        let input = [line(nudgeFixtureWords())]

        let result = LyricPhraseGrouper.regroup(
            input, beatTimes: uniformBeatTimes(bpm: 120, bars: 12), tempo: 120,
            chords: nudgeFixtureChords(), rhymeDetector: RhymeDetector(table: [:]))

        XCTAssertEqual(result[1].text, "singing every single quickly")
    }
}
