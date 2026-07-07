import XCTest

@testable import SongWorkbench

final class RomanNumeralMapperTests: XCTestCase {
    func testMapsBasicMajorKeyChordsToUpperAndLowerCaseNumerals() {
        let key = MusicalKey(root: .g, quality: .major)
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "G", in: key), "I")
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "D", in: key), "V")
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "Em", in: key), "vi")
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "C", in: key), "IV")
    }

    func testMapsSeventhsAndMinorKeyDegreesIncludingTheRaisedFifth() {
        let key = MusicalKey(root: .a, quality: .minor)
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "Am", in: key), "i")
        // E7 (the harmonic-minor V) reads as a MAJOR/dominant chord even in a minor key,
        // so it gets an uppercase numeral despite sitting on the minor scale's 5th degree.
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "E7", in: key), "V7")
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "G", in: key), "VII")
    }

    func testFallsBackToTheBareLabelForAnUnparseableChord() {
        let key = MusicalKey(root: .c, quality: .major)
        XCTAssertEqual(RomanNumeralMapper.numeral(for: "N.C.", in: key), "N.C.")
    }
}

final class MelodyPhraseProxyTests: XCTestCase {
    func testGroupsLinesSharingChordPatternAndCloseSyllableCountUnderOneLetter() {
        let signatures: [[String]] = [["I", "IV"], ["I", "IV"], ["ii", "V"], ["I", "IV"]]
        let syllables = [8, 8, 7, 9]
        XCTAssertEqual(
            MelodyPhraseProxy.phraseLetters(chordSignatures: signatures, syllableCounts: syllables),
            ["A", "A", "B", "A"])
    }

    func testSameChordPatternButFarApartSyllableCountsGetDifferentLetters() {
        let signatures: [[String]] = [["I", "IV"], ["I", "IV"]]
        let syllables = [6, 10]
        XCTAssertEqual(
            MelodyPhraseProxy.phraseLetters(chordSignatures: signatures, syllableCounts: syllables),
            ["A", "B"])
    }
}

final class SongStructureOverviewBuilderTests: XCTestCase {
    /// End-to-end fixture: two verses sharing one chord pattern (I-V-vi-IV in C major), a
    /// wordless instrumental gap that reuses that SAME pattern (should read as a **Solo** —
    /// Eric: "a word-less verse or chorus pattern is usually a solo"), and a third worded
    /// section whose chords don't match either verse (should read as a **Bridge**, not
    /// "Verse 3"). No `sourceDuration` is set, so `TrailingLyricTailPruner` never activates
    /// and the default empty `words: []` on these fixtures is harmless.
    private func chordAndSoloFixture() -> ChordProDraftInput {
        ChordProDraftInput(
            title: "Bridge and Solo Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "Woke up alone under grey skies"),
                TimedLyricSegment(start: 2, end: 4, text: "Nobody called nobody tried"),
                TimedLyricSegment(start: 14, end: 16, text: "Drove to the coast just to breathe"),
                TimedLyricSegment(
                    start: 16, end: 18, text: "Trying to leave what I could not leave"),
                TimedLyricSegment(start: 38, end: 40, text: "Nothing stays the same forever now"),
            ],
            chords: [
                // Verse 1: I-V-vi-IV
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 1, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 2, chord: "Am", confidence: 0.9),
                EditableChordEvent(time: 3, chord: "F", confidence: 0.9),
                // Verse 2: same pattern
                EditableChordEvent(time: 14, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 15, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 16, chord: "Am", confidence: 0.9),
                EditableChordEvent(time: 17, chord: "F", confidence: 0.9),
                // Wordless gap [18, 38): reuses the verse pattern exactly -> should read Solo.
                EditableChordEvent(time: 28, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 29, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 30, chord: "Am", confidence: 0.9),
                EditableChordEvent(time: 31, chord: "F", confidence: 0.9),
                // Worded section with an unrelated chord pattern -> should read Bridge.
                EditableChordEvent(time: 38, chord: "Eb", confidence: 0.9),
                EditableChordEvent(time: 38.5, chord: "Bb", confidence: 0.9),
                EditableChordEvent(time: 39, chord: "Cm", confidence: 0.9),
                EditableChordEvent(time: 39.5, chord: "Gm", confidence: 0.9),
            ],
            estimatedKey: MusicalKey(root: .c, quality: .major)
        )
    }

    func testWordlessGapMatchingTheVerseChordPatternBecomesASolo() {
        let overview = SongStructureOverviewBuilder().build(chordAndSoloFixture())
        XCTAssertNotNil(overview)
        let kinds = overview?.form.map(\.kind)
        XCTAssertEqual(
            kinds,
            [.verse, .instrumental, .verse, .solo, .bridge, .outro],
            "form: \(overview?.form.map { "\($0.label):\($0.kind)" } ?? [])")
    }

    func testWordedSectionWithMismatchedChordsBecomesABridgeNotAThirdVerse() {
        let overview = SongStructureOverviewBuilder().build(chordAndSoloFixture())
        let bridge = overview?.form.first { $0.kind == .bridge }
        XCTAssertNotNil(bridge)
        XCTAssertEqual(bridge?.label, "Bridge")
        XCTAssertEqual(bridge?.lines.first?.text, "Nothing stays the same forever now")
    }

    func testGenericInstrumentalGapWithNoChordsIsNotReclassifiedAsSolo() {
        let overview = SongStructureOverviewBuilder().build(chordAndSoloFixture())
        let plainGap = overview?.form.first { $0.label == "Instrumental" }
        XCTAssertNotNil(plainGap)
        XCTAssertEqual(plainGap?.kind, .instrumental)
    }

    func testVerseTemplateCapturesTheSharedChordPatternAndLineCount() {
        let overview = SongStructureOverviewBuilder().build(chordAndSoloFixture())
        let verseTemplate = overview?.templates.first { $0.kind == .verse }
        XCTAssertNotNil(verseTemplate)
        XCTAssertEqual(verseTemplate?.lineCount, 2)
        XCTAssertEqual(verseTemplate?.chordPattern, ["I", "V", "vi", "IV"])
        XCTAssertEqual(verseTemplate?.meterPattern.count, 2)
        XCTAssertEqual(verseTemplate?.rhymeScheme.count, 2)
        XCTAssertEqual(verseTemplate?.phrasePattern.count, 2)
    }

    func testBridgeTemplateUsesItsOwnMismatchedChordPattern() {
        let overview = SongStructureOverviewBuilder().build(chordAndSoloFixture())
        let bridgeTemplate = overview?.templates.first { $0.kind == .bridge }
        XCTAssertNotNil(bridgeTemplate)
        XCTAssertEqual(bridgeTemplate?.chordPattern, ["bIII", "bVII", "i", "v"])
    }

    func testReturnsNilForEmptyLyrics() {
        let input = ChordProDraftInput(title: "Empty", tempo: 120, lyrics: [], chords: [])
        XCTAssertNil(SongStructureOverviewBuilder().build(input))
    }
}

/// Builds `SongStructureOverview` values directly (bypassing `SongStructureOverviewBuilder`'s
/// section-detection heuristics like `SongStructureAnalyzer`'s word-Jaccard chorus/verse split)
/// so these tests exercise ONLY `StructureAlignmentDiagnostics` against controlled Form/Template
/// data. The builder's own detection logic (verse-vs-chorus classification, section boundaries)
/// is already covered by `SongStructureOverviewBuilderTests`; re-fighting it here to also land
/// on plain "Verse" sections would make these tests fragile for no benefit.
final class StructureAlignmentDiagnosticsTests: XCTestCase {
    private func line(_ start: TimeInterval, _ end: TimeInterval, _ text: String)
        -> TimedLyricSegment
    {
        TimedLyricSegment(start: start, end: end, text: text)
    }

    /// One chord event per line, matching `chordCountPattern`'s per-line count of 1 exactly —
    /// chord-count corroboration is intentionally a non-issue in these tests (they target the
    /// required meter+rhyme signals), so every line always agrees with the template here.
    private func chordsPerLine(startingAt times: [TimeInterval]) -> [EditableChordEvent] {
        times.map { EditableChordEvent(time: $0, chord: "C", confidence: 0.9) }
    }

    /// A small, hand-built rhyme table in the same format `RhymeDetectorTests` uses — the SPM
    /// test bundle doesn't host the app target's `Resources/`, so `RhymeDetector.shared` resolves
    /// every word to "no entry" here. "window" gets its own distinct rhyme part so it reads as a
    /// genuine, resolvable-but-different rhyme (not just an out-of-vocabulary "-").
    private func testDetector() -> RhymeDetector {
        RhymeDetector(
            table: RhymeDetector.parseTable(
                """
                cat\tAE T
                hat\tAE T
                dog\tAO G
                frog\tAO G
                window\tIH N D OW
                """))
    }

    func testFlagsOnlyTheLineThatBreaksBothMeterAndRhyme() {
        let builder = SongStructureOverviewBuilder()
        let detector = testDetector()

        // Verse 1 is the template's representative occurrence — an AABB rhyme scheme
        // ("cat"/"hat", "dog"/"frog"). Its OWN real syllable/rhyme values (computed via the
        // same helpers the diagnostic uses) become the template, so this test isn't guessing
        // magic numbers for the counter/dictionary's actual output.
        let verse1Lines = [
            line(0, 2, "I pet the cat"),
            line(2, 4, "I found my hat"),
            line(4, 6, "I walked the dog"),
            line(6, 8, "beside a little frog"),
        ]
        let meterPattern = verse1Lines.map(builder.syllableCount(for:))
        let rhymeScheme = builder.rhymeScheme(for: verse1Lines, detector: detector)
        XCTAssertEqual(rhymeScheme, ["A", "A", "B", "B"], "fixture assumption: cat/hat/dog/frog")

        let template = SongStructureOverview.PhraseTemplate(
            kind: .verse, lineCount: 4, phrasePattern: [], chordPattern: [],
            meterPattern: meterPattern, rhymeScheme: rhymeScheme,
            chordCountPattern: [1, 1, 1, 1])

        // Verse 2: lines 1, 2, and 4 match verse 1 verbatim (zero deviation expected); line 3
        // is swapped for a long, unrelated line that breaks BOTH the meter (far more syllables)
        // and the rhyme (an unrelated ending word) — the exact shape of bug this targets: a
        // run-on/mis-split line inside an otherwise-regular verse.
        let deviatingLine = line(
            24, 26, "Yesterday I wandered around the entire town looking for a window")
        let verse2Lines = [
            line(20, 22, "I pet the cat"),
            line(22, 24, "I found my hat"),
            deviatingLine,
            line(26, 28, "beside a little frog"),
        ]
        // Sanity: the deviating line really does break both signals against the template — its
        // established rhyme partner is line 4 ("frog"), and "window" doesn't rhyme with it.
        XCTAssertGreaterThanOrEqual(
            abs(builder.syllableCount(for: deviatingLine) - meterPattern[2]), 2)
        XCTAssertFalse(detector.rhymes("window", "frog"))

        let verse1 = SongStructureOverview.Section(
            label: "Verse", kind: .verse, start: 0, end: 8, lines: verse1Lines,
            chords: chordsPerLine(startingAt: [0, 2, 4, 6]))
        let verse2 = SongStructureOverview.Section(
            label: "Verse", kind: .verse, start: 20, end: 28, lines: verse2Lines,
            chords: chordsPerLine(startingAt: [20, 22, 24, 26]))
        let overview = SongStructureOverview(
            title: "Cat and Hat", form: [verse1, verse2], templates: [template])

        let anomalies = StructureAlignmentDiagnostics.anomalies(in: overview, detector: detector)

        XCTAssertEqual(anomalies.count, 1, "unexpected anomalies: \(anomalies)")
        XCTAssertEqual(Array(anomalies.keys), [deviatingLine.id])
        XCTAssertTrue(
            anomalies[deviatingLine.id]?.contains("breaks the established rhyme") == true)

        // The other three lines of verse 2 (and all of verse 1, which the template came from)
        // must NOT be flagged.
        for otherLine in verse1Lines + verse2Lines where otherLine.id != deviatingLine.id {
            XCTAssertNil(anomalies[otherLine.id], "unexpected flag on \"\(otherLine.text)\"")
        }
    }

    /// A 3-line verse occurrence compared against a 4-line template — a mismatched line count
    /// can't be compared position-by-position, so it should be flagged as a whole (on its first
    /// line) rather than silently skipped.
    func testFlagsALineCountMismatchOnTheFirstLineOfTheShortOccurrence() {
        let template = SongStructureOverview.PhraseTemplate(
            kind: .verse, lineCount: 4, phrasePattern: [], chordPattern: [],
            meterPattern: [4, 4, 4, 6], rhymeScheme: ["A", "A", "B", "B"],
            chordCountPattern: [1, 1, 1, 1])
        let shortVerseLines = [
            line(40, 42, "I pet the cat"),
            line(42, 44, "I found my hat"),
            line(44, 46, "I walked the dog"),
        ]
        let shortVerse = SongStructureOverview.Section(
            label: "Verse", kind: .verse, start: 40, end: 46, lines: shortVerseLines,
            chords: chordsPerLine(startingAt: [40, 42, 44]))
        let overview = SongStructureOverview(
            title: "Missing Last Line", form: [shortVerse], templates: [template])

        let anomalies = StructureAlignmentDiagnostics.anomalies(in: overview)

        XCTAssertEqual(anomalies.count, 1, "unexpected anomalies: \(anomalies)")
        XCTAssertEqual(Array(anomalies.keys), [shortVerseLines[0].id])
        XCTAssertTrue(anomalies[shortVerseLines[0].id]?.contains("Line count") == true)
    }
}
