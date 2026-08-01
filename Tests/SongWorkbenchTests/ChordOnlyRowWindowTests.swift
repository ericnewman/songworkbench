import XCTest

@testable import SongWorkbench

/// Each row of a multi-row instrumental run must claim its OWN time, not an equal slice.
final class ChordOnlyRowWindowTests: XCTestCase {
    private func document(_ source: String) -> ChordProPreviewDocument {
        ChordProPreviewDocument(document: try! ChordProDocument(parsing: source))
    }

    /// Field shape from "Key West Bar": a 4-row intro whose real chord windows are
    /// 5.12 / 5.25 / 5.05 / 4.04 s. Equal slicing rendered all four as 4.90 s.
    func testRunRowsTakeTheirRealChordWindows() {
        let source = """
            {title: T}
            | [Eb] . [Cm] . | [Ab] . [F] . [Bb] |
            | [Eb] . [Bb] . |
            | [Cm] . [Bb] . | [Ab] . [Bb] . |
            | [Cm] . [Ab] . |
            [F]Monday's been [Eb]hanging around like a [Cm]thousand pound stone
            """
        let preview = document(source)
        let items = ChordProPreviewIndexing.indexedBlocks(for: preview)
        let chordRows = items.indices.filter { ChordProPreviewIndexing.isChordOnlyRow(items, $0) }
        XCTAssertEqual(chordRows.count, 4)

        let onsets: [TimeInterval] = [
            0.14, 1.52, 2.80, 4.09, 4.73,
            5.26, 8.53,
            10.51, 12.43, 13.10, 14.27,
            15.56, 16.97,
        ]
        var widths: [TimeInterval] = []
        for row in chordRows {
            let window = ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
                items: items, index: row, lyricLineWindows: [19.60...23.79],
                explicitStart: 0, explicitEnd: 19.60,
                songDuration: 231, envelopeDurations: [231], beatTimes: [],
                beatLengthSeconds: 0.5, chordOnsetTimes: onsets)
            widths.append((window?.end ?? 0) - (window?.start ?? 0))
        }
        XCTAssertEqual(widths[0], 5.26, accuracy: 0.01)
        XCTAssertEqual(widths[1], 5.25, accuracy: 0.01)
        XCTAssertEqual(widths[2], 5.05, accuracy: 0.01)
        XCTAssertEqual(widths[3], 4.04, accuracy: 0.01)
        // The bug: every row the same width regardless of the time it covers.
        XCTAssertNotEqual(widths[0], widths[3], accuracy: 0.001)
    }

    /// Without usable onsets the equal slice must still be produced — no invented boundaries.
    func testFallsBackToEqualSlicesWithoutOnsets() {
        let source = """
            {title: T}
            | [Eb] . [Cm] . |
            | [Ab] . [Bb] . |
            [F]a word here
            """
        let preview = document(source)
        let items = ChordProPreviewIndexing.indexedBlocks(for: preview)
        let chordRows = items.indices.filter { ChordProPreviewIndexing.isChordOnlyRow(items, $0) }
        var widths: [TimeInterval] = []
        for row in chordRows {
            let window = ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
                items: items, index: row, lyricLineWindows: [10.0...12.0],
                explicitStart: 0, explicitEnd: 10.0,
                songDuration: 60, envelopeDurations: [60], beatTimes: [],
                beatLengthSeconds: 0.5, chordOnsetTimes: [])
            widths.append((window?.end ?? 0) - (window?.start ?? 0))
        }
        XCTAssertEqual(widths, [5.0, 5.0])
    }
}
