import AVFoundation
import XCTest

@testable import SongWorkbench

final class MusicLibraryOpenabilityTests: XCTestCase {
    private func item(
        location: URL?,
        isProtected: Bool = false,
        title: String = "Track"
    ) -> MusicLibraryItem {
        MusicLibraryItem(
            id: UUID().uuidString,
            title: title,
            artist: "Artist",
            album: "Album",
            location: location,
            isProtected: isProtected
        )
    }

    func testDRMProtectedTrackIsBlockedRegardlessOfLocation() {
        let url = URL(fileURLWithPath: "/tmp/whatever.m4p")
        let result = item(location: url, isProtected: true).openability { _ in true }
        XCTAssertEqual(result, .drmProtected)
        XCTAssertFalse(result.canOpen)
    }

    func testCloudOnlyTrackWithNoLocationReportsNotDownloaded() {
        let result = item(location: nil).openability { _ in true }
        XCTAssertEqual(result, .notDownloaded)
    }

    func testNonFileLocationReportsNotDownloaded() {
        let url = URL(string: "https://example.com/stream.m4a")!
        let result = item(location: url).openability { _ in true }
        XCTAssertEqual(result, .notDownloaded)
    }

    func testMissingFileReported() {
        let url = URL(fileURLWithPath: "/tmp/gone.mp3")
        let result = item(location: url).openability { _ in false }
        XCTAssertEqual(result, .missingFile)
    }

    func testUnsupportedFormatReported() {
        let url = URL(fileURLWithPath: "/tmp/song.txt")
        let result = item(location: url).openability { _ in true }
        XCTAssertEqual(result, .unsupportedFormat)
    }

    func testOpenableLocalSupportedFileClassifiesOpenable() throws {
        // A real file on disk so the default (FileManager-backed) `openability`
        // and `unopenableReason` agree with the injected stub.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let classified = item(location: url)
        XCTAssertEqual(classified.openability(), .openable(url))
        XCTAssertTrue(classified.openability().canOpen)
        XCTAssertNil(classified.unopenableReason)
    }
}

@MainActor
final class MusicLibraryAppModelTests: XCTestCase {
    func testOpeningLocalLibraryTrackAddsAndSelectsSong() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(
            store: InMemoryProjectStore(),
            musicLibrary: FakeMusicLibrary(items: [])
        )
        await model.restoreProjects()

        let item = MusicLibraryItem(
            id: "1", title: "Local", artist: "A", album: "B",
            location: url, isProtected: false
        )
        let opened = model.openMusicLibraryItem(item)

        XCTAssertTrue(opened)
        XCTAssertTrue(model.songs.contains { $0.id == Song(url: url).id })
        XCTAssertEqual(model.selectedSongID, Song(url: url).id)
        XCTAssertNil(model.musicLibraryNotice)
        XCTAssertFalse(model.isMusicLibraryPickerPresented)
    }

    func testOpeningDRMTrackShowsNoticeAndAddsNothing() async throws {
        let model = AppModel(
            store: InMemoryProjectStore(),
            musicLibrary: FakeMusicLibrary(items: [])
        )
        await model.restoreProjects()

        let item = MusicLibraryItem(
            id: "1", title: "Streamed", artist: "A", album: "B",
            location: nil, isProtected: true
        )
        let opened = model.openMusicLibraryItem(item)

        XCTAssertFalse(opened)
        XCTAssertTrue(model.songs.isEmpty)
        XCTAssertNil(model.selectedSongID)
        XCTAssertNotNil(model.musicLibraryNotice)
        XCTAssertTrue(model.musicLibraryNotice?.contains("DRM") ?? false)
    }

    func testLoadMusicLibraryPopulatesItemsFromProvider() async throws {
        let provided = [
            MusicLibraryItem(
                id: "1", title: "One", artist: "A", album: "B",
                location: URL(fileURLWithPath: "/tmp/one.mp3"), isProtected: false)
        ]
        let model = AppModel(
            store: InMemoryProjectStore(),
            musicLibrary: FakeMusicLibrary(items: provided)
        )
        await model.restoreProjects()

        model.loadMusicLibrary()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(model.musicLibraryItems.map(\.id), ["1"])
        XCTAssertFalse(model.isLoadingMusicLibrary)
        XCTAssertNil(model.musicLibraryError)
    }

    func testLoadMusicLibrarySurfacesProviderError() async throws {
        let model = AppModel(
            store: InMemoryProjectStore(),
            musicLibrary: FailingMusicLibrary()
        )
        await model.restoreProjects()

        model.loadMusicLibrary()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(model.musicLibraryItems.isEmpty)
        XCTAssertNotNil(model.musicLibraryError)
        XCTAssertFalse(model.isLoadingMusicLibrary)
    }

    private func makeSilentWAV(frameCount: AVAudioFrameCount = 800) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file?.write(from: buffer)
        file = nil
        return url
    }
}

private struct FakeMusicLibrary: MusicLibraryProviding {
    let items: [MusicLibraryItem]
    func fetchSongs() throws -> [MusicLibraryItem] { items }
}

private struct FailingMusicLibrary: MusicLibraryProviding {
    struct LibraryError: Error {}
    func fetchSongs() throws -> [MusicLibraryItem] { throw LibraryError() }
}

private actor InMemoryProjectStore: ProjectStore {
    private var document = ProjectLibraryDocument()
    func load() async throws -> ProjectLibraryDocument { document }
    func save(_ document: ProjectLibraryDocument) async throws { self.document = document }
    nonisolated func saveBlocking(_ document: ProjectLibraryDocument) throws {}
}
