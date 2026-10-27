import XCTest

@testable import SongWorkbench

final class ThemeContrastTests: XCTestCase {
    func testProminentControlLabelMeetsNormalTextContrastOnItsFill() {
        XCTAssertGreaterThanOrEqual(
            SWColorPalette.prominentControlTint.contrastRatio(
                against: SWColorPalette.prominentControlLabel),
            4.5
        )
    }
}
