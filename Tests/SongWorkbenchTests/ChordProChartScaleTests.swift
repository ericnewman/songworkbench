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

    func testMaximumZoomIsTripleTheMinimum() {
        XCTAssertEqual(
            ChordProChartScale.maximumFontSize,
            ChordProChartScale.minimumFontSize * 3,
            accuracy: 0.0001)

        let scale = ChordProChartScale(fontSize: ChordProChartScale.maximumFontSize)

        XCTAssertEqual(scale.zoom, 3, accuracy: 0.0001)
        XCTAssertEqual(scale.factor, 3, accuracy: 0.0001)
        XCTAssertEqual(scale.chordSize, ChordProChartTypography.chordSize * 3, accuracy: 0.0001)
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
        let scale = ChordProChartScale(fontSize: ChordProChartScale.minimumFontSize * 2)

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

    // MARK: - Window fit

    private let inset = ChordProPreviewLineLayout.chartHorizontalInset
    private let leading = ChordProPreviewLineLayout.rowLeadingWidth
    private let gutterBeats = ChordProPreviewLineLayout.gutterBeats

    private func fit(width: CGFloat, beatsPerLine: Int, bpm: Double) -> ChordProChartScale {
        ChordProChartScale(
            fontSize: ChordProChartScale.minimumFontSize,
            fitFactor: ChordProChartScale.fitFactor(
                availableWidth: width,
                horizontalInset: inset,
                rowLeadingWidth: leading,
                beatsPerLine: beatsPerLine,
                gutterBeats: gutterBeats,
                beatLengthSeconds: bpm > 0 ? 60 / bpm : 0,
                basePixelsPerSecond: ChordProPreviewLineLayout.pixelsPerSecond))
    }

    /// The width of a row exactly one phrase period long, drawn at `scale` — the same arithmetic
    /// `ChordProPreviewLineView` does (`gutterPx + beats × pixelsPerBeat`, plus the line-number
    /// column the row's `HStack` puts to its left).
    private func phraseRowWidth(
        scale: ChordProChartScale, beatsPerLine: Int, bpm: Double
    ) -> CGFloat {
        let pixelsPerSecond = scale.scaled(ChordProPreviewLineLayout.pixelsPerSecond)
        let pixelsPerBeat = CGFloat(60 / bpm) * pixelsPerSecond
        return scale.scaled(leading) + (gutterBeats + CGFloat(beatsPerLine)) * pixelsPerBeat
    }

    /// THE rule, as an equation: at 1× zoom one phrase period — plus its pickup gutter and the
    /// row's own leading furniture — is exactly the width the chart was given. No horizontal
    /// scrolling for a correctly cut row, on any song.
    func testOnePhrasePeriodExactlyFillsTheAvailableWidth() {
        for width: CGFloat in [900, 1400, 2400] {
            for (beatsPerLine, bpm) in [(8, 120.0), (12, 96.0), (14, 143.0), (16, 72.0)] {
                let scale = fit(width: width, beatsPerLine: beatsPerLine, bpm: bpm)
                XCTAssertEqual(
                    phraseRowWidth(scale: scale, beatsPerLine: beatsPerLine, bpm: bpm),
                    width - inset, accuracy: 0.01,
                    "P=\(beatsPerLine) at \(bpm) bpm did not fill \(width) px")
            }
        }
    }

    /// A beat's width comes out as the window divided by the phrase, so it depends on the PHRASE
    /// and the window and (near enough) not on the tempo: two songs at wildly different tempi with
    /// the same period render at the same scale. That is what makes "one phrase per row" a
    /// page-level rule rather than a per-song accident.
    ///
    /// "Near enough" and not exact because the line-number column scales with the chart too, so it
    /// takes a slightly tempo-dependent share of the width. The ROW's total width is exact either
    /// way — see `testOnePhrasePeriodExactlyFillsTheAvailableWidth`.
    func testFittedBeatWidthBarelyMovesWithTempo() {
        let slow = fit(width: 1400, beatsPerLine: 8, bpm: 60)
        let fast = fit(width: 1400, beatsPerLine: 8, bpm: 180)
        let slowBeat = CGFloat(60 / 60.0) * slow.scaled(ChordProPreviewLineLayout.pixelsPerSecond)
        let fastBeat = CGFloat(60 / 180.0) * fast.scaled(ChordProPreviewLineLayout.pixelsPerSecond)
        let ideal = (1400 - inset) / (8 + gutterBeats)

        XCTAssertEqual(slowBeat, fastBeat, accuracy: ideal * 0.05)
        XCTAssertEqual(slowBeat, ideal, accuracy: ideal * 0.05)
        XCTAssertEqual(fastBeat, ideal, accuracy: ideal * 0.05)
    }

    /// The fallback that keeps every existing song rendering exactly as it did: with no phrase
    /// period (the estimator returns nil on songs whose line onsets don't resolve), no tempo, or
    /// no viewport yet, the fit is 1 — the fixed 200 px/s chart.
    func testFitFallsBackToTheFixedAxisWhenThePeriodIsUnavailable() {
        XCTAssertEqual(fit(width: 1400, beatsPerLine: 0, bpm: 120).fitFactor, 1, accuracy: 0.0001)
        XCTAssertEqual(fit(width: 1400, beatsPerLine: -3, bpm: 120).fitFactor, 1, accuracy: 0.0001)
        XCTAssertEqual(fit(width: 1400, beatsPerLine: 8, bpm: 0).fitFactor, 1, accuracy: 0.0001)
        XCTAssertEqual(fit(width: 0, beatsPerLine: 8, bpm: 120).fitFactor, 1, accuracy: 0.0001)
        XCTAssertEqual(fit(width: 20, beatsPerLine: 8, bpm: 120).fitFactor, 1, accuracy: 0.0001)
        // And a 1 fit leaves the chart at exactly today's geometry.
        let fallback = fit(width: 1400, beatsPerLine: 0, bpm: 120)
        XCTAssertEqual(fallback.factor, 1, accuracy: 0.0001)
        XCTAssertEqual(
            fallback.scaled(ChordProPreviewLineLayout.pixelsPerSecond),
            ChordProPreviewLineLayout.pixelsPerSecond, accuracy: 0.0001)
    }

    /// Zoom sits ON TOP of the fit: 2× draws the fitted chart at twice the size, which overflows
    /// the window and brings horizontal scrolling back deliberately.
    func testZoomMultipliesTheFittedChart() {
        let fitted = fit(width: 1400, beatsPerLine: 12, bpm: 96)
        let zoomed = ChordProChartScale(
            fontSize: ChordProChartScale.minimumFontSize * 2, fitFactor: fitted.fitFactor)

        XCTAssertEqual(zoomed.zoom, 2, accuracy: 0.0001)
        XCTAssertEqual(zoomed.factor, fitted.factor * 2, accuracy: 0.0001)
        XCTAssertEqual(
            phraseRowWidth(scale: zoomed, beatsPerLine: 12, bpm: 96),
            (1400 - inset) * 2, accuracy: 0.02)
    }

    /// The fit shrinks the GLYPHS by the same factor as the axis — the one property the whole
    /// layout depends on (see `testScalingMovesTheTimeAxisAndTheGlyphAdvanceTogether`). A fit that
    /// squeezed the axis while leaving 15 pt text would make words collide and the nudge would
    /// slide them off their beat columns.
    func testFitMovesGlyphsAndAxisTogether() {
        // A long phrase in a narrow window: the fit must be well under 1 for this to prove anything.
        let scale = fit(width: 900, beatsPerLine: 16, bpm: 80)
        XCTAssertLessThan(scale.fitFactor, 0.9)

        XCTAssertEqual(
            scale.lyricSize / ChordProChartTypography.lyricSize, scale.factor, accuracy: 0.0001)
        XCTAssertEqual(
            scale.scaled(ChordProPreviewLineLayout.pixelsPerSecond)
                / ChordProPreviewLineLayout.pixelsPerSecond, scale.factor, accuracy: 0.0001)
        XCTAssertEqual(
            scale.chordSize / scale.lyricSize,
            ChordProChartTypography.chordSize / ChordProChartTypography.lyricSize, accuracy: 0.0001)
    }

    /// Degenerate inputs clamp instead of collapsing or exploding the chart.
    func testFitClampsOnDegenerateInput() {
        let tiny = fit(width: 400, beatsPerLine: 512, bpm: 40)
        XCTAssertEqual(tiny.fitFactor, ChordProChartScale.minimumFitFactor, accuracy: 0.0001)

        let huge = fit(width: 8000, beatsPerLine: 2, bpm: 200)
        XCTAssertEqual(huge.fitFactor, ChordProChartScale.maximumFitFactor, accuracy: 0.0001)

        XCTAssertEqual(
            ChordProChartScale(fontSize: 15, fitFactor: .nan).fitFactor, 1, accuracy: 0.0001)
    }
}
