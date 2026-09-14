import XCTest

@testable import SongWorkbench

final class ChartRowGridTests: XCTestCase {
    func testPeriodRoundsUpToWholeBarsAndIsAtLeastOneBar() {
        XCTAssertEqual(ChartRowGrid.periodBeats(phraseBeats: 8, beatsPerBar: 4), 8)
        XCTAssertEqual(ChartRowGrid.periodBeats(phraseBeats: 6, beatsPerBar: 4), 8)
        XCTAssertEqual(ChartRowGrid.periodBeats(phraseBeats: 5, beatsPerBar: 4), 8)
        XCTAssertEqual(ChartRowGrid.periodBeats(phraseBeats: 4, beatsPerBar: 4), 4)
        XCTAssertEqual(ChartRowGrid.periodBeats(phraseBeats: 8, beatsPerBar: 3), 9)
        XCTAssertEqual(ChartRowGrid.periodBeats(phraseBeats: 0, beatsPerBar: 4), 4)
    }

    func testWindowsStartOnTheBarPhaseAndTileTheWholeSong() throws {
        // 120 bpm, first detected beat at 0.25 s, first downbeat on beat 1 (0.75 s).
        let beats = (0..<24).map { 0.25 + Double($0) * 0.5 }
        let grid = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120,
                barGrid: SongBarGrid(
                    beatsPerBar: 4, barPhase: 1, confidence: 0.5, phaseSource: .drumAccents),
                phraseBeats: 6, duration: 10))

        XCTAssertEqual(grid.periodBeats, 8)
        XCTAssertEqual(grid.anchorBeatIndex, 1)
        // The pickup before the first downbeat is its own (negative) row, clipped to 0.
        XCTAssertEqual(grid.windows.map(\.index), [-1, 0, 1, 2])
        XCTAssertEqual(grid.windows.first?.start, 0)
        XCTAssertEqual(grid.windows[1].start, 0.75, accuracy: 1e-9)
        XCTAssertEqual(grid.windows[2].start, 4.75, accuracy: 1e-9)
        XCTAssertEqual(grid.windows.last?.end, 10)
        for (earlier, later) in zip(grid.windows, grid.windows.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start, accuracy: 1e-12, "rows must tile")
        }
    }

    func testBoundariesFollowMeasuredBeatsWhenTheTempoDrifts() throws {
        // Each beat 1% longer than the last: a rigid 60/bpm grid would drift off these.
        var beats: [TimeInterval] = [0]
        var length = 0.5
        for _ in 0..<60 {
            beats.append(beats.last! + length)
            length *= 1.01
        }
        let grid = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120, barGrid: nil, phraseBeats: 8, duration: beats[56]))

        for window in grid.windows where window.index > 0 {
            XCTAssertEqual(
                window.start, beats[window.index * 8], accuracy: 1e-9,
                "row \(window.index) must start on measured beat \(window.index * 8)")
        }
    }

    func testTimesMapToTheirRowWithBoundariesBelongingToTheLaterRow() throws {
        let beats = (0..<32).map { Double($0) * 0.5 }
        let grid = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120, barGrid: nil, phraseBeats: 8, duration: 16))

        XCTAssertEqual(grid.windowIndex(forTime: 0), 0)
        XCTAssertEqual(grid.windowIndex(forTime: 3.99), 0)
        XCTAssertEqual(grid.windowIndex(forTime: 4.0), 1)
        XCTAssertEqual(grid.windowIndex(forTime: 7.5), 1)
        // Before the first detected beat the grid extrapolates, so a pickup lands in row -1.
        let pickupGrid = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats.map { $0 + 1 }, bpm: 120, barGrid: nil, phraseBeats: 8,
                duration: 17))
        XCTAssertEqual(pickupGrid.windowIndex(forTime: 0.5), -1)
        XCTAssertEqual(pickupGrid.windowIndex(forTime: 1.0), 0)
    }

    func testUntimedSongsHaveNoGrid() {
        XCTAssertNil(
            ChartRowGrid.make(beatTimes: [], bpm: 120, barGrid: nil, phraseBeats: 8, duration: 10))
        XCTAssertNil(
            ChartRowGrid.make(
                beatTimes: [0, 0.5], bpm: nil, barGrid: nil, phraseBeats: 8, duration: 10))
        XCTAssertNil(
            ChartRowGrid.make(
                beatTimes: [0, 0.5], bpm: 120, barGrid: nil, phraseBeats: 8, duration: 0))
    }

    // MARK: - ChartLyricLineCutter

    /// 120 BPM, beat 0 at 0 s, one bar of 4/4 = 2 s, rows of 8 beats = 4 s.
    private func cutterGrid() throws -> ChartRowGrid {
        try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: (0..<80).map { Double($0) * 0.5 }, bpm: 120, barGrid: nil,
                phraseBeats: 8, duration: 40))
    }

    private func line(
        _ text: String, _ onsets: [TimeInterval], end: TimeInterval, accepted: Bool = false,
        overrideText: String? = nil
    ) -> TimedLyricSegment {
        var cursor = 0
        let tokens = text.split(separator: " ").map(String.init)
        let words = zip(tokens, onsets).enumerated().map { index, pair -> TimedLyricWord in
            let range = cursor..<(cursor + pair.0.count)
            cursor += pair.0.count + 1
            return TimedLyricWord(
                text: pair.0, start: pair.1,
                end: index + 1 < onsets.count ? onsets[index + 1] : end, characterRange: range)
        }
        return TimedLyricSegment(
            start: onsets.first ?? 0, end: end, text: text, words: words, accepted: accepted,
            overrideText: overrideText)
    }

    func testALineInsideOneRowStaysWholeWithItsIdentity() throws {
        let source = line("First line here", [4.0, 5.0, 6.0], end: 7.5, accepted: true)
        let lines = ChartLyricLineCutter.lines(from: [source], grid: try cutterGrid())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].windowIndex, 1)
        XCTAssertEqual(lines[0].segment, source)
        XCTAssertEqual(lines[0].sourceIDs, [source.id])
        XCTAssertFalse(lines[0].continuesOnNextRow)
        XCTAssertTrue(lines[0].isWholeSourceLine)
    }

    func testALongLineSplitsAtTheRowBoundaryAndMarksItsContinuation() throws {
        // Onsets 8.0 ... 14.5 span beats 16-29: rows 2 (16-23) and 3 (24-31).
        let source = line(
            "A much longer line that keeps on going",
            [8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 14.5],
            end: 15.0)
        let lines = ChartLyricLineCutter.lines(from: [source], grid: try cutterGrid())
        XCTAssertEqual(lines.map(\.windowIndex), [2, 3])
        XCTAssertEqual(lines.map(\.segment.text), ["A much longer line", "that keeps on going"])
        XCTAssertEqual(lines.map(\.continuesOnNextRow), [true, false])
        XCTAssertEqual(lines.map(\.segment.id), [source.id, source.id])
        XCTAssertEqual(
            lines.map(\.isWholeSourceLine), [false, false], "a split piece is not editable")
        // Character ranges are rebased onto each row's own text.
        XCTAssertEqual(
            lines[1].segment.words.map(\.characterRange), [0..<4, 5..<10, 11..<13, 14..<19])
        XCTAssertEqual(lines[1].segment.start, 12.0)
        XCTAssertEqual(lines[0].segment.end, 12.0)
    }

    func testAPickupJustBeforeARowMovesIntoIt() throws {
        // "And" one beat before the row-3 downbeat (12 s); the rest sings in row 3.
        let source = line("And then we sing", [11.5, 12.0, 13.0, 14.0], end: 15.0)
        let lines = ChartLyricLineCutter.lines(from: [source], grid: try cutterGrid())
        XCTAssertEqual(lines.map(\.windowIndex), [3])
        XCTAssertEqual(
            lines[0].segment, source, "a whole line after moving its pickup stays untouched")
        XCTAssertTrue(lines[0].isWholeSourceLine)

        // Three beats early is no pickup: it stays on the earlier row.
        let early = line("And then we sing", [10.5, 12.0, 13.0, 14.0], end: 15.0)
        XCTAssertEqual(
            ChartLyricLineCutter.lines(from: [early], grid: try cutterGrid()).map(\.windowIndex),
            [2, 3])
    }

    func testShortLinesInOneRowMergeAndAreAcceptedOnlyTogether() throws {
        let first = line("Oh yeah", [16.0, 17.0], end: 17.8, accepted: true)
        let second = line("come on", [18.0, 19.0], end: 19.8, accepted: false)
        let lines = ChartLyricLineCutter.lines(from: [second, first], grid: try cutterGrid())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].segment.text, "Oh yeah come on")
        XCTAssertEqual(lines[0].sourceIDs, [first.id, second.id])
        XCTAssertEqual(lines[0].segment.id, first.id)
        XCTAssertFalse(lines[0].segment.accepted)
        XCTAssertFalse(lines[0].isWholeSourceLine, "a shared row is not editable")
        XCTAssertEqual(lines[0].segment.start, 16.0)
        XCTAssertEqual(lines[0].segment.end, 19.8)
    }

    func testHandCorrectedAndUntimedLinesAreNeverSplit() throws {
        let corrected = line(
            "A much longer line that keeps on going",
            [8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 14.5],
            end: 15.0, overrideText: "A much longer line that keeps on rolling")
        let untimed = TimedLyricSegment(start: 20.5, end: 27.0, text: "No word timings here")
        let lines = ChartLyricLineCutter.lines(from: [untimed, corrected], grid: try cutterGrid())
        XCTAssertEqual(lines.map(\.windowIndex), [2, 5])
        XCTAssertEqual(lines[0].segment, corrected)
        XCTAssertEqual(lines[1].segment, untimed)
        XCTAssertEqual(lines.map(\.continuesOnNextRow), [false, false])
        XCTAssertEqual(lines.map(\.isWholeSourceLine), [true, true])
    }
}
