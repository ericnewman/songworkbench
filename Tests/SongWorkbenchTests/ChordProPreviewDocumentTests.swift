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

    // MARK: - chordOnlyRunPosition (multi-row intro/instrumental/outro window slicing)

    func testChordOnlyRunPositionCountsConsecutiveRowsAcrossInterleavedDirectives() throws {
        // Mirrors ChordProDraftBuilder's real output: EVERY chord-only bar row is immediately
        // preceded by its own `{x_chord_times: ...}` round-trip directive (B5), so a 3-row
        // intro looks like directive/row/directive/row/directive/row in `document.blocks`, not
        // 3 adjacent `.lyric` blocks. Regression for "Intro and outro bars are now twice as
        // wide as they should be": a naive adjacent-index scan sees a `.directive` immediately
        // next to each row and stops, collapsing every row's run to length 1 (rowCount == 1,
        // so each row claimed the ENTIRE gap instead of its 1/3 slice).
        let source = """
            {comment: Intro}
            {x_chord_times: 0.000:C}
            | [C] | [C] |
            {x_chord_times: 2.000:F}
            | [F] | [F] |
            {x_chord_times: 4.000:G}
            | [G] | [G] |
            [C]Real lyric line here
            """
        let document = try ChordProPreviewDocument(parsing: source)
        let items = ChordProPreviewIndexing.indexedBlocks(for: document)
        let rowIndices = items.indices.filter { ChordProPreviewIndexing.isChordOnlyRow(items, $0) }

        XCTAssertEqual(rowIndices.count, 3, "sanity check: 3 chord-only rows in the fixture")

        let positions = rowIndices.map {
            ChordProPreviewIndexing.chordOnlyRunPosition(in: items, at: $0)
        }
        XCTAssertEqual(
            positions.map(\.rowCount), [3, 3, 3],
            "every row in the run must see the TRUE row count, not 1")
        XCTAssertEqual(
            positions.map(\.position), [0, 1, 2],
            "each row's position within the run must advance, not reset to 0")
    }

    func testChordOnlyRunPositionTreatsARealLyricLineAsARunBoundary() throws {
        // Two separate 1-row instrumental breaks either side of a sung line must NOT be fused
        // into a single false "run" of 2 — the sung line genuinely ends the first run.
        let source = """
            {x_chord_times: 0.000:C}
            | [C] | [C] |
            [G]A real sung line
            {x_chord_times: 4.000:F}
            | [F] | [F] |
            """
        let document = try ChordProPreviewDocument(parsing: source)
        let items = ChordProPreviewIndexing.indexedBlocks(for: document)
        let rowIndices = items.indices.filter { ChordProPreviewIndexing.isChordOnlyRow(items, $0) }

        XCTAssertEqual(rowIndices.count, 2)
        for index in rowIndices {
            let result = ChordProPreviewIndexing.chordOnlyRunPosition(in: items, at: index)
            XCTAssertEqual(result.rowCount, 1)
            XCTAssertEqual(result.position, 0)
        }
    }
}
