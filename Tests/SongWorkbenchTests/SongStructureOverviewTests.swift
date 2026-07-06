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
