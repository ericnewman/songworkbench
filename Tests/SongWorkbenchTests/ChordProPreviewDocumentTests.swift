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
}
