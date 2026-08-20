import XCTest

@testable import SongWorkbench

/// The pickup gutter's sizing rule, in isolation.
///
/// Two properties carry the whole design and are asserted here rather than inferred: the result is
/// always a WHOLE number of beats (that is what keeps beat columns aligned once the gutter varies
/// per row), and a row whose first sound lands on its downbeat gets ZERO (that is the reported
/// bug — Doc Holiday's opening chord is stored at beat index 0.00 yet rendered two beats in).
final class ChartPickupGutterTests: XCTestCase {
    private let beat = 0.5  // 120 BPM

    private func beats(pickupBeats: Double) -> Int {
        let downbeat = 10.0
        return ChartPickupGutter.beats(
            downbeat: downbeat,
            earliestContent: downbeat - pickupBeats * beat,
            beatLengthSeconds: beat)
    }

    /// Content ON the downbeat, or after it, reserves nothing: the row starts flush left.
    func testContentAtOrAfterTheDownbeatGetsNoGutter() {
        XCTAssertEqual(beats(pickupBeats: 0), 0)
        XCTAssertEqual(beats(pickupBeats: -1), 0)
    }

    /// Sub-deadband offsets are performance jitter, not an anacrusis. Doc Holiday's MEDIAN row
    /// pickup is 0.02 beat; without the deadband a bare `ceil` would give every such row a full
    /// beat of empty gutter and reintroduce the bug this change exists to fix.
    func testJitterInsideTheDeadbandGetsNoGutter() {
        XCTAssertEqual(beats(pickupBeats: 0.02), 0)
        XCTAssertEqual(beats(pickupBeats: ChartPickupGutter.deadbandBeats), 0)
    }

    /// A real pickup rounds UP to whole beats, so the content always fits.
    func testRealPickupsRoundUpToWholeBeats() {
        XCTAssertEqual(beats(pickupBeats: 0.20), 1)
        XCTAssertEqual(beats(pickupBeats: 1.00), 1)
        XCTAssertEqual(beats(pickupBeats: 1.01), 2)
        XCTAssertEqual(beats(pickupBeats: 1.20), 2)
        XCTAssertEqual(beats(pickupBeats: 2.00), 2)
    }

    /// A long lead-in is capped, so it can never push the row's content column off-screen.
    func testLongPickupsAreCappedAtTheMaximum() {
        XCTAssertEqual(beats(pickupBeats: 2.5), ChartPickupGutter.maximumBeats)
        XCTAssertEqual(beats(pickupBeats: 40), ChartPickupGutter.maximumBeats)
    }

    /// Degenerate inputs reserve nothing rather than crashing or reserving a default.
    func testMissingInputsGetNoGutter() {
        XCTAssertEqual(
            ChartPickupGutter.beats(
                downbeat: nil, earliestContent: 1, beatLengthSeconds: beat), 0)
        XCTAssertEqual(
            ChartPickupGutter.beats(
                downbeat: 10, earliestContent: nil, beatLengthSeconds: beat), 0)
        XCTAssertEqual(
            ChartPickupGutter.beats(
                downbeat: 10, earliestContent: 9, beatLengthSeconds: 0), 0)
    }

    /// `seconds` is `beats` × the beat length, EXACTLY — the line view divides it back out to
    /// recover the integer, so any drift here would put the gutter at a fractional beat.
    func testSecondsIsAnExactWholeNumberOfBeats() {
        for pickup in stride(from: 0.0, through: 3.0, by: 0.1) {
            let seconds = ChartPickupGutter.seconds(
                downbeat: 10, earliestContent: 10 - pickup * beat, beatLengthSeconds: beat)
            let recovered = (seconds / beat).rounded()
            XCTAssertEqual(seconds, recovered * beat, accuracy: 1e-12)
            XCTAssertLessThanOrEqual(recovered, Double(ChartPickupGutter.maximumBeats))
        }
    }

    /// The cap is the same constant the window fit reserves, or the fit could under-reserve.
    func testCapMatchesTheLayoutConstantTheFitReserves() {
        XCTAssertEqual(
            CGFloat(ChartPickupGutter.maximumBeats), ChordProPreviewLineLayout.gutterBeats)
    }
}
