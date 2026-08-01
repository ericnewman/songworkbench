import XCTest

@testable import SongWorkbench

final class ChordProTabConfigTests: XCTestCase {
    func testChordProPlaybackPresentationUsesPreviewOnlyControls() {
        let config = ChordProTabConfig.chordProPlayback

        XCTAssertFalse(config.showsSecondaryMode)
        XCTAssertFalse(config.supportsImport)
        XCTAssertFalse(config.supportsMarkReviewed)
        XCTAssertTrue(config.supportsTranspose)
        switch config.highlightStyle {
        case .chord:
            break
        case .bassNote:
            XCTFail("ChordPro playback must highlight chord labels")
        }
    }

    /// The ChordPro tab shows what a ChordPro file contains and nothing else: no bouncing ball,
    /// beat dots, barlines, waveform, bass-note row, chord time labels, confidence shading, or
    /// per-line accept/edit affordances. Those are the Review tab's job.
    func testChordProTabDoesNotShowPlaybackOrReviewChrome() {
        XCTAssertFalse(ChordProTabConfig.chordProPlayback.showsPlaybackChrome)
    }

    func testReviewTabKeepsPlaybackAndReviewChrome() {
        XCTAssertTrue(ChordProTabConfig.chordPro.showsPlaybackChrome)
        XCTAssertTrue(ChordProTabConfig.bassNote.showsPlaybackChrome)
    }

    /// Transpose is chart function, not chrome, and stays on the plain tab — as does export.
    func testPlainChordProTabStillSupportsTranspose() {
        XCTAssertTrue(ChordProTabConfig.chordProPlayback.supportsTranspose)
    }
}
