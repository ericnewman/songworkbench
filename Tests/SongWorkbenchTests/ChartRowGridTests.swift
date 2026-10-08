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

    /// Eric, 2026-10-06: a section starts on the bar holding its first word, and the empty bar
    /// before it stays with the previous section.
    func testASectionStartsARowOnTheBarOfItsFirstWord() throws {
        // 120 bpm, 4/4 from beat 0: bars every 2 s, two-bar rows every 4 s.
        let beats = (0..<48).map { Double($0) * 0.5 }
        // The section's first word is in bar 2 of the second row (6.3 s, bar starting at 6 s).
        let grid = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120, barGrid: nil, phraseBeats: 8, duration: 24,
                sectionStarts: [6.3]))

        XCTAssertEqual(grid.windows.map(\.start), [0, 4, 6, 10, 14, 18, 22])
        // The bar before the section ends the previous section as a one-bar row.
        XCTAssertEqual(grid.windows.map(\.beats), [8, 4, 8, 8, 8, 8, 8])
        XCTAssertEqual(grid.windowIndex(forTime: 5.9), grid.windows[1].index)
        XCTAssertEqual(grid.windowIndex(forTime: 6.3), grid.windows[2].index)
        XCTAssertEqual(grid.windowIndex(forTime: 6.0), grid.windows[2].index)
        for (earlier, later) in zip(grid.windows, grid.windows.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start, accuracy: 1e-12, "rows must tile")
        }
        // A section that already starts a row changes nothing.
        let aligned = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120, barGrid: nil, phraseBeats: 8, duration: 24,
                sectionStarts: [8.4]))
        XCTAssertEqual(aligned.windows.map(\.beats), [8, 8, 8, 8, 8, 8])
        // A section whose first word is a pickup into a row's downbeat (Flip Flops, verse 2:
        // "Charcoal" 0.6 beat early) starts on that downbeat: no short row, and the pickup word
        // stays at the end of the row before.
        let pickup = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120, barGrid: nil, phraseBeats: 8, duration: 24,
                sectionStarts: [7.7]))
        XCTAssertEqual(pickup.windows.map(\.beats), [8, 8, 8, 8, 8, 8])
        XCTAssertEqual(pickup.windowIndex(forTime: 7.7), pickup.windows[1].index)
        // Earlier than the gutter is not a pickup: the section keeps the bar holding the word.
        let early = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: beats, bpm: 120, barGrid: nil, phraseBeats: 8, duration: 24,
                sectionStarts: [6.7]))
        XCTAssertEqual(early.windows.map(\.beats), [8, 4, 8, 8, 8, 8, 8])
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

    /// A line's opening pickup moves onto its line's row (Eric, 2026-10-07: "first word of verses
    /// is still crammed in to the end of the lines"); a pickup inside a line stays where it sounds.
    func testALinesOpeningPickupMovesOntoItsRowButAMidLinePickupStays() throws {
        // "And" one beat before the row-3 downbeat (12 s); the rest sings in row 3.
        let opening = line("And then we sing", [11.5, 12.0, 13.0, 14.0], end: 15.0)
        let lines = ChartLyricLineCutter.lines(from: [opening], grid: try cutterGrid())
        XCTAssertEqual(lines.map(\.windowIndex), [3])
        XCTAssertEqual(lines.map(\.segment.text), ["And then we sing"])
        XCTAssertTrue(lines[0].isWholeSourceLine)
        // Starting further out than the gutter, the line splits where it sounds as before.
        let midLine = line(
            "We go and then we sing", [10.0, 10.5, 11.5, 12.0, 13.0, 14.0], end: 15.0)
        let split = ChartLyricLineCutter.lines(from: [midLine], grid: try cutterGrid())
        XCTAssertEqual(split.map(\.segment.text), ["We go and", "then we sing"])
    }

    /// A section's opening pickup is drawn on the section's first row, not crammed onto the end of
    /// the row before (Eric, 2026-10-07, Flip Flops verse 2: "Charcoal" 0.6 beat early).
    func testASectionsOpeningPickupMovesOntoTheSectionsRow() throws {
        let grid = try XCTUnwrap(
            ChartRowGrid.make(
                beatTimes: (0..<80).map { Double($0) * 0.5 }, bpm: 120, barGrid: nil,
                phraseBeats: 8, duration: 40, sectionStarts: [11.7]))
        let source = line("Charcoal crackles sparks fly", [11.7, 12.4, 13.0, 14.0], end: 15.0)
        let lines = ChartLyricLineCutter.lines(from: [source], grid: grid)
        XCTAssertEqual(lines.map(\.windowIndex), [3])
        XCTAssertEqual(lines.map(\.segment.text), ["Charcoal crackles sparks fly"])
        XCTAssertTrue(lines[0].isWholeSourceLine)
        // Further out than the gutter is not a pickup.
        XCTAssertNil(grid.pickupWindow(forTime: 10.9))
        XCTAssertEqual(grid.pickupWindow(forTime: 11.7), 3)
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
