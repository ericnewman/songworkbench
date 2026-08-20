import AVFoundation
import XCTest

@testable import SongWorkbench

/// Drag-to-reorder in the Songs card.
///
/// The library's ARRAY ORDER is its persisted order — `SplitProjectStore` writes and reads
/// `library.json` as an ordered manifest. These cover the move itself and, just as importantly,
/// that nothing re-alphabetizes the list behind the user's back: a `.sort` on restore used to
/// discard any manual order on every launch.
@MainActor
final class SongReorderTests: XCTestCase {
    func testRestorePreservesADeliberatelyUnalphabeticalOrder() async throws {
        let urls = try (0..<3).map { _ in try makeSilentWAV() }
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }

        // Descending by title, so the expected order can ONLY survive if no alphabetical sort
        // runs during restore — whatever the random filenames happen to be.
        let descending = urls.map(Song.init).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedDescending
        }
        let document = ProjectLibraryDocument(
            songs: descending.map { StoredSongProject(url: $0.url, settings: PracticeSettings()) })
        let model = AppModel(store: ReorderTestStore(document: document))

        await model.restoreProjects()

        XCTAssertEqual(model.songs.map(\.title), descending.map(\.title))
    }

    func testMoveReordersTheLibrary() async throws {
        let urls = try (0..<3).map { _ in try makeSilentWAV() }
        defer {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        let ordered = urls.map(Song.init)
        let model = AppModel(
            store: ReorderTestStore(
                document: ProjectLibraryDocument(
                    songs: ordered.map {
                        StoredSongProject(url: $0.url, settings: PracticeSettings())
                    })))
        await model.restoreProjects()
        let before = model.songs.map(\.title)
        XCTAssertEqual(before.count, 3)

        // First song to the end.
        model.moveSongs(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(model.songs.map(\.title), [before[1], before[2], before[0]])

        // Last song back to the front.
        model.moveSongs(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.songs.map(\.title), [before[0], before[1], before[2]])
    }

    private func makeSilentWAV(frameCount: AVAudioFrameCount = 800) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }
}

private actor ReorderTestStore: ProjectStore {
    private let document: ProjectLibraryDocument

    init(document: ProjectLibraryDocument) {
        self.document = document
    }

    func load() async throws -> ProjectLibraryDocument { document }
    func save(_ document: ProjectLibraryDocument) async throws {}
    nonisolated func saveBlocking(_ document: ProjectLibraryDocument) throws {}
}
