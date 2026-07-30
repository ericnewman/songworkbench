import XCTest

@testable import SongWorkbench

final class ChordProReadOnlyLineRendererTests: XCTestCase {
    func testChordOnlyBarGridRowsAreExpandedWithAlignedChords() throws {
        let source = "| [C] | . [G] . |"
        let line = try onlyLine(from: source)

        let rows = ChordProReadOnlyLineRenderer.rows(for: line)

        XCTAssertFalse(line.hasSungText)
        XCTAssertGreaterThan(rows.lyricRow.count, line.lyric.count)
        XCTAssertEqual(rows.chordRow?.firstIndexDistance(of: "C"), line.chords[0].column * 2)
        XCTAssertEqual(rows.chordRow?.firstIndexDistance(of: "G"), line.chords[1].column * 2)
    }

    func testSungLyricRowsKeepExactChordProColumns() throws {
        let line = try onlyLine(from: "[C]Hello [G]world")

        let rows = ChordProReadOnlyLineRenderer.rows(for: line)

        XCTAssertTrue(line.hasSungText)
        XCTAssertEqual(rows.lyricRow, "Hello world")
        XCTAssertEqual(rows.chordRow, ChordRowStringBuilder.build(chords: line.chords))
    }

    private func onlyLine(from source: String) throws -> ChordProPreviewLine {
        let document = try ChordProPreviewDocument(parsing: source)
        guard case .lyric(let line) = document.blocks.first else {
            throw XCTestError(.failureWhileWaiting)
        }
        return line
    }
}

extension String {
    fileprivate func firstIndexDistance(of character: Character) -> Int? {
        guard let index = firstIndex(of: character) else { return nil }
        return distance(from: startIndex, to: index)
    }
}
