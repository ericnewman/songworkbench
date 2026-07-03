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
        XCTAssertTrue(doc.contains("{comment: Verse 1}"), doc)
        XCTAssertTrue(doc.contains("{comment: Chorus}"), doc)
        XCTAssertTrue(doc.contains("{comment: Verse 2}"), doc)
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
            | D | F# |
            {end_of_grid}
            """ + "\n"
        )
    }
}
