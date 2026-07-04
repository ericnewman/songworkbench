import XCTest

@testable import SongWorkbench

/// C1 (backlog #8): the Lyrics tab's reference-lyrics prompt banner should surface exactly when
/// a song has lyrics to review, no reference text is set, and the user hasn't dismissed it for
/// THAT song this session — see `ReferenceLyricsPromptPolicy` in `WorkspaceEditorsView.swift`.
final class ReferenceLyricsPromptPolicyTests: XCTestCase {
    private let songA = URL(fileURLWithPath: "/tmp/song-a.wav")
    private let songB = URL(fileURLWithPath: "/tmp/song-b.wav")

    func testPromptsWhenNoReferenceAndLyricsExist() {
        XCTAssertTrue(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "",
                hasLyricSegments: true,
                selectedSongID: songA,
                dismissedForSongID: nil))
    }

    func testDoesNotPromptWithoutASelectedSong() {
        XCTAssertFalse(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "",
                hasLyricSegments: true,
                selectedSongID: nil,
                dismissedForSongID: nil))
    }

    func testDoesNotPromptWithoutAnyLyricSegments() {
        // Nothing to review yet (song not analyzed) — the prompt would be premature.
        XCTAssertFalse(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "",
                hasLyricSegments: false,
                selectedSongID: songA,
                dismissedForSongID: nil))
    }

    func testDoesNotPromptWhenReferenceLyricsAlreadySet() {
        XCTAssertFalse(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "Real lyrics here",
                hasLyricSegments: true,
                selectedSongID: songA,
                dismissedForSongID: nil))
    }

    func testWhitespaceOnlyReferenceLyricsStillCountsAsUnset() {
        XCTAssertTrue(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "   \n  ",
                hasLyricSegments: true,
                selectedSongID: songA,
                dismissedForSongID: nil))
    }

    func testDoesNotPromptAfterDismissalForTheSameSong() {
        XCTAssertFalse(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "",
                hasLyricSegments: true,
                selectedSongID: songA,
                dismissedForSongID: songA))
    }

    func testStillPromptsForADifferentSongAfterDismissingAnotherOne() {
        // Session-only, per-song dismissal: dismissing the banner for song A must not silently
        // suppress it forever for song B.
        XCTAssertTrue(
            ReferenceLyricsPromptPolicy.shouldPrompt(
                referenceLyrics: "",
                hasLyricSegments: true,
                selectedSongID: songB,
                dismissedForSongID: songA))
    }
}
