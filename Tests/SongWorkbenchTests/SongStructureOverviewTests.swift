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

    /// Regression (Eric, live review, 2026-07-07): "the composition of the chorus lists many
    /// patterns A B C D E F G H etc. But there seem to be a lot less than that, so maybe the
    /// criteria is off." Real per-line chord windows pick up timing jitter — the same underlying
    /// phrase's chord signature sometimes carries one extra/missing passing chord from one
    /// occurrence to the next. Under the OLD exact-`==` clustering, only the byte-identical
    /// occurrences of each phrase matched (["A","B","C","D","A","B"] — 4 distinct letters for 2
    /// real phrases); allowing one inserted passing chord while preserving sequence order folds
    /// the jittery occurrences into their real phrase (["A","B","A","B","A","B"] — exactly 2).
    func testJitteryChordSignaturesWithOnePassingChordStillClusterAsTheSamePhrase() {
        let signatures: [[String]] = [
            ["I", "IV", "V"],  // A
            ["vi", "ii", "V"],  // B
            ["I", "IV", "V", "vi"],  // A + one passing chord, ordered shared sequence
            ["vi", "ii", "V", "I"],  // B + one passing chord, ordered shared sequence
            ["I", "IV", "V"],  // A exactly
            ["vi", "ii", "V"],  // B exactly
        ]
        let syllables = [8, 8, 8, 8, 8, 8]
        XCTAssertEqual(
            MelodyPhraseProxy.phraseLetters(chordSignatures: signatures, syllableCounts: syllables),
            ["A", "B", "A", "B", "A", "B"])
    }

    func testReorderedChordSignaturesAreDifferentPhrases() {
        let signatures: [[String]] = [
            ["I", "V", "vi", "IV"],
            ["IV", "vi", "V", "I"],
        ]

        XCTAssertEqual(
            MelodyPhraseProxy.phraseLetters(
                chordSignatures: signatures, syllableCounts: [8, 8]),
            ["A", "B"])
    }

    /// Two lines with NO detected chord data at all must not blindly cluster together just
    /// because both signatures are empty — `chordSignaturesMatch`'s `a == b` branch does still
    /// match `[] == []`, matching the prior exact-equality behavior for this specific case, but
    /// this test pins that down explicitly since the tolerant Jaccard branch's own `!a.isEmpty`
    /// guard would otherwise silently do the opposite.
    func testTwoLinesWithNoChordDataStillClusterTogetherLikeTheOldExactMatchDid() {
        let signatures: [[String]] = [[], []]
        let syllables = [8, 8]
        XCTAssertEqual(
            MelodyPhraseProxy.phraseLetters(chordSignatures: signatures, syllableCounts: syllables),
            ["A", "A"])
    }
}

final class SongStructureOverviewBuilderTests: XCTestCase {
    /// End-to-end fixture: two verses sharing one chord pattern (I-V-vi-IV in C major), a
    /// wordless instrumental gap that reuses that SAME pattern (should read as a **Solo** —
    /// Eric: "a word-less verse or chorus pattern is usually a solo"), and a third worded
    /// section whose chords don't match either verse (should read as a **Bridge**, not
    /// "Verse 3"). No `sourceDuration` is set, so `TrailingLyricTailPruner` never activates
    /// and the default empty `words: []` on these fixtures is harmless.
    private func chordAndSoloFixture(
        soloPattern: [String] = ["C", "G", "Am", "F"],
        finalPattern: [String] = ["Eb", "Bb", "Cm", "Gm"]
    ) -> ChordProDraftInput {
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
            ]
                + soloPattern.enumerated().map {
                    EditableChordEvent(
                        time: 28 + Double($0.offset), chord: $0.element, confidence: 0.9)
                }
                + finalPattern.enumerated().map {
                    EditableChordEvent(
                        time: 38 + Double($0.offset) * 0.35, chord: $0.element, confidence: 0.9)
                },
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

    func testBridgeClassificationRejectsSameChordSetInDifferentOrder() {
        let overview = SongStructureOverviewBuilder().build(
            chordAndSoloFixture(finalPattern: ["F", "Am", "G", "C"]))

        let finalWordedSection = overview?.form.first {
            $0.lines.first?.text == "Nothing stays the same forever now"
        }
        XCTAssertEqual(finalWordedSection?.kind, .bridge)
    }

    func testSoloClassificationRejectsSameChordSetInDifferentOrder() {
        let overview = SongStructureOverviewBuilder().build(
            chordAndSoloFixture(soloPattern: ["F", "Am", "G", "C"]))

        let reorderedInstrumental = overview?.form.first { $0.start == 18 }
        XCTAssertEqual(reorderedInstrumental?.kind, .instrumental)
    }

    func testBridgeClassificationStillToleratesOneInsertedPassingChord() {
        let overview = SongStructureOverviewBuilder().build(
            chordAndSoloFixture(finalPattern: ["C", "G", "D", "Am", "F"]))

        let finalWordedSection = overview?.form.first {
            $0.lines.first?.text == "Nothing stays the same forever now"
        }
        XCTAssertEqual(finalWordedSection?.kind, .verse)
    }

    func testGenericInstrumentalGapWithNoChordsIsNotReclassifiedAsSolo() {
        let overview = SongStructureOverviewBuilder().build(chordAndSoloFixture())
        let plainGap = overview?.form.first { $0.label == "Instrumental" }
        XCTAssertNotNil(plainGap)
        XCTAssertEqual(plainGap?.kind, .instrumental)
    }

    func testKnownUntranscribedVocalGapCannotBeReclassifiedAsSolo() {
        var input = chordAndSoloFixture()
        input.untranscribedVocalRegions = [20...34]

        let overview = SongStructureOverviewBuilder().build(input)
        let missedVocalSection = overview?.form.first { $0.kind == .untranscribedVocal }

        XCTAssertNotNil(missedVocalSection)
        XCTAssertEqual(missedVocalSection?.label, "Vocals not transcribed")
        XCTAssertFalse(
            overview?.form.contains {
                ($0.kind == .instrumental || $0.kind == .solo)
                    && $0.start < 34 && $0.end > 20
            } ?? true)
    }

    func testShortUntranscribedVocalGapPreservesSurroundingVocalSections() {
        let input = ChordProDraftInput(
            title: "Continuous Verse",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "First line"),
                TimedLyricSegment(start: 4, end: 6, text: "Second line"),
            ],
            chords: [],
            untranscribedVocalRegions: [2.5...3.5]
        )

        let overview = SongStructureOverviewBuilder().build(input)

        XCTAssertEqual(
            overview.map { Array($0.form.prefix(3).map(\.kind)) },
            [.verse, .untranscribedVocal, .verse])
        XCTAssertEqual(overview.map { Array($0.form.prefix(3).map(\.start)) }, [0, 2.5, 4])
        XCTAssertEqual(overview?.form[0].lines.map(\.text), ["First line"])
        XCTAssertEqual(
            overview?.form.first { $0.start == 4 }?.lines.map(\.text), ["Second line"])
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

    /// Regression (Settle Down live review, 2026-07-07): with three verse-kind occurrences whose
    /// LINE COUNTS are all different (6, 4, 2 — no majority, an unstable tie under the old
    /// `mostCommonInt` line-count logic), the VERSE TEMPLATE's representative must be picked by
    /// CHORD-PATTERN majority (two of the three share `C-G-Am-F`) rather than by which line count
    /// happened to win an arbitrary Dictionary-iteration-order tie. Eric: "This seems like
    /// another place with too much dependence on lyrics" — live-observed picking the anomalous
    /// 2-line occurrence as "representative" (`Length: 2 lines`) purely because no other line
    /// count could out-vote it either.
    func testVerseTemplateRepresentativePicksChordPatternMajorityNotAnUnstableLineCountTie() {
        // Genuinely distinct wording per line (no shared template with only an index swapped —
        // that would Jaccard-match every line in a block against every other and misclassify the
        // whole block as a repeated chorus instead of a verse).
        func lines(_ texts: [String], at start: TimeInterval) -> [TimedLyricSegment] {
            texts.enumerated().map { i, text in
                TimedLyricSegment(
                    start: start + Double(i) * 2, end: start + Double(i) * 2 + 1.5, text: text)
            }
        }
        let verse1 = lines(
            [
                "Morning light breaks through the trees",
                "Coffee steam rises past my face",
                "Dog runs circles round the yard",
                "Neighbors wave from cars going by",
                "Radio plays a song I love",
                "Time moves slow on days like these",
            ], at: 0)
        let verse2 = lines(
            [
                "Evening falls across the field",
                "Crickets start their nightly song",
                "Porch light flickers on next door",
                "Stars come out one by one",
            ], at: 30)
        // The anomaly: fewest lines AND (below) a mismatched chord progression.
        let verse3 = lines(
            ["Thunder rolls beyond the hills", "Rain begins without a warning"], at: 60)
        // A real Chorus (Jaccard-matching itself between its two occurrences) sits between every
        // verse-kind block, exactly like Settle Down's real Verse-Chorus-Verse-Chorus-Bridge
        // shape — so `SongStructureAnalyzer`'s section splits are all genuine classification-
        // mismatch boundaries, not bare gap-only ones (keeps this fixture isolated to testing the
        // Task D representative-selection fix, not Task A's separate gap-fragment merge).
        let chorusLine = { (start: TimeInterval) in
            TimedLyricSegment(start: start, end: start + 1.5, text: "we all sing the same song")
        }
        let input = ChordProDraftInput(
            title: "Tie-Break Song",
            tempo: 120,
            lyrics: verse1 + [chorusLine(20)] + verse2 + [chorusLine(50)] + verse3,
            chords: [
                // Verse 1 (6 lines): the real verse progression.
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 3, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 6, chord: "Am", confidence: 0.9),
                EditableChordEvent(time: 9, chord: "F", confidence: 0.9),
                // Verse 2 (4 lines): SAME progression -- the two together form the majority.
                EditableChordEvent(time: 30, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 33, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 36, chord: "Am", confidence: 0.9),
                EditableChordEvent(time: 39, chord: "F", confidence: 0.9),
                // Verse "3" (2 lines): the anomaly -- fewest lines AND a different progression.
                EditableChordEvent(time: 60, chord: "Eb", confidence: 0.9),
                EditableChordEvent(time: 61, chord: "Bb", confidence: 0.9),
            ],
            estimatedKey: MusicalKey(root: .c, quality: .major)
        )
        let overview = SongStructureOverviewBuilder().build(input)
        let verseSections = overview?.form.filter { $0.kind == .verse }
        XCTAssertEqual(
            verseSections?.map(\.lines.count), [6, 4],
            "\(overview?.form.map { "\($0.label):\($0.kind)" } ?? [])")
        XCTAssertEqual(overview?.form.first(where: { $0.kind == .bridge })?.lines.count, 2)
        let verseTemplate = overview?.templates.first { $0.kind == .verse }
        XCTAssertNotNil(verseTemplate)
        // The representative must be Verse 1 or Verse 2 (6 or 4 lines, chord-pattern majority),
        // NEVER the 2-line anomaly -- and its chord pattern must be the shared majority one.
        XCTAssertNotEqual(verseTemplate?.lineCount, 2, "\(overview?.templates ?? [])")
        XCTAssertEqual(verseTemplate?.chordPattern, ["I", "V", "vi", "IV"])
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
