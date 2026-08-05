import XCTest

@testable import SongWorkbench

final class ChordProDraftBuilderTests: XCTestCase {
    func testInterludeCommentMarksLongInstrumentalGapUsingBeats() {
        // Beats every 0.5s (120 BPM). The gap [2, 12] holds ~19 beats ≈ 4.75 bars.
        let beats = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let input = ChordProDraftInput(
            title: "Gap Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "First line"),
                TimedLyricSegment(start: 12, end: 14, text: "Second line"),
            ],
            chords: [],
            beatTimes: beats
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(document.contains("{comment: Instrumental"), document)
    }

    func testKnownUntranscribedVocalsAreNotLabeledInstrumental() {
        let beats = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let input = ChordProDraftInput(
            title: "Missed Vocal Gap",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "First line"),
                TimedLyricSegment(start: 12, end: 14, text: "Second line"),
            ],
            chords: [],
            beatTimes: beats,
            untranscribedVocalRegions: [3...11]
        )

        let document = ChordProDraftBuilder().build(input)

        XCTAssertTrue(document.contains("{comment: Vocals not transcribed"), document)
        XCTAssertFalse(document.contains("{comment: Instrumental"), document)
    }

    func testStructureAnalyzerLabelsRepeatedSectionsAsChorus() {
        let lyrics = [
            TimedLyricSegment(start: 0, end: 2, text: "Friday night is coming"),
            TimedLyricSegment(start: 2, end: 4, text: "With little jeans in my hand"),
            TimedLyricSegment(start: 4, end: 6, text: "It's a party going on"),
            TimedLyricSegment(start: 6, end: 8, text: "Shout it loud till the dawn"),
            TimedLyricSegment(start: 20, end: 22, text: "Drinks start a flowing now"),
            TimedLyricSegment(start: 22, end: 24, text: "Strangers turn into friends"),
            TimedLyricSegment(start: 24, end: 26, text: "It's a party going on"),
            TimedLyricSegment(start: 26, end: 28, text: "Shout it loud till the dawn"),
        ]
        let sections = SongStructureAnalyzer().vocalSections(for: lyrics)
        XCTAssertEqual(sections.map(\.label), ["Verse 1", "Chorus", "Verse 2", "Chorus"])
        XCTAssertEqual(sections.map(\.kind), [.verse, .chorus, .verse, .chorus])
    }

    func testChordProLabelsVersesAndChoruses() {
        let input = ChordProDraftInput(
            title: "Party",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "Friday night is coming"),
                TimedLyricSegment(start: 2, end: 4, text: "With little jeans in my hand"),
                TimedLyricSegment(start: 4, end: 6, text: "It's a party going on"),
                TimedLyricSegment(start: 6, end: 8, text: "Shout it loud till the dawn"),
                TimedLyricSegment(start: 20, end: 22, text: "Drinks start a flowing now"),
                TimedLyricSegment(start: 22, end: 24, text: "Strangers turn into friends"),
                TimedLyricSegment(start: 24, end: 26, text: "It's a party going on"),
                TimedLyricSegment(start: 26, end: 28, text: "Shout it loud till the dawn"),
            ],
            chords: [],
            beatTimes: []
        )
        let doc = ChordProDraftBuilder().build(input)
        XCTAssertTrue(doc.contains("{start_of_verse: Verse 1}"), doc)
        XCTAssertTrue(doc.contains("{start_of_chorus}"), doc)
        XCTAssertTrue(doc.contains("{start_of_verse: Verse 2}"), doc)
        // Four sections total (Verse 1, Chorus, Verse 2, Chorus — the big gap before "Drinks
        // start..." splits the two chorus occurrences into separate sections); every opened
        // section must be closed, none left dangling.
        XCTAssertEqual(doc.components(separatedBy: "{start_of_verse").count - 1, 2)
        XCTAssertEqual(doc.components(separatedBy: "{end_of_verse}").count - 1, 2)
        XCTAssertEqual(doc.components(separatedBy: "{start_of_chorus}").count - 1, 2)
        XCTAssertEqual(doc.components(separatedBy: "{end_of_chorus}").count - 1, 2)
    }

    /// Regression: a same-section instrumental gap (bars-based threshold) must not fragment
    /// one continuous verse into two directive blocks — only a genuine new
    /// `SongStructureAnalyzer` section may close/open `{start_of_verse}`/`{start_of_chorus}`.
    /// The two gap thresholds are independent (bars vs. `SongStructureAnalyzer`'s flat 4s
    /// `sectionGap`), so a fast tempo can put ≥4 bars inside well under 4 seconds — dense beats
    /// every 0.1s (300 BPM) put comfortably more than 4 bars in the 3.8s gap between the first
    /// two lines below, enough to trigger the gap-based "Instrumental" comment line while
    /// staying under the analyzer's 4s section-split gap, so both lines must stay inside the
    /// SAME open verse.
    func testSectionDirectivesStayOpenAcrossAnInstrumentalGapWithinOneSection() {
        // Dense beats give plenty of margin over the 4-bar threshold regardless of the exact
        // counting convention at the window edges; what's under test is the 3.8s gap (< the
        // analyzer's 4.0s sectionGap) between the first two lines, alongside a comfortably
        // ≥4-bar count. A third, textually-unrelated line after a real (>=4s) gap gives the
        // song a second section, since a single-section clip gets no directives at all
        // (`vocalSections.count >= 2` gate) — the property under test is that the first two
        // lines share ONE open verse, not that directives exist at all.
        let beats = stride(from: 0.0, through: 20.0, by: 0.1).map { $0 }
        let input = ChordProDraftInput(
            title: "One Verse",
            tempo: 300,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "First line of the verse"),
                TimedLyricSegment(start: 5.8, end: 7.8, text: "Second line of the same verse"),
                TimedLyricSegment(start: 15, end: 17, text: "A totally different later verse"),
            ],
            chords: [],
            beatTimes: beats
        )
        let doc = ChordProDraftBuilder().build(input)
        XCTAssertTrue(doc.contains("{comment: Instrumental"), doc)
        XCTAssertEqual(doc.components(separatedBy: "{start_of_verse").count - 1, 2, doc)
        XCTAssertEqual(doc.components(separatedBy: "{end_of_verse}").count - 1, 2, doc)
        // The instrumental gap must sit INSIDE the first verse's block, not split it: both of
        // its lines appear before that verse's single close directive.
        guard let firstClose = doc.range(of: "{end_of_verse}") else {
            return XCTFail("no {end_of_verse} found in:\n\(doc)")
        }
        let beforeFirstClose = doc[doc.startIndex..<firstClose.lowerBound]
        XCTAssertTrue(beforeFirstClose.contains("First line of the verse"))
        XCTAssertTrue(beforeFirstClose.contains("Second line of the same verse"))
    }

    func testShortGapDoesNotInsertInterludeComment() {
        let input = ChordProDraftInput(
            title: "Tight Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "First line"),
                TimedLyricSegment(start: 2.5, end: 4, text: "Second line"),
            ],
            chords: [],
            beatTimes: stride(from: 0.0, through: 4.0, by: 0.5).map { $0 }
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertFalse(document.contains("{comment: Instrumental"), document)
    }

    func testLongInstrumentalSplitsIntoSeveralRows() {
        // 120 BPM → 1 bar = 2s. Two 2-bar sung lines (typical = 2 bars) and an 8-bar intro
        // (0→16s) full of chords. The intro must break into ~4 chord-only rows, not one wide line.
        var introChords: [EditableChordEvent] = []
        for i in stride(from: 0.0, to: 16.0, by: 2.0) {
            introChords.append(EditableChordEvent(time: i, chord: "C", confidence: 0.9))
        }
        let input = ChordProDraftInput(
            title: "Long Intro",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 16, end: 18, text: "First line here"),
                TimedLyricSegment(start: 18, end: 20, text: "Second line here"),
            ],
            chords: introChords,
            beatTimes: stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        )
        let document = ChordProDraftBuilder().build(input)
        // Count chord-only rows before the lyrics. B2: a chord-only row is now bar-aligned pipe
        // text (`| [C] | [C] . [C] |`) rather than proportionally spaced brackets, so a row counts
        // as chord-only when — after stripping `[chord]` tokens — only bar/beat punctuation
        // (`|`, `.`, spaces) remains, no lyric letters.
        let intro = document.components(separatedBy: "First line").first ?? document
        let chordOnlyRows = intro.split(separator: "\n").filter { row in
            let s = String(row)
            guard s.contains("["), !s.hasPrefix("{") else { return false }
            let stripped = s.replacingOccurrences(
                of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            let remainder = stripped.trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty || remainder.allSatisfy { "| .".contains($0) }
        }
        XCTAssertGreaterThan(
            chordOnlyRows.count, 1,
            "expected the 8-bar intro to split into multiple rows, got \(chordOnlyRows.count):\n\(document)"
        )
    }

    func testInstrumentalRowBoundariesLandOnBarDownbeats() {
        // 120 BPM, 4/4 → bars every 2 s. A 9-bar span that starts MID-bar (0.3 s): equal slicing
        // would put boundaries at 4.8/9.3/13.8 — every row starting on a different beat of its
        // bar, which rendered as staircase indents. Interior boundaries must snap to downbeats;
        // only the first row keeps the section's real (mid-bar) start.
        let grid = MeasureGrid(
            beatTimes: stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }, bpm: 120)
        let boundaries = ChordProDraftBuilder().barAlignedBoundaries(
            start: 0.3, end: 18.3, count: 4, grid: grid)
        XCTAssertEqual(boundaries.first, 0.3)
        XCTAssertEqual(boundaries.last, 18.3)
        for boundary in boundaries.dropFirst().dropLast() {
            XCTAssertEqual(
                boundary.truncatingRemainder(dividingBy: 2.0), 0, accuracy: 0.0001,
                "interior boundary \(boundary) is not on a bar downbeat")
        }
        XCTAssertEqual(boundaries, boundaries.sorted(), "boundaries must be increasing")
        XCTAssertGreaterThan(boundaries.count, 3, "a 9-bar span should still split into rows")
    }

    func testInstrumentalRowsAreUniformWholeBars() {
        // Musically equal rows must be pixel-equal rows: every interior gap is exactly the same
        // whole number of bars (the first/last rows absorb the mid-bar entry and remainder).
        let grid = MeasureGrid(
            beatTimes: stride(from: 0.0, through: 40.0, by: 0.5).map { $0 }, bpm: 120)
        let boundaries = ChordProDraftBuilder().barAlignedBoundaries(
            start: 0.3, end: 18.3, count: 4, grid: grid)
        let inner = boundaries.dropFirst().dropLast()
        let interior = zip(inner.dropFirst(), inner).map(-)
        for gap in interior {
            XCTAssertEqual(gap, interior[0], accuracy: 0.0001, "rows must span equal bars")
        }
        XCTAssertEqual(
            interior[0].truncatingRemainder(dividingBy: 2.0), 0, accuracy: 0.0001,
            "row span must be a whole number of bars")
    }

    func testGapChordsEarlierThanTheGutterStayInThePreviousLinesTail() {
        // 120 BPM (0.5 s beats, 2 s bars). Two lines with a 6 s gap (12 beats, 3 bars — short
        // of the 4-bar instrumental threshold). Gap chords at 4 beats and 1 beat before the
        // next line: only the 1-beat one is a renderable anticipation (the pickup gutter is
        // 2 beats); the 4-beat-early one must stay in the previous line's tail, or it renders
        // clamp-piled at the next row's left edge with any neighbours ("3 chords basically on
        // a single beat").
        let input = ChordProDraftInput(
            title: "Attachment",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 2, end: 4, text: "First line here"),
                TimedLyricSegment(start: 10, end: 12, text: "Second line here"),
            ],
            chords: [
                EditableChordEvent(time: 2.2, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 8.0, chord: "F", confidence: 0.9),
                EditableChordEvent(time: 9.5, chord: "G", confidence: 0.9),
            ],
            beatTimes: stride(from: 0.0, through: 16.0, by: 0.5).map { $0 }
        )
        let result = ChordProDraftBuilder().buildResult(input)
        let lyricRows = result.timeline.rows.filter(\.isLyric)
        XCTAssertEqual(lyricRows.count, 2)
        // F (2.0 s = 4 beats early) belongs to line 1's tail; G (0.5 s = 1 beat early) leads
        // line 2.
        XCTAssertTrue(
            lyricRows[0].chordTimes.contains(where: { abs($0 - 8.0) < 0.001 }),
            "4-beat-early chord must stay in the previous line's tail, "
                + "got \(lyricRows[0].chordTimes)")
        XCTAssertFalse(
            lyricRows[1].chordTimes.contains(where: { abs($0 - 8.0) < 0.001 }),
            "4-beat-early chord must not lead the next line")
        XCTAssertTrue(
            lyricRows[1].chordTimes.contains(where: { abs($0 - 9.5) < 0.001 }),
            "1-beat-early chord is a true anticipation and leads the next line")
    }

    func testStaleChartDetectionByAlgorithmTag() {
        // No identifier (pre-versioning chart) and old-format identifiers are stale; a chart
        // stamped by the CURRENT algorithm version is not.
        XCTAssertTrue(ChordProDraftBuilder.isOutputStale(configurationIdentifier: nil))
        XCTAssertTrue(
            ChordProDraftBuilder.isOutputStale(configurationIdentifier: "confidence-60"))
        XCTAssertTrue(
            ChordProDraftBuilder.isOutputStale(configurationIdentifier: "alg0-confidence-60"))
        XCTAssertFalse(
            ChordProDraftBuilder.isOutputStale(
                configurationIdentifier: "\(ChordProDraftBuilder.algorithmTag)-confidence-60"))
    }

    func testDegenerateSnapsMergeRowsInsteadOfCreatingEmptyOnes() {
        // A span shorter than one bar with an absurd row count: every snap collapses onto the
        // span edges, so the result must degrade to a single [start, end] row, never emit
        // duplicate or out-of-order boundaries.
        let grid = MeasureGrid(
            beatTimes: stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }, bpm: 120)
        let boundaries = ChordProDraftBuilder().barAlignedBoundaries(
            start: 2.1, end: 3.4, count: 8, grid: grid)
        XCTAssertEqual(boundaries, [2.1, 3.4])
    }

    func testSustainedChordIsRestatedAtSectionStartAfterInstrumental() {
        // 120 BPM → 1 bar = 2s. C changes during the 8-bar intro and SUSTAINS through the sung
        // lines (no further events). Without restatement the whole verse shows no chord at all;
        // the chart must restate [C] on the first sung line.
        let input = ChordProDraftInput(
            title: "Sustained",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 16, end: 18, text: "Warm sun kisses my nose"),
                TimedLyricSegment(start: 18, end: 20, text: "Cool sand under my toes"),
            ],
            chords: [EditableChordEvent(time: 2, chord: "C", confidence: 0.9)],
            beatTimes: stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(
            document.contains("[C]Warm sun"),
            "expected the sustained chord restated at the section start:\n\(document)")
        // But NOT restated on the following non-section line (change-only there).
        XCTAssertFalse(document.contains("[C]Cool sand"), document)
    }

    func testRestatementSkippedWhenLineAlreadyStartsWithChord() {
        let input = ChordProDraftInput(
            title: "Already Chorded",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 16, end: 18, text: "Warm sun kisses my nose")],
            chords: [
                EditableChordEvent(time: 2, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 16.1, chord: "G", confidence: 0.9),
            ],
            beatTimes: stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        )
        let document = ChordProDraftBuilder().build(input)
        // The line's own G within half a beat of the start suppresses a [C] restatement.
        XCTAssertFalse(document.contains("[C]Warm"), document)
    }

    func testShortIntervalChordFoldsIntoPreviousLineNotOwnLine() {
        // 120 BPM, 4/4 → 1 bar = 2s. The [2, 3] gap is 1s ≈ 0.5 bar — a brief musical breath
        // between sung lines, NOT an instrumental section. Its passing C#m must not become a
        // standalone chord-only line; it belongs to the tail of the previous sung line.
        let input = ChordProDraftInput(
            title: "Breath Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "Nothing else I'd rather do"),
                TimedLyricSegment(start: 3, end: 5, text: "Laughter rising in the air"),
            ],
            chords: [
                EditableChordEvent(time: 2.4, chord: "C#m", confidence: 0.9),
                EditableChordEvent(time: 3.2, chord: "A", confidence: 0.9),
            ],
            beatTimes: stride(from: 0.0, through: 6.0, by: 0.5).map { $0 }
        )
        let document = ChordProDraftBuilder().build(input)

        // No interlude marker for such a short gap.
        XCTAssertFalse(document.contains("{comment: Instrumental"), document)

        // No content line may consist only of chords (i.e. a standalone chord-only line):
        // stripping [..] tokens must leave real lyric text on every content line.
        let contentLines = document.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("{") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        for line in contentLines {
            let withoutChords = line.replacingOccurrences(
                of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            XCTAssertFalse(
                withoutChords.trimmingCharacters(in: .whitespaces).isEmpty,
                "Unexpected chord-only line: \(line)\n\(document)")
        }

        // The C#m is carried onto the previous sung line; the next line still gets its own A.
        let ratherLine = contentLines.first { $0.contains("rather") }
        XCTAssertTrue(ratherLine?.contains("[C#m]") ?? false, document)
        let laughterLine = contentLines.first { $0.contains("Laughter") }
        XCTAssertTrue(laughterLine?.contains("[A]") ?? false, document)
        XCTAssertFalse(laughterLine?.contains("[C#m]") ?? true, document)
    }

    func testLyricSectionDeriverMarksIntroInstrumentalAndOutro() {
        let beats = stride(from: 0.0, through: 80.0, by: 0.5).map { $0 }
        let lyrics = [
            TimedLyricSegment(start: 10, end: 12, text: "First line"),
            TimedLyricSegment(start: 24, end: 26, text: "Second line"),
            TimedLyricSegment(start: 50, end: 52, text: "Third line"),
        ]
        let sections = LyricSectionDeriver().sections(
            lyrics: lyrics,
            beatTimes: beats,
            tempo: 120,
            sourceDuration: 72)

        XCTAssertTrue(sections.contains { $0.kind == .intro && $0.label.hasPrefix("Intro") })
        XCTAssertTrue(sections.contains { $0.kind == .instrumental })
        XCTAssertTrue(sections.contains { $0.kind == .outro && $0.label == "Outro" })
    }

    func testLyricSectionDeriverKeepsKnownVocalGapOutOfInstrumentalSections() {
        let beats = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let lyrics = [
            TimedLyricSegment(start: 0, end: 2, text: "First line"),
            TimedLyricSegment(start: 12, end: 14, text: "Second line"),
        ]

        let sections = LyricSectionDeriver().sections(
            lyrics: lyrics,
            beatTimes: beats,
            tempo: 120,
            sourceDuration: 16,
            untranscribedVocalRegions: [3...11])

        XCTAssertTrue(sections.contains { $0.kind == .untranscribedVocal })
        XCTAssertFalse(sections.contains { $0.kind == .instrumental })
    }

    func testLyricSectionDeriverClosesShortMissedVocalRegionAtNextLine() {
        let lyrics = [
            TimedLyricSegment(start: 0, end: 2, text: "First line"),
            TimedLyricSegment(start: 4, end: 6, text: "Second line"),
        ]

        let sections = LyricSectionDeriver().sections(
            lyrics: lyrics,
            untranscribedVocalRegions: [2.5...3.5])

        XCTAssertEqual(sections.map(\.kind), [.untranscribedVocal, .vocal("Vocals")])
        XCTAssertEqual(sections.map(\.start), [2.5, 4])
    }

    func testLyricSectionDeriverOutroNotChorusAfterTailHallucination() {
        let beats = stride(from: 0.0, through: 240.0, by: 0.5).map { $0 }
        let lyrics = [
            TimedLyricSegment(start: 40, end: 44, text: "Sunset winks and starts to leave"),
            TimedLyricSegment(
                start: 104, end: 107.76, text: "And under the stars it feels so right"),
            TimedLyricSegment(start: 107.76, end: 109.36, text: "Sunset winks and starts to leave"),
        ]
        let sections = LyricSectionDeriver().sections(
            lyrics: lyrics,
            beatTimes: beats,
            tempo: 120,
            sourceDuration: 233)

        XCTAssertFalse(sections.contains { $0.label == "Chorus" && $0.start >= 107.76 })
        XCTAssertTrue(sections.contains { $0.kind == .outro && $0.start == 107.76 })
    }

    func testLyricSectionDeriverLabelsVersesAndChoruses() {
        let lyrics = [
            TimedLyricSegment(start: 0, end: 2, text: "Friday night is coming"),
            TimedLyricSegment(start: 2, end: 4, text: "With little jeans in my hand"),
            TimedLyricSegment(start: 4, end: 6, text: "It's a party going on"),
            TimedLyricSegment(start: 6, end: 8, text: "Shout it loud till the dawn"),
            TimedLyricSegment(start: 20, end: 22, text: "Drinks start a flowing now"),
            TimedLyricSegment(start: 22, end: 24, text: "Strangers turn into friends"),
            TimedLyricSegment(start: 24, end: 26, text: "It's a party going on"),
            TimedLyricSegment(start: 26, end: 28, text: "Shout it loud till the dawn"),
        ]
        let sections = LyricSectionDeriver().sections(lyrics: lyrics, beatTimes: [], tempo: 120)

        XCTAssertTrue(sections.contains { $0.label == "Verse 1" })
        XCTAssertTrue(sections.contains { $0.label == "Chorus" })
        XCTAssertTrue(sections.contains { $0.label == "Verse 2" })
    }

    func testIntroChordsBeforeFirstLyricAreRendered() {
        // Chords play during an 8s intro before the first vocal line; the chart
        // should start on the first chord rather than the first lyric's chord.
        let input = ChordProDraftInput(
            title: "Intro Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 8, end: 10, text: "First words")
            ],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 4, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 8, chord: "Am", confidence: 0.9),
            ]
        )
        let document = ChordProDraftBuilder().build(input)
        let body = document.split(separator: "\n")
        // First non-directive line should be an intro chord line, so the chart starts on the
        // first chord rather than the first lyric's chord. Intro rows now split to the typical
        // LYRIC line length (here ~2 bars), so the 4-bar intro renders as two bar-aligned rows
        // (B2: pipe-delimited bars on the song's MeasureGrid — 120 BPM, no detected beats, so a
        // uniform grid is synthesized from tempo; each row here is one 2-bar span. C holds through
        // both of its bars unchanged, so each bar shows the bare symbol with no continuation dot).
        let content = body.filter { !$0.hasPrefix("{") && !$0.isEmpty }.map(String.init)
        XCTAssertEqual(content.first, "| [C] | [C] |", document)
        XCTAssertEqual(content.dropFirst().first, "| [G] | [G] |", document)
    }

    func testInstrumentalChordOnlyLineUsesRhythmicSpacing() {
        let input = ChordProDraftInput(
            title: "Instrumental Break",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 2, text: "First line"),
                TimedLyricSegment(start: 10, end: 12, text: "Second line"),
            ],
            chords: [
                EditableChordEvent(time: 2, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 3, chord: "F", confidence: 0.9),
                EditableChordEvent(time: 6, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 9, chord: "C", confidence: 0.9),
            ]
        )

        let document = ChordProDraftBuilder().build(input)

        // The 4-bar break (120 BPM, 2s bars) splits into two lyric-line-length rows of 2 bars
        // each (B2: bar-aligned on the song's MeasureGrid, barPhase 0 from the chord onsets).
        // C@2 and F@3 land in the SAME bar (beats 4-7 of the grid, i.e. song time [2,4)): C on
        // the downbeat (beat 4), F two beats later (beat 6) — a change after the downbeat, so the
        // bar shows both symbols with "." filling the beats between/after them. The next bar
        // (beats 8-11, time [4,6)) has no change, so F just holds as a bare symbol. G@6 starts its
        // own bar cleanly (bare symbol, beat 12); C@9 changes mid-bar (beat 18 of a beat-16-19 bar)
        // so its bar shows the hold dots the same way as the first.
        XCTAssertTrue(document.contains("| [C] . [F] . | [F] |"), document)
        XCTAssertTrue(document.contains("| [G] | . . [C] . |"), document)
    }

    func testTrailingChordAfterLastWordIsTypesetPastTheText() {
        // A chord that sounds a beat AFTER the line's last word must land past the end of
        // the text, not stacked over the final word (in the audio it's to the RIGHT of it).
        let input = ChordProDraftInput(
            title: "Tail Chord",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(
                    start: 0, end: 2.0, text: "Sing along",
                    words: [
                        TimedLyricWord(text: "Sing", start: 0.0, end: 0.8, characterRange: 0..<4),
                        TimedLyricWord(text: "along", start: 1.0, end: 2.0, characterRange: 5..<10),
                    ]),
                TimedLyricSegment(
                    start: 4.0, end: 5.0, text: "Next line",
                    words: [
                        TimedLyricWord(text: "Next", start: 4.0, end: 4.4, characterRange: 0..<4),
                        TimedLyricWord(text: "line", start: 4.5, end: 5.0, characterRange: 5..<9),
                    ]),
            ],
            chords: [
                EditableChordEvent(time: 0.0, chord: "C", confidence: 0.9),
                // Sounds 0.5s after "along" ends — a trailing chord in the short gap.
                EditableChordEvent(time: 2.5, chord: "G", confidence: 0.9),
            ]
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(document.contains("Sing along[G]"), document)
        XCTAssertFalse(document.contains("[G]along"), document)
    }

    func testChordOnlyLineStacksChordsThatShareABeatSlot() {
        // Edge case (B2): chords that don't line up evenly with the beat grid — three chords
        // 0.1s apart (a fast passing run) all land within the SAME 0.5s beat slot at 120 BPM.
        // Rather than let the bar-aligned renderer silently keep only the last one (dropping
        // detected chords is worse than the old proportional layout ever was), every chord in a
        // shared slot renders together as adjacent bracket tokens, in chart order, with no
        // collision — bar-column layout has no character-width collision concern to begin with,
        // since chords never share literal text columns the way the old proportional spacing did.
        let input = ChordProDraftInput(
            title: "Sharp Intro",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 8, end: 10, text: "First words")
            ],
            chords: [
                EditableChordEvent(time: 0, chord: "C#", confidence: 0.9),
                EditableChordEvent(time: 0.1, chord: "A", confidence: 0.9),
                EditableChordEvent(time: 0.2, chord: "G#", confidence: 0.9),
            ]
        )
        let document = ChordProDraftBuilder().build(input)
        let chordLine =
            document
            .split(separator: "\n")
            .first { !$0.hasPrefix("{") && !$0.isEmpty }
            .map(String.init)
        // 120 BPM, no detected beats → a uniform grid is synthesized from tempo (B2). All three
        // chords round to beat index 0 (the bar's downbeat), so they stack in that one cell; the
        // chord holds unchanged into the next bar (no mid-bar change), so that bar is bare "[G#]".
        XCTAssertEqual(chordLine, "| [C#][A][G#] | [G#] |", document)
    }

    func testChordOnlyRowRendersOneChordPerBar() {
        // B2: the canonical case — a chord change on every bar's downbeat, nothing else. 120
        // BPM, explicit beats (0.5s apart, so 1 bar = 4 beats = 2s) with barPhase 0 (all four
        // onsets land on residue 0). A single long lyric line (8 bars) makes `typicalBars` clamp
        // to its 8-bar max, so the 3.75-bar outro renders as ONE row instead of splitting —
        // isolating exactly the bar-per-chord pattern with no row-splitting noise.
        let beats = stride(from: 0.0, through: 30.0, by: 0.5).map { $0 }
        let input = ChordProDraftInput(
            title: "One Chord Per Bar",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 16, text: "One long line across eight bars")],
            chords: [
                EditableChordEvent(time: 16, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 18, chord: "F", confidence: 0.9),
                EditableChordEvent(time: 20, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 22, chord: "C", confidence: 0.9),
            ],
            beatTimes: beats,
            sourceDuration: 24
        )
        let document = ChordProDraftBuilder().build(input)
        // Each chord sits alone on its own bar's downbeat with nothing else in the bar, so every
        // bar renders as a bare symbol — no continuation dots, matching `| C# | F# | Ab | C# |`.
        XCTAssertTrue(document.contains("| [C] | [F] | [G] | [C] |"), document)
    }

    func testChordOnlyRowUsesEstimatedBeatsPerBarFromLyricSpacing() {
        // Finding 3 regression: the live preview estimates beatsPerBar from lyric-line onset
        // spacing (3/4/5/6 via DownbeatEstimator), but the generated ChordPro used to
        // hard-code 4 regardless. Steady 120 BPM grid (0.5s/beat); five lyric-line onsets are
        // spaced 5 beats (2.5s) apart -- a clean non-4/4 phrase the estimator should detect
        // over its default. A 2-bar outro then holds one chord per 5-beat bar (2.5s each);
        // with the old hard-coded 4-beat (2.0s) bar, F's 2.5s offset from C is 1.25 bars --
        // not a bar boundary -- so it would NOT render as a clean one-chord-per-bar row.
        //
        // Each line carries 3 real `words` (>2 substantive tokens) so
        // `TrailingLyricTailPruner` doesn't mistake this short-line fixture for a degenerate
        // ASR tail hallucination and prune the last lines out of the outro boundary.
        func line(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TimedLyricSegment {
            TimedLyricSegment(
                start: start, end: end, text: text,
                words: [
                    TimedLyricWord(text: "a", start: start, end: start, characterRange: 0..<1),
                    TimedLyricWord(text: "b", start: start, end: start, characterRange: 1..<2),
                    TimedLyricWord(text: "c", start: start, end: start, characterRange: 2..<3),
                ])
        }
        let beats = stride(from: 0.0, through: 20.0, by: 0.5).map { $0 }
        let input = ChordProDraftInput(
            title: "Five Four Verse",
            tempo: 120,
            lyrics: [
                line(0.0, 0.5, "First line here"),
                line(2.5, 3.0, "Second line here"),
                line(5.0, 5.5, "Third line here"),
                line(7.5, 8.0, "Fourth line here"),
                line(10.0, 12.5, "Fifth line here"),
            ],
            chords: [
                EditableChordEvent(time: 12.5, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 15.0, chord: "F", confidence: 0.9),
            ],
            beatTimes: beats,
            sourceDuration: 17.5
        )
        let document = ChordProDraftBuilder().build(input)

        // Control: the SAME outro chords, but preceding lyric lines spaced 4 beats (2.0s)
        // apart instead of 5 -- consistent with the old hard-coded default, so the estimator
        // has no reason to deviate from it. Everything else (outro start/chords/duration,
        // per-line word count, beat grid) is identical, isolating the lyric-spacing signal as
        // the only difference between the two builds.
        let fourBeatInput = ChordProDraftInput(
            title: "Five Four Verse",
            tempo: 120,
            lyrics: [
                line(0.0, 0.5, "First line here"),
                line(2.0, 2.5, "Second line here"),
                line(4.0, 4.5, "Third line here"),
                line(6.0, 6.5, "Fourth line here"),
                line(8.0, 12.5, "Fifth line here"),
            ],
            chords: input.chords,
            beatTimes: beats,
            sourceDuration: 17.5
        )
        let controlDocument = ChordProDraftBuilder().build(fourBeatInput)
        let outro = { (doc: String) in doc.components(separatedBy: "{comment: Outro}").last ?? "" }
        XCTAssertNotEqual(
            outro(document), outro(controlDocument),
            "Changing only the lyric-line spacing (5 beats/line vs 4) should change the "
                + "estimated beatsPerBar and thus the rendered outro bar grid, proving the "
                + "builder wires lyric onsets into MeasureGrid instead of hard-coding 4.\n\n"
                + "5-beat lyrics:\n\(document)\n\n4-beat lyrics:\n\(controlDocument)")
    }

    func testChordOnlyRowMarksMidBarChordHoldWithContinuationDot() {
        // B2: a chord that changes AFTER a bar's downbeat (an off-beat-1 change) must show the
        // beats it then holds through as "." rather than a blank or a restated symbol — the
        // `F# .` half of `| C# | F# . | Ab | C# |`. 120 BPM, explicit beats (0.5s/beat, 2s/bar).
        let beats = stride(from: 0.0, through: 30.0, by: 0.5).map { $0 }
        let input = ChordProDraftInput(
            title: "Mid-Bar Hold",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 16, text: "One long line across eight bars")],
            chords: [
                // Bar at [16, 18): C states on the downbeat, nothing else — bare "[C]".
                EditableChordEvent(time: 16, chord: "C", confidence: 0.9),
                // Bar at [18, 20): F states on the downbeat (beat 0), then Ab changes at beat 2
                // (1s into the bar) and holds through beat 3 — "[F] . [Ab] .".
                EditableChordEvent(time: 18, chord: "F", confidence: 0.9),
                EditableChordEvent(time: 19, chord: "Ab", confidence: 0.9),
            ],
            beatTimes: beats,
            sourceDuration: 20
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(document.contains("| [C] | [F] . [Ab] . |"), document)
    }

    func testTrailingChordsAfterLastLyricRenderAsOutro() {
        // Chords detected after the final lyric line must not be dropped.
        let input = ChordProDraftInput(
            title: "Outro Song",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "Last line")],
            chords: [
                EditableChordEvent(time: 1, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 6, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 8, chord: "Am", confidence: 0.9),
            ]
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(document.contains("{comment: Outro}"), document)
        XCTAssertTrue(document.contains("[G]"), document)
        XCTAssertTrue(document.contains("[Am]"), document)
    }

    func testOutroLineSpansFullSourceDuration() {
        let input = ChordProDraftInput(
            title: "Long Outro",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "Last line")],
            chords: [
                EditableChordEvent(time: 6, chord: "G", confidence: 0.9),
                EditableChordEvent(time: 30, chord: "C", confidence: 0.9),
            ],
            sourceDuration: 120
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(document.contains("{comment: Outro}"), document)
        // A long outro is broken into multiple chord-only rows (so it wraps instead of running off
        // the right edge); both detected chords still appear, on their respective rows. B2: a
        // chord-only row is bar-aligned pipe text, so after stripping `[chord]` tokens only bar/beat
        // punctuation (`|`, `.`, spaces) remains — no lyric letters.
        let outro = document.components(separatedBy: "{comment: Outro}").last ?? document
        let chordOnlyRows = outro.split(separator: "\n").filter { row in
            let s = String(row)
            guard s.contains("["), !s.hasPrefix("{") else { return false }
            let stripped = s.replacingOccurrences(
                of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            let remainder = stripped.trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty || remainder.allSatisfy { "| .".contains($0) }
        }
        XCTAssertGreaterThan(chordOnlyRows.count, 1, document)
        XCTAssertTrue(outro.contains("[G]"), document)
        XCTAssertTrue(outro.contains("[C]"), document)
    }

    func testBuildAlignsIncludedChordChangesToLyrics() {
        let input = ChordProDraftInput(
            title: "Test Song",
            tempo: 120,
            lyrics: [
                TimedLyricSegment(start: 0, end: 4, text: "Hello wide world")
            ],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.95),
                EditableChordEvent(time: 2, chord: "G", confidence: 0.60),
            ]
        )

        let document = ChordProDraftBuilder().build(input)

        XCTAssertEqual(
            document,
            """
            {title: Test Song}
            {tempo: 120}
            {time: 4/4}
            {comment: Generated analysis draft - review required}

            {x_chord_times: 0.000:C;2.000:G}
            [C]Hello [G]wide world
            """ + "\n"
        )
    }

    func testBuildProducesChordGridWhenLyricsAreUnavailable() {
        let input = ChordProDraftInput(
            title: "Instrumental",
            tempo: nil,
            lyrics: [],
            chords: [
                EditableChordEvent(time: 0, chord: "Dm", confidence: 0.9),
                EditableChordEvent(time: 4, chord: "Bb", confidence: 0.8),
            ]
        )

        XCTAssertEqual(
            ChordProDraftBuilder().build(input),
            """
            {title: Instrumental}
            {comment: Generated analysis draft - review required}

            {start_of_grid}
            {x_chord_times: 0.000:Dm;4.000:Bb}
            | Dm | Bb |
            {end_of_grid}
            """ + "\n"
        )
    }

    func testBuildExcludesDetectedChordsBelowThresholdButKeepsManualChords() {
        let input = ChordProDraftInput(
            title: "Threshold",
            tempo: nil,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "One two three")],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.79),
                EditableChordEvent(time: 1, chord: "G", confidence: 0.80),
                EditableChordEvent(time: 2, chord: "Am", confidence: nil),
            ],
            confidenceThreshold: 0.80
        )

        let document = ChordProDraftBuilder().build(input)

        XCTAssertFalse(document.contains("[C]"))
        XCTAssertTrue(document.contains("[G]"))
        XCTAssertTrue(document.contains("[Am]"))
        XCTAssertFalse(document.contains("low-confidence"))
    }

    func testBuildIsStableAcrossDifferentPersistenceIdentifiers() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = ChordProDraftInput(
            title: "Stable",
            tempo: 90,
            lyrics: [TimedLyricSegment(id: firstID, start: 0, end: 4, text: "Same words")],
            chords: [
                EditableChordEvent(id: firstID, time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(id: secondID, time: 0, chord: "G", confidence: 0.8),
            ]
        )
        let second = ChordProDraftInput(
            title: "Stable",
            tempo: 90,
            lyrics: [TimedLyricSegment(id: secondID, start: 0, end: 4, text: "Same words")],
            chords: [
                EditableChordEvent(id: secondID, time: 0, chord: "C", confidence: 0.9),
                EditableChordEvent(id: firstID, time: 0, chord: "G", confidence: 0.8),
            ]
        )

        XCTAssertEqual(ChordProDraftBuilder().build(first), ChordProDraftBuilder().build(second))
    }

    func testBassNoteBuildPrefersSlashBassThenChordRoot() {
        let input = ChordProDraftInput(
            title: "Bass Song",
            tempo: 96,
            lyrics: [TimedLyricSegment(start: 0, end: 6, text: "Walk the low line")],
            chords: [
                EditableChordEvent(time: 0, chord: "Cmaj7", confidence: 0.9),
                EditableChordEvent(time: 2, chord: "G/B", confidence: 0.9),
                EditableChordEvent(time: 4, chord: "F#m/A", confidence: 0.9),
            ]
        )

        let document = ChordProDraftBuilder().build(
            input,
            comment: ChordProDraftBuilder.bassNoteDraftComment,
            chordLabel: { BassNote(chordSymbol: $0.chord)?.label }
        )

        XCTAssertEqual(
            document,
            """
            {title: Bass Song}
            {tempo: 96}
            {time: 4/4}
            {comment: Generated bass-note analysis draft - review required}

            {x_chord_times: 0.000:C;2.000:B;4.000:A}
            [C]Walk [B]the [A]low line
            """ + "\n"
        )
    }

    func testBassNoteBuildHonorsConfidenceThresholdAndOmitsInvalidChordNames() {
        let input = ChordProDraftInput(
            title: "Bass Grid",
            tempo: nil,
            lyrics: [],
            chords: [
                EditableChordEvent(time: 0, chord: "C/E", confidence: 0.79),
                EditableChordEvent(time: 1, chord: "Bbmaj7/D", confidence: 0.8),
                EditableChordEvent(time: 2, chord: "N.C.", confidence: 0.95),
                EditableChordEvent(time: 3, chord: "F#", confidence: nil),
            ],
            confidenceThreshold: 0.8
        )

        let document = ChordProDraftBuilder().build(
            input,
            comment: ChordProDraftBuilder.bassNoteDraftComment,
            chordLabel: { BassNote(chordSymbol: $0.chord)?.label }
        )

        XCTAssertEqual(
            document,
            """
            {title: Bass Grid}
            {comment: Generated bass-note analysis draft - review required}

            {start_of_grid}
            {x_chord_times: 1.000:D;3.000:F#}
            | D | F# |
            {end_of_grid}
            """ + "\n"
        )
    }

    // MARK: - B5: x_chord_times round-trip carrier

    func testChordTimeDirectiveCarriesExactTimestampsForInlineLyricChords() {
        let input = ChordProDraftInput(
            title: "Round Trip",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "Hello wide world")],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.95),
                EditableChordEvent(time: 2, chord: "G", confidence: 0.60),
            ]
        )
        let document = ChordProDraftBuilder().build(input)
        let recovered = ChordProChordTimeCarrier.parse(document)
        XCTAssertEqual(
            recovered,
            [
                ChordProChordTimeCarrier.Entry(time: 0, label: "C"),
                ChordProChordTimeCarrier.Entry(time: 2, label: "G"),
            ], document)
    }

    func testChordTimeDirectiveCarriesExactTimestampsAcrossInstrumentalAndOutroRows() {
        // One chord-only intro row (4-bar gap before the first line, single row since
        // typicalBars clamps to the lyric line's own length), one inline lyric chord, and an
        // outro chord after the last line — exercises all three emission sites in one pass.
        let input = ChordProDraftInput(
            title: "Round Trip Full",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 8, end: 16, text: "One long line across bars")],
            chords: [
                EditableChordEvent(time: 0, chord: "Dm", confidence: 0.9),
                EditableChordEvent(time: 8, chord: "C", confidence: 0.9),
                EditableChordEvent(time: 20, chord: "G", confidence: 0.9),
            ],
            sourceDuration: 24
        )
        let document = ChordProDraftBuilder().build(input)
        let recovered = ChordProChordTimeCarrier.parse(document)
        // Every genuinely detected chord event must round-trip losslessly, in chronological
        // order; the carrier may ALSO include synthetic restatement entries the builder adds
        // for chart readability (e.g. restating a sustained chord at a section start), so this
        // asserts the original events are a subsequence, not that the two lists are identical.
        let expected = [
            ChordProChordTimeCarrier.Entry(time: 0, label: "Dm"),
            ChordProChordTimeCarrier.Entry(time: 8, label: "C"),
            ChordProChordTimeCarrier.Entry(time: 20, label: "G"),
        ]
        var remaining = recovered[...]
        for entry in expected {
            guard let index = remaining.firstIndex(of: entry) else {
                return XCTFail("missing \(entry) in recovered \(recovered):\n\(document)")
            }
            remaining = remaining[remaining.index(after: index)...]
        }
    }

    func testChordTimeDirectiveOmittedWhenNoChordsPresent() {
        let input = ChordProDraftInput(
            title: "No Chords",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "Just words, no chords here")],
            chords: []
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertFalse(document.contains("x_chord_times"), document)
        XCTAssertTrue(ChordProChordTimeCarrier.parse(document).isEmpty, document)
    }

    /// Regression (Key West Bar field case): a short (<=4-word) call-and-response tag line —
    /// "in a Key West bar" — that completes a chorus phrase after a real but short (~3s, well
    /// under the analyzer's 4s `sectionGap`) instrumental/breath pause must stay part of the SAME
    /// section as the line it completes, not be misread as a new verse. On its own the short tag
    /// shares few/no words with the fuller chorus line elsewhere in the song, so its standalone
    /// Jaccard similarity comes out low — without the short-trailing-line exemption, that
    /// classification mismatch (verse vs. chorus) would incorrectly split the section even though
    /// the gap itself is nowhere near the 4s threshold.
    func testShortTagLineAfterShortGapStaysInSameSectionAsCompletedChorusLine() {
        func line(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TimedLyricSegment {
            let words = text.split(separator: " ")
            var characterOffset = 0
            var timedWords: [TimedLyricWord] = []
            let span = (end - start) / Double(max(words.count, 1))
            for (index, word) in words.enumerated() {
                let wordStart = start + Double(index) * span
                let wordEnd = wordStart + span
                let range = characterOffset..<(characterOffset + word.count)
                timedWords.append(
                    TimedLyricWord(
                        text: String(word), start: wordStart, end: wordEnd, characterRange: range))
                characterOffset += word.count + 1
            }
            return TimedLyricSegment(start: start, end: end, text: text, words: timedWords)
        }
        let lyrics = [
            // Earlier, unsplit occurrence of the full phrase — the reference the split
            // occurrence's COMBINED (lead-in + tag) text will match.
            line(0, 2, "Yeah I need a break in a Key West bar"),
            // An independent EARLIER occurrence of just the lead-in half, so "Yeah I need a
            // break" reliably Jaccard-matches (1.0) and classifies as chorus on its own, entirely
            // independent of whatever tag follows it later.
            line(10, 11.7, "Yeah I need a break"),
            line(20, 22, "Some totally unrelated verse content here"),
            line(24, 26, "More unrelated verse content follows along"),
            // Split occurrence: a real ~3s pause breaks the SAME phrase into a lead-in line and a
            // short trailing tag — mirrors the field case exactly (segments 13 → 14). "in a Key
            // West bar" shares NO words with anything else in this fixture on ITS OWN (standalone
            // Jaccard ~0 against every other line), but COMBINED with the immediately preceding
            // "Yeah I need a break" it reconstructs the first occurrence's full text exactly
            // (Jaccard 1.0) — the signal that correctly identifies it as a continuation/tag
            // rather than a genuinely new, self-sufficient line.
            line(50, 51.7, "Yeah I need a break"),
            line(54.76, 56, "in a Key West bar"),
        ]
        let sections = SongStructureAnalyzer().vocalSections(for: lyrics)
        // The short tag line at 54.76 must NOT start its own new section: it should fall inside
        // whichever section starts at 50 (the "Yeah I need a break" lead-in), not create a new
        // section boundary at 54.76.
        XCTAssertFalse(
            sections.contains { $0.start == 54.76 },
            "short trailing tag line incorrectly started its own section: \(sections)")
        // The lead-in ("Yeah I need a break" @50) and its trailing tag must land in the SAME,
        // LAST section (nothing else starts after 50), and that section must be classified as a
        // chorus — inherited correctly from the lead-in's own reliable classification.
        XCTAssertEqual(sections.map(\.start).max(), 50, "\(sections)")
        XCTAssertEqual(sections.last?.kind, .chorus, "\(sections)")
    }

    /// Regression (Settle Down field case, 2026-07-07): a Bridge whose mid-phrase breath happens
    /// to land a HAIR over `sectionGap` (4s) must stay ONE section, not fragment into two short
    /// "Verse N" blocks. Every real verse here runs 6 lines; the bridge's two halves run 1 line
    /// each — before the fix, the bare `gap >= sectionGap` split (4.1s, no classification
    /// mismatch: both halves default to `.verse`, same as the real verse) produced
    /// ["Verse 1", "Chorus", "Verse 2", "Verse 3", "Chorus"]; after the fix the two anomalously
    /// short same-kind fragments merge into one "Verse 2", giving
    /// `SongStructureOverviewBuilder.reclassifyBridgeAndSolo` (a later stage, not under test
    /// here) an actual chance to relabel it as a Bridge by chord-pattern mismatch — impossible
    /// while it was still two 1-line fragments too sparse to compare meaningfully.
    func testGapFragmentedShortVerseBlocksMergeIntoOneSection() {
        func line(_ start: TimeInterval, _ text: String, duration: TimeInterval = 2)
            -> TimedLyricSegment
        {
            TimedLyricSegment(start: start, end: start + duration, text: text)
        }
        // Six lines with genuinely distinct wording (not a shared template with one word
        // swapped) so they never accidentally Jaccard-match EACH OTHER at >= chorusSimilarity
        // and get misread as a repeated chorus themselves.
        let verse1Text = [
            "Morning light breaks through the trees",
            "Coffee steam rises past my face",
            "Dog runs circles round the yard",
            "Neighbors wave from cars going by",
            "Radio plays a song I love",
            "Time moves slow on days like these",
        ]
        var verse1: [TimedLyricSegment] = []
        var t: TimeInterval = 0
        for text in verse1Text {
            verse1.append(line(t, text))
            t += 2.3  // 0.3s inter-line gap, well under sectionGap
        }
        let chorusText = ["sing the chorus now", "everybody sing along"]
        t += 1
        var chorusA: [TimedLyricSegment] = []
        for text in chorusText {
            chorusA.append(line(t, text))
            t += 2.3
        }
        t += 1
        let fragmentA = line(t, "thought I would slow down today", duration: 1.5)
        t = fragmentA.end + 4.1  // just OVER sectionGap (4.0) -- the exact field case
        let fragmentB = line(t, "but then I saw her smile", duration: 1.5)
        t = fragmentB.end + 1
        var chorusB: [TimedLyricSegment] = []
        for text in chorusText {
            chorusB.append(line(t, text))
            t += 2.3
        }

        let lyrics = verse1 + chorusA + [fragmentA, fragmentB] + chorusB
        let sections = SongStructureAnalyzer().vocalSections(for: lyrics)

        XCTAssertEqual(
            sections.map(\.label), ["Verse 1", "Chorus", "Verse 2", "Chorus"], "\(sections)")
        XCTAssertEqual(sections.map(\.kind), [.verse, .chorus, .verse, .chorus], "\(sections)")
        // The merged "Verse 2" must start at the FIRST fragment, not the second -- confirming the
        // two fragments actually merged into one section rather than the second simply vanishing.
        XCTAssertEqual(sections[2].start, fragmentA.start, "\(sections)")
    }

    /// Guard-rail: two ORDINARY, full-length verses (no chorus between them, a strophic song)
    /// separated only by a `sectionGap`-or-longer pause must stay split — the merge above only
    /// fires when at least one side is anomalously SHORT relative to the song's other verse-kind
    /// blocks, so two same-length verses are never accidentally collapsed into one.
    func testTwoOrdinaryEqualLengthVersesSeparatedByAGapStaySplit() {
        func line(_ start: TimeInterval, _ text: String) -> TimedLyricSegment {
            TimedLyricSegment(start: start, end: start + 2, text: text)
        }
        let verse1Text = [
            "Morning light breaks through the trees",
            "Coffee steam rises past my face",
            "Dog runs circles round the yard",
            "Neighbors wave from cars going by",
        ]
        let verse2Text = [
            "Evening falls across the field",
            "Crickets start their nightly song",
            "Porch light flickers on next door",
            "Stars come out one by one",
        ]
        var verse1: [TimedLyricSegment] = []
        var t: TimeInterval = 0
        for text in verse1Text {
            verse1.append(line(t, text))
            t += 2.3
        }
        t = verse1.last!.end + 4.1  // just over sectionGap, same magnitude as the fragment case
        var verse2: [TimedLyricSegment] = []
        for text in verse2Text {
            verse2.append(line(t, text))
            t += 2.3
        }
        let sections = SongStructureAnalyzer().vocalSections(for: verse1 + verse2)
        XCTAssertEqual(sections.map(\.label), ["Verse 1", "Verse 2"], "\(sections)")
        XCTAssertEqual(sections.map(\.start), [verse1[0].start, verse2[0].start], "\(sections)")
    }

    func testChordTimeDirectiveIsPreservedByTheChordProParserAsAnOpaqueDirective() throws {
        // x_ is the ChordPro convention for app-specific extensions: a spec-compliant parser
        // must not choke on it, and this app's own parser must round-trip it verbatim through a
        // parse/export pass (proving the carrier survives beyond just string search).
        let input = ChordProDraftInput(
            title: "Parser Safety",
            tempo: 120,
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "Hello wide world")],
            chords: [EditableChordEvent(time: 0, chord: "C", confidence: 0.9)]
        )
        let document = ChordProDraftBuilder().build(input)
        XCTAssertTrue(document.contains("{x_chord_times: 0.000:C}"), document)
        let parsed = try ChordProDocument(parsing: document)
        XCTAssertEqual(parsed.export(), document)
    }
}
