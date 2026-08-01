import XCTest

@testable import SongWorkbench

final class ChordProPreviewLineLayoutTests: XCTestCase {
    func testRhythmicInstrumentalWidthMatchesLyricRowTimeScale() {
        // 8 s at 100 px/s = 800 px — the SAME pixels-per-second a lyric row uses, so a gap of a
        // given duration is the same width whether the row has words or only chords. (This was
        // 1080 while chord-only rows carried a 1.35x readability scale, which meant one chart
        // had two horizontal scales.) The 12-column chord extent is 120 px, below the time
        // width, so it does not raise the floor here.
        let width = ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: true,
            lineDuration: 8,
            chordColumnExtent: 12,
            characterWidth: 10,
            pixelsPerSecond: 100
        )

        XCTAssertEqual(width, 800, accuracy: 0.001)
    }

    /// SUPERSEDES `testRhythmicInstrumentalWidthPreservesWiderChordExtent`, which asserted the
    /// opposite: that a wide chord extent (40 columns x 10pt = 400) beat the row's real 2s x 100
    /// = 200. That rule is what let TEXT stretch a row past the time it covers, so rows stopped
    /// being comparable to each other (Eric: "these lines represent time - and everything else
    /// needs to align to this time-based reference"). On the rhythmic axis, time is now the only
    /// input; crowding is answered by `pixelsPerSecond`, not by a wider row.
    func testRhythmicInstrumentalWidthIsTimeOnly() {
        let width = ChordProPreviewLineLayout.instrumentalWidth(
            rhythmicSpacing: true,
            lineDuration: 2,
            chordColumnExtent: 40,
            characterWidth: 10,
            pixelsPerSecond: 100
        )

        XCTAssertEqual(width, 200, accuracy: 0.001)
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
