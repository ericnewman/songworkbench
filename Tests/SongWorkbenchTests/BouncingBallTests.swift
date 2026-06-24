import CoreGraphics
import XCTest

@testable import SongWorkbench

final class BouncingBallTests: XCTestCase {
    func testLiftIsZeroAtEachBeat() {
        let beats: [TimeInterval] = [0, 1, 2, 3]
        let ball = BouncingBall(beatTimes: beats, beatX: [0, 10, 20, 30])
        for beat in beats {
            let position = ball.position(at: beat)
            XCTAssertNotNil(position)
            XCTAssertEqual(Double(position?.lift ?? -1), 0, accuracy: 0.0001)
        }
    }

    func testLiftIsApexAtMidpoint() {
        let ball = BouncingBall(beatTimes: [0, 1, 2], beatX: [0, 10, 20])
        let mid = ball.position(at: 0.5)
        XCTAssertNotNil(mid)
        XCTAssertEqual(Double(mid?.lift ?? 0), 1, accuracy: 0.0001)
    }

    func testXEqualsWordXAtBeatsAndBetweenNeighborsMidBeat() {
        let ball = BouncingBall(beatTimes: [0, 1, 2], beatX: [0, 10, 20])
        XCTAssertEqual(Double(ball.position(at: 0)?.x ?? -1), 0, accuracy: 0.0001)
        XCTAssertEqual(Double(ball.position(at: 1)?.x ?? -1), 10, accuracy: 0.0001)
        XCTAssertEqual(Double(ball.position(at: 2)?.x ?? -1), 20, accuracy: 0.0001)

        let midX = Double(ball.position(at: 0.5)?.x ?? -1)
        XCTAssertGreaterThan(midX, 0)
        XCTAssertLessThan(midX, 10)
        // smoothstep(0.5) == 0.5 -> exactly between neighbors.
        XCTAssertEqual(midX, 5, accuracy: 0.0001)
    }

    func testNilBeforeFirstAndAfterLast() {
        let ball = BouncingBall(beatTimes: [1, 2, 3], beatX: [0, 10, 20])
        XCTAssertNil(ball.position(at: 0.5))
        XCTAssertNil(ball.position(at: 3.5))
        XCTAssertNotNil(ball.position(at: 1))
        XCTAssertNotNil(ball.position(at: 3))
    }

    func testNilWhenEmptyBeats() {
        let ball = BouncingBall(beatTimes: [], beatX: [])
        XCTAssertNil(ball.position(at: 0))
    }

    func testBeatsFromExistingBeatTimesWithinSegmentIncludeNeighbors() {
        let beatTimes: [TimeInterval] = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
        let beats = BouncingBall.beats(in: 1.0, 2.0, beatTimes: beatTimes, bpm: nil)
        // Includes the neighbor before (0.5) and after (2.5) the [1.0, 2.0] range.
        XCTAssertEqual(beats, [0.5, 1.0, 1.5, 2.0, 2.5])
    }

    func testBeatsBpmSynthesisProducesEvenlySpacedBeats() {
        let beats = BouncingBall.beats(in: 0, 2, beatTimes: [], bpm: 120)
        // 120 BPM -> 0.5s per beat. Beats at 0, 0.5, 1.0, 1.5, 2.0, plus one extra (2.5).
        XCTAssertEqual(beats.count, 6)
        for (index, beat) in beats.enumerated() {
            XCTAssertEqual(beat, Double(index) * 0.5, accuracy: 0.0001)
        }
    }

    func testBeatsEmptyWhenNoBeatTimesAndNoOrZeroBpm() {
        XCTAssertTrue(BouncingBall.beats(in: 0, 2, beatTimes: [], bpm: nil).isEmpty)
        XCTAssertTrue(BouncingBall.beats(in: 0, 2, beatTimes: [], bpm: 0).isEmpty)
        XCTAssertTrue(BouncingBall.beats(in: 0, 2, beatTimes: [], bpm: -10).isEmpty)
    }

    func testWordOnsetsProduceTapsAtEachWordStartWithWordCenterX() {
        // Mirror the word-onset wiring: beatTimes = word starts, beatX = word centers.
        // "Walk the low line" with character ranges and a monospaced character width.
        let characterWidth: CGFloat = 9
        let words = [
            TimedLyricWord(text: "Walk", start: 0.0, end: 1.0, characterRange: 0..<4),
            TimedLyricWord(text: "the", start: 1.5, end: 2.0, characterRange: 5..<8),
            TimedLyricWord(text: "low", start: 3.0, end: 3.5, characterRange: 9..<12),
            TimedLyricWord(text: "line", start: 4.5, end: 5.0, characterRange: 13..<17),
        ]
        let beatTimes = words.map(\.start)
        let centers: [CGFloat] = words.map { word in
            (CGFloat(word.characterRange.lowerBound) + CGFloat(word.characterRange.upperBound))
                / 2 * characterWidth
        }
        let ball = BouncingBall(beatTimes: beatTimes, beatX: centers)

        for (index, word) in words.enumerated() {
            let position = ball.position(at: word.start)
            XCTAssertNotNil(position)
            // Tap (lift == 0) exactly at each word's onset.
            XCTAssertEqual(Double(position?.lift ?? -1), 0, accuracy: 0.0001)
            // And the tap lands on that word's character center.
            XCTAssertEqual(position?.x ?? -1, centers[index], accuracy: 0.0001)
        }
    }

    func testSynthesizedBeatsDriveASmoothArc() {
        let beats = BouncingBall.beats(in: 0, 2, beatTimes: [], bpm: 120)
        let xs = beats.map { CGFloat($0 * 100) }
        let ball = BouncingBall(beatTimes: beats, beatX: xs)
        // Tap at a beat.
        XCTAssertEqual(Double(ball.position(at: 0.5)?.lift ?? -1), 0, accuracy: 0.0001)
        // Apex mid-beat between 0.5 and 1.0.
        XCTAssertEqual(Double(ball.position(at: 0.75)?.lift ?? -1), 1, accuracy: 0.0001)
    }
}
