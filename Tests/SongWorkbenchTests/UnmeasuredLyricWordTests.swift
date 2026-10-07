import Foundation
import XCTest

@testable import SongWorkbench

/// A word forced alignment could not place has NO time (Eric, 2026-09-27): it is never estimated,
/// interpolated or kept from the transcriber, and a line takes its bounds from placed words only.
final class UnmeasuredLyricWordTests: XCTestCase {
    private func word(_ text: String, _ start: TimeInterval?, at lower: Int) -> TimedLyricWord {
        TimedLyricWord(
            text: text, start: start, end: start.map { $0 + 0.4 },
            characterRange: lower..<(lower + text.count))
    }

    private func line(_ start: TimeInterval, _ words: [TimedLyricWord]) -> TimedLyricSegment {
        TimedLyricSegment(
            start: start, end: start + 1, text: words.map(\.text).joined(separator: " "),
            words: words)
    }

    func testALineWithNoPlacedWordJoinsItsNeighbourWithoutGainingATime() {
        let lines = [
            line(99, [word("lead", nil, at: 0)]),
            line(10, [word("one", 10, at: 0), word("two", 11, at: 4)]),
            line(99, [word("lost", nil, at: 0), word("words", nil, at: 5)]),
            line(20, [word("three", 20, at: 0)]),
        ]

        let joined = MeasuredLyricTiming.withUnplacedLinesJoined(lines)

        XCTAssertEqual(joined.map(\.text), ["lead one two lost words", "three"])
        XCTAssertEqual(joined.map(\.start), [10, 20], "bounds stay the placed line's")
        XCTAssertEqual(joined[0].id, lines[1].id)
        XCTAssertEqual(joined[0].words.map(\.start), [nil, 10, 11, nil, nil])
        for segment in joined {
            for word in segment.words {
                XCTAssertEqual(
                    Array(segment.text)[word.characterRange].map(String.init).joined(), word.text,
                    "every range must address the joined text")
            }
        }
    }

    func testACorrectedWordWithNoCounterpartHasNoTime() {
        let raw = [word("hello", 1, at: 0), word("world", 2, at: 6)]
        let words = LyricWordRanges.words(
            for: "hello big world", from: raw, isCorrection: true)

        XCTAssertEqual(words.map(\.text), ["hello", "big", "world"])
        XCTAssertEqual(words.map(\.start), [1, nil, 2])
        XCTAssertEqual(words[1].timingSource, .unplaced)
    }

    func testAnUntimedWordIsDrawnAfterTheWordBeforeItAndNeverSounds() {
        let words = [word("a", nil, at: 0), word("b", 5, at: 2), word("c", nil, at: 4)]

        XCTAssertEqual(words.displayAnchors(lineStart: 4), [4, 5, 5])
        XCTAssertEqual(words.firstStart, 5)
        XCTAssertEqual(words.lastEnd, 5.4)
        XCTAssertFalse(words[2].hasStarted(by: 100))
        XCTAssertFalse(words[2].isSounding(at: 5.1))
    }

    func testStoredTimesStillDecodeAndAnUntimedWordRoundTrips() throws {
        let stored = Data(#"{"text":"old","start":1.5,"end":2,"characterRange":[0,3]}"#.utf8)
        let old = try JSONDecoder().decode(TimedLyricWord.self, from: stored)
        XCTAssertEqual(old.start, 1.5)
        XCTAssertEqual(old.end, 2)

        let untimed = word("new", nil, at: 0)
        let decoded = try JSONDecoder().decode(
            TimedLyricWord.self, from: JSONEncoder().encode(untimed))
        XCTAssertEqual(decoded, untimed)
    }
}
