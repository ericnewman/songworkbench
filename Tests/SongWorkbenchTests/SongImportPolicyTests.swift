import Foundation
import XCTest

@testable import SongWorkbench

final class SongImportPolicyTests: XCTestCase {
    func testSupportedAudioExtensionsAreAcceptedCaseInsensitively() {
        for name in ["song.mp3", "song.M4A", "song.wav", "song.aiff", "song.flac"] {
            XCTAssertTrue(SongImportPolicy.accepts(URL(fileURLWithPath: name)))
        }
    }

    func testUnsupportedFilesAndDuplicatesAreRemoved() {
        let mp3 = URL(fileURLWithPath: "/tmp/song.mp3")
        let songs = SongImportPolicy.songs(from: [
            mp3,
            URL(fileURLWithPath: "/tmp/notes.txt"),
            mp3,
        ])

        XCTAssertEqual(songs.map(\.url), [mp3])
    }
}
