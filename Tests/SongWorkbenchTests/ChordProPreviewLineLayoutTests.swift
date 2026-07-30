import XCTest

@testable import SongWorkbench

final class ChordProPreviewLineLayoutTests: XCTestCase {
    func testRhythmicInstrumentalWidthUsesReadableTimeScale() {
        let width = ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: true,
            lineDuration: 8,
            chordColumnExtent: 12,
            characterWidth: 10,
            pixelsPerSecond: 100
        )

        XCTAssertEqual(width, 1080, accuracy: 0.001)
    }

    func testRhythmicInstrumentalWidthPreservesWiderChordExtent() {
        let width = ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: true,
            lineDuration: 2,
            chordColumnExtent: 40,
            characterWidth: 10,
            pixelsPerSecond: 100
        )

        XCTAssertEqual(width, 400, accuracy: 0.001)
    }

    func testInstrumentalWidthFallsBackToChordExtentWithoutRhythmicTiming() {
        let nonRhythmicWidth = ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: false,
            lineDuration: 8,
            chordColumnExtent: 12,
            characterWidth: 10,
            pixelsPerSecond: 100
        )
        let unknownDurationWidth = ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: true,
            lineDuration: 0,
            chordColumnExtent: 12,
            characterWidth: 10,
            pixelsPerSecond: 100
        )

        XCTAssertEqual(nonRhythmicWidth, 120, accuracy: 0.001)
        XCTAssertEqual(unknownDurationWidth, 120, accuracy: 0.001)
    }

    func testOutroChordOnlyWindowUsesChordOnsetsWhenNoAudioOrBeatBoundsExist() throws {
        let document = try ChordProPreviewDocument(
            parsing: """
                [C]Last sung line
                {x_chord_times: 22.000:F 26.000:G}
                | [F] | [G] |
                """)
        let items = ChordProPreviewIndexing.indexedBlocks(for: document)
        let outroIndex = try XCTUnwrap(
            items.indices.first {
                ChordProPreviewIndexing.isChordOnlyRow(items, $0)
            })

        let window = try XCTUnwrap(
            ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
                items: items,
                index: outroIndex,
                lyricLineWindows: [10...20],
                songDuration: 0,
                envelopeDurations: [],
                beatTimes: [],
                beatLengthSeconds: 0.5,
                chordOnsetTimes: [22, 26]
            ))

        XCTAssertEqual(window.start, 20, accuracy: 0.001)
        XCTAssertEqual(window.end, 28, accuracy: 0.001)
    }

    func testOutroChordOnlyWindowUsesTimelineDurationBeforeChordTailFallback() throws {
        let document = try ChordProPreviewDocument(
            parsing: """
                [C]Last sung line
                {x_chord_times: 22.000:F}
                | [F] |
                """)
        let items = ChordProPreviewIndexing.indexedBlocks(for: document)
        let outroIndex = try XCTUnwrap(
            items.indices.first {
                ChordProPreviewIndexing.isChordOnlyRow(items, $0)
            })

        let window = try XCTUnwrap(
            ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
                items: items,
                index: outroIndex,
                lyricLineWindows: [10...20],
                songDuration: 36,
                envelopeDurations: [],
                beatTimes: [],
                beatLengthSeconds: 0.5,
                chordOnsetTimes: [22]
            ))

        XCTAssertEqual(window.start, 20, accuracy: 0.001)
        XCTAssertEqual(window.end, 36, accuracy: 0.001)
    }
}
