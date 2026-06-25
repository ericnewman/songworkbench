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
        // First non-directive line should be the intro chord line with timing preserved.
        let firstContent = body.first { !$0.hasPrefix("{") && !$0.isEmpty }
        XCTAssertEqual(firstContent.map(String.init), "[C]    [G]", document)
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

        XCTAssertTrue(document.contains("[C]  [F]   [G]   [C]"), document)
        XCTAssertFalse(document.contains("[C] [F] [G] [C]"), document)
    }

    func testChordOnlyLineReservesMultiCharLabelWidth() {
        // Adjacent multi-character chords (C#, D#, G#) must not collide: the gap
        // between two chords has to clear the previous label plus a blank column,
        // otherwise the preview renders them as "C#A".
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
        // "C#" (2 chars) + 1 min gap = 3 spaces before "A"; "A" (1 char) + 1 = 2 before "G#".
        XCTAssertEqual(chordLine, "[C#]   [A]  [G#]", document)
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
