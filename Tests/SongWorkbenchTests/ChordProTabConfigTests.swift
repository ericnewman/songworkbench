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
}
