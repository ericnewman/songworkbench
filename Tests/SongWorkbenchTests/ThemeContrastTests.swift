import XCTest

@testable import SongWorkbench

final class ThemeContrastTests: XCTestCase {
    func testProminentControlTintMeetsNormalTextContrastAgainstWhite() {
        XCTAssertGreaterThanOrEqual(
            SWColorPalette.prominentControlTint.contrastRatio(against: .white),
            4.5
        )
    }
}
