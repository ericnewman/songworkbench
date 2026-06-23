import XCTest

@testable import SongWorkbench

final class PitchShiftTests: XCTestCase {
    func testPitchIsClampedToOneOctave() {
        XCTAssertEqual(PitchShift.normalized(-20), -12)
        XCTAssertEqual(PitchShift.normalized(5), 5)
        XCTAssertEqual(PitchShift.normalized(20), 12)
    }

    func testSemitonesConvertToCents() {
        XCTAssertEqual(PitchShift.cents(for: -3), -300)
        XCTAssertEqual(PitchShift.cents(for: 0), 0)
        XCTAssertEqual(PitchShift.cents(for: 7), 700)
    }
}
