import XCTest

@testable import SongWorkbench

final class ChordProTabConfigTests: XCTestCase {
    func testChordProPlaybackPresentationUsesPreviewOnlyControls() {
        let config = ChordProTabConfig.chordProPlayback

        XCTAssertFalse(config.showsSecondaryMode)
        XCTAssertFalse(config.supportsImport)
        XCTAssertFalse(config.supportsMarkReviewed)
        XCTAssertTrue(config.supportsTranspose)
        XCTAssertTrue(config.rendersPlaybackChart)
        XCTAssertTrue(config.showsPlaybackControls)
        switch config.highlightStyle {
        case .chord:
            break
        case .bassNote:
            XCTFail("ChordPro playback must highlight chord labels")
        }
    }

    /// The ChordPro playback tab deliberately reuses the timeline-aware chart so its bouncing balls
    /// match Review mode, but it still omits Review-only editing and diagnostic affordances.
    func testChordProTabShowsPlaybackWithoutReviewAffordances() {
        XCTAssertTrue(ChordProTabConfig.chordProPlayback.rendersPlaybackChart)
        XCTAssertTrue(ChordProTabConfig.chordProPlayback.showsPlaybackControls)
        XCTAssertFalse(ChordProTabConfig.chordProPlayback.showsReviewAffordances)
    }

    func testReviewTabKeepsPlaybackAndReviewChrome() {
        XCTAssertTrue(ChordProTabConfig.chordPro.rendersPlaybackChart)
        XCTAssertTrue(ChordProTabConfig.chordPro.showsPlaybackControls)
        XCTAssertTrue(ChordProTabConfig.chordPro.showsReviewAffordances)
        XCTAssertTrue(ChordProTabConfig.bassNote.rendersPlaybackChart)
        XCTAssertTrue(ChordProTabConfig.bassNote.showsPlaybackControls)
        XCTAssertTrue(ChordProTabConfig.bassNote.showsReviewAffordances)
    }

    /// Transpose is chart function, not chrome, and stays on the plain tab — as does export.
    func testPlainChordProTabStillSupportsTranspose() {
        XCTAssertTrue(ChordProTabConfig.chordProPlayback.supportsTranspose)
    }
}
