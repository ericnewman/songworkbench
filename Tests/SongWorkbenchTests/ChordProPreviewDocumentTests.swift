import XCTest

@testable import SongWorkbench

final class ChordProPreviewDocumentTests: XCTestCase {
    func testPlacesChordsAtTheirLyricCharacterColumns() throws {
        let preview = try ChordProPreviewDocument(parsing: "[C]Hello [G7/B]world")

        XCTAssertEqual(
            preview.blocks,
            [
                .lyric(
                    ChordProPreviewLine(
                        lyric: "Hello world",
                        chords: [
                            ChordProPreviewChord(name: "C", column: 0),
                            ChordProPreviewChord(name: "G7/B", column: 6),
                        ]
                    ))
            ]
        )
    }

    func testConvertsCommonDirectivesAndPreservesBlankLines() throws {
        let source = """
            {title: Test Song}
            {artist: Example Artist}
            {key: Bb}
            {start_of_chorus: Chorus 1}
            [Bb]Sing

            {end_of_chorus}
            """

        let preview = try ChordProPreviewDocument(parsing: source)

        XCTAssertEqual(
            preview.blocks,
            [
                .title("Test Song"),
                .metadata(label: "Artist", value: "Example Artist"),
                .metadata(label: "Key", value: "Bb"),
                .section("Chorus 1"),
                .lyric(
                    ChordProPreviewLine(
                        lyric: "Sing",
                        chords: [ChordProPreviewChord(name: "Bb", column: 0)]
                    )),
                .lyric(ChordProPreviewLine(lyric: "", chords: [])),
            ]
        )
    }

    func testRemovesChordProEscapesFromDisplayedLyrics() throws {
        let preview = try ChordProPreviewDocument(parsing: #"A \[literal\] [D]line"#)

        XCTAssertEqual(
            preview.blocks,
            [
                .lyric(
                    ChordProPreviewLine(
                        lyric: "A [literal] line",
                        chords: [ChordProPreviewChord(name: "D", column: 12)]
                    ))
            ]
        )
    }

    // MARK: - hasSungText (instrumental/chord-only row detection)

    func testHasSungTextIsTrueForARealLyricLine() {
        let line = ChordProPreviewLine(
            lyric: "Monday's been hanging around",
            chords: [ChordProPreviewChord(name: "C", column: 0)]
        )
        XCTAssertTrue(line.hasSungText)
    }

    func testHasSungTextIsFalseForABlankLine() {
        let line = ChordProPreviewLine(lyric: "", chords: [])
        XCTAssertFalse(line.hasSungText)

        let whitespaceOnly = ChordProPreviewLine(lyric: "   ", chords: [])
        XCTAssertFalse(whitespaceOnly.hasSungText)
    }

    func testHasSungTextIsFalseForBarAlignedChordOnlyRows() throws {
        // What's left of ChordProDraftBuilder.chordOnlyLine's rendered bar row
        // ("| . | [C#] . [Ab] . |") once the bracketed chords are parsed out as separate
        // .chord elements - regression check for the missing purple-waveform bug: this text
        // is NOT whitespace-only (it has "|" and "."), so a plain blank check misses it.
        let preview = try ChordProPreviewDocument(
            parsing: "| . | [C#] . [Ab] . | [C#] . [Bbm] [F#] |")
        guard case .lyric(let line) = preview.blocks.first else {
            return XCTFail("expected a single lyric block")
        }
        XCTAssertFalse(line.lyric.isEmpty, "sanity check: the bar text itself isn't blank")
        XCTAssertFalse(line.hasSungText)
    }

    func testHasSungTextIsTrueForARealLineContainingPeriodsOrPipes() {
        // A genuine sung line that happens to contain "." or "|"-like punctuation must still
        // count as real - hasSungText only excludes a line that is PURELY those characters.
        let line = ChordProPreviewLine(lyric: "Wait a minute...", chords: [])
        XCTAssertTrue(line.hasSungText)
    }
}
