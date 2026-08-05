import XCTest

@testable import SongWorkbench

/// The chart's font-size slider is a PROPORTIONAL zoom, not a text-only one. These tests pin the
/// part that makes that true and is easy to break later: one factor, applied to the horizontal
/// time axis and the glyph advance alike.
final class ChordProChartScaleTests: XCTestCase {
    func testMinimumSizeIsTodaysChartAndLeavesEveryLengthUnchanged() {
        let scale = ChordProChartScale.base

        XCTAssertEqual(scale.fontSize, ChordProChartTypography.lyricSize)
        XCTAssertEqual(scale.factor, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.lyricSize, ChordProChartTypography.lyricSize, accuracy: 0.0001)
        XCTAssertEqual(scale.chordSize, ChordProChartTypography.chordSize, accuracy: 0.0001)
        XCTAssertEqual(scale.scaled(22), 22, accuracy: 0.0001)
    }

    func testMaximumSizeIsDoubleTheMinimum() {
        XCTAssertEqual(
            ChordProChartScale.maximumFontSize,
            ChordProChartScale.minimumFontSize * 2,
            accuracy: 0.0001)

        let scale = ChordProChartScale(fontSize: ChordProChartScale.maximumFontSize)

        XCTAssertEqual(scale.factor, 2, accuracy: 0.0001)
        XCTAssertEqual(scale.chordSize, ChordProChartTypography.chordSize * 2, accuracy: 0.0001)
    }

    /// Out-of-range sizes clamp rather than trip an assertion: the value comes from `@AppStorage`,
    /// which can hold whatever an older build (or a hand-edited defaults plist) left behind.
    func testFontSizeClampsToTheSliderRange() {
        XCTAssertEqual(
            ChordProChartScale(fontSize: 4).fontSize,
            ChordProChartScale.minimumFontSize)
        XCTAssertEqual(
            ChordProChartScale(fontSize: 400).fontSize,
            ChordProChartScale.maximumFontSize)
        XCTAssertEqual(ChordProChartScale(fontSize: 0).factor, 1, accuracy: 0.0001)
    }

    /// Chord glyphs stay at 13/15 of the lyric size at EVERY step, so the chart's internal
    /// proportions never shift as it grows.
    func testChordToLyricRatioHoldsAtEveryStep() {
        let expected = ChordProChartTypography.chordSize / ChordProChartTypography.lyricSize
        var size = ChordProChartScale.minimumFontSize
        while size <= ChordProChartScale.maximumFontSize {
            let scale = ChordProChartScale(fontSize: size)
            XCTAssertEqual(
                scale.chordSize / scale.lyricSize, expected, accuracy: 0.0001,
                "chord/lyric ratio drifted at \(size) pt")
            size += ChordProChartScale.step
        }
    }

    /// THE constraint behind the whole feature. `ChordProPreviewLineView` places a word at
    /// `time × pixelsPerSecond` and then nudges a colliding word right by
    /// `characterCount × characterWidth`. If the font grew without the axis, the same rows would
    /// start colliding and the nudge would slide words off the beat columns they exist to prove.
    /// Scaling both by one factor leaves every x in the row multiplied by that factor — the same
    /// picture, bigger.
    func testScalingMovesTheTimeAxisAndTheGlyphAdvanceTogether() {
        let basePixelsPerSecond = ChordProPreviewLineLayout.pixelsPerSecond
        let baseCharacterWidth: CGFloat = 9
        let scale = ChordProChartScale(fontSize: ChordProChartScale.maximumFontSize)

        // A word's x is time × pixelsPerSecond; the collision cursor after it is that x plus a
        // whole number of character advances. Both must land at exactly 2x.
        let baseWordX = 1.75 * basePixelsPerSecond
        let baseCursor = baseWordX + 6 * baseCharacterWidth
        let zoomedWordX = 1.75 * scale.scaled(basePixelsPerSecond)
        let zoomedCursor = zoomedWordX + 6 * scale.scaled(baseCharacterWidth)

        XCTAssertEqual(zoomedWordX, baseWordX * 2, accuracy: 0.0001)
        XCTAssertEqual(zoomedCursor, baseCursor * 2, accuracy: 0.0001)
        // The ratio is what decides whether words collide — it must not move at all.
        XCTAssertEqual(
            zoomedCursor / zoomedWordX, baseCursor / baseWordX, accuracy: 0.0001)
    }

    /// The same rule through the one layout helper that takes both values as parameters, so a
    /// caller passing an unscaled `pixelsPerSecond` alongside a scaled `characterWidth` would show
    /// up here.
    func testInstrumentalRowWidthScalesOnBothItsBranches() {
        let scale = ChordProChartScale(fontSize: ChordProChartScale.maximumFontSize)
        let characterWidth: CGFloat = 10
        let pixelsPerSecond: CGFloat = 200

        for rhythmic in [true, false] {
            let base = ChordProPreviewLineLayout.instrumentalWidth(
                rhythmicSpacing: rhythmic,
                lineDuration: 3,
                chordColumnExtent: 12,
                characterWidth: characterWidth,
                pixelsPerSecond: pixelsPerSecond
            )
            let zoomed = ChordProPreviewLineLayout.instrumentalWidth(
                rhythmicSpacing: rhythmic,
                lineDuration: 3,
                chordColumnExtent: 12,
                characterWidth: scale.scaled(characterWidth),
                pixelsPerSecond: scale.scaled(pixelsPerSecond)
            )

            XCTAssertEqual(
                zoomed, base * scale.factor, accuracy: 0.0001,
                "instrumental width did not scale (rhythmicSpacing: \(rhythmic))")
        }
    }
}
