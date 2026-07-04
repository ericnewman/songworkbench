import XCTest

@testable import SongWorkbench

/// Tests for the "0:00" ASR hallucination fix (line-9-missing-chords investigation): Whisper
/// occasionally emits a bare clock/timestamp string as a "word" over quiet/ambiguous audio.
final class TimestampHallucinationFilterTests: XCTestCase {

    private func token(_ text: String, start: TimeInterval = 0, end: TimeInterval = 1)
        -> TimedTranscriptionToken
    {
        TimedTranscriptionToken(text: text, startTime: start, endTime: end, confidence: 0.9)
    }

    // MARK: - isTimestampLike

    func testRecognizesBareClockStrings() {
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("0:00"))
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("00:00"))
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("12:34"))
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("1:23:45"))
    }

    func testRecognizesClockStringsWrappedInPunctuation() {
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("(0:00)"))
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("[0:00]"))
    }

    func testRecognizesClockStringWithSurroundingWhitespace() {
        XCTAssertTrue(TimestampHallucinationFilter.isTimestampLike("  0:00  "))
    }

    func testDoesNotFlagRealWords() {
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike("right"))
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike("stone"))
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike(""))
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike("   "))
    }

    func testDoesNotFlagWordsThatMerelyContainDigitsOrColons() {
        // Only a WHOLE token matching the pattern is dropped — never a partial match inside a
        // real word, and never a number that isn't clock-shaped.
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike("911"))
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike("time:00"))
        XCTAssertFalse(TimestampHallucinationFilter.isTimestampLike("said 0:00 today"))
    }

    // MARK: - filtered

    func testFilteredDropsOnlyTimestampTokensPreservingOrderAndOthers() {
        let tokens = [
            token("Under", start: 0, end: 1),
            token("the", start: 1, end: 1.5),
            token("stars", start: 1.5, end: 2),
            token("0:00", start: 2, end: 4),
        ]

        let result = TimestampHallucinationFilter.filtered(tokens)

        XCTAssertEqual(result.map(\.text), ["Under", "the", "stars"])
    }

    func testFilteredDropsAnEntireFakeTimestampOnlyLine() {
        let tokens = [
            token("0:00", start: 10, end: 10.6),
            token("0:00", start: 10.6, end: 11.2),
        ]

        XCTAssertEqual(TimestampHallucinationFilter.filtered(tokens), [])
    }

    func testFilteredIsNoOpWhenNothingMatches() {
        let tokens = [token("hello"), token("world")]
        XCTAssertEqual(TimestampHallucinationFilter.filtered(tokens), tokens)
    }

    func testFilteredIsNoOpOnEmptyInput() {
        XCTAssertEqual(TimestampHallucinationFilter.filtered([]), [])
    }
}
