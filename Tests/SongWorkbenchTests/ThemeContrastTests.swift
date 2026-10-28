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

    /// The dark grounds text sits on: Night (canvas), Scope (panels), Grid (raised mixer panel).
    private let grounds: [UInt32] = [0x0D1117, 0x070A0E, 0x1C2532]

    /// Solid Mist replaced the 0.5–0.8-opacity dims on the chord grid, status icon, bar numbers,
    /// rests, section times and held chords (2026-10-28). It must clear 4.5:1 on every ground.
    func testMistSecondaryTextMeetsNormalTextContrastOnEveryGround() {
        for ground in grounds {
            XCTAssertGreaterThanOrEqual(
                SWRGBColor(hex: 0x8B96A3).contrastRatio(against: SWRGBColor(hex: ground)), 4.5,
                String(format: "Mist on %06X", ground))
        }
    }

    /// Increase Contrast swaps Mist for Text; the swap must reach 7:1.
    func testIncreasedContrastSecondaryTextReachesSevenToOne() {
        for ground in grounds {
            XCTAssertGreaterThanOrEqual(
                SWRGBColor(hex: 0xC3CCD6).contrastRatio(against: SWRGBColor(hex: ground)), 7,
                String(format: "Text on %06X", ground))
        }
    }

    /// Stem lane colors label the chart's bucket and tab rows at full strength (the 0.85-opacity
    /// violet measured 4.39:1).
    func testSolidLaneColorsMeetNormalTextContrastOnEveryGround() {
        let lanes: [UInt32] = [0xCC5DE8, 0x22B8CF, 0xF06595, 0x339AF0, 0x20C997, 0xFF6B6B]
        for lane in lanes {
            for ground in grounds {
                XCTAssertGreaterThanOrEqual(
                    SWRGBColor(hex: lane).contrastRatio(against: SWRGBColor(hex: ground)), 4.5,
                    String(format: "%06X on %06X", lane, ground))
            }
        }
    }
}

final class TextScaleTests: XCTestCase {
    func testStepsWalkUpAndDownAndClamp() {
        let defaults = UserDefaults(suiteName: "TextScaleTests-\(UUID().uuidString)")!
        let scale = SWTextScale(defaults: defaults)
        XCTAssertEqual(scale.factor, 1)
        XCTAssertEqual(SWTextScale.clamped(10), SWTextScale.steps.last)
        XCTAssertEqual(SWTextScale.clamped(0.1), SWTextScale.steps.first)
        XCTAssertEqual(SWTextScale.clamped(.nan), 1)
    }

    /// The chart takes the text size as zoom, so glyph size and character advance scale by the
    /// same factor (the geometry tests' invariant), instead of the glyphs growing alone.
    func testChartScaleCarriesTextSizeIntoGlyphsAndAxisTogether() {
        let base = ChordProChartScale(fontSize: ChordProChartScale.minimumFontSize)
        let bigger = ChordProChartScale(fontSize: ChordProChartScale.minimumFontSize * 1.5)
        XCTAssertEqual(bigger.lyricSize / base.lyricSize, 1.5, accuracy: 1e-9)
        XCTAssertEqual(bigger.scaled(128) / base.scaled(128), 1.5, accuracy: 1e-9)
    }
}
