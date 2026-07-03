import XCTest

@testable import SongWorkbench

final class SplitProjectStoreTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testRoundTripsMultipleSongsInOrder() async throws {
        let directory = makeTempDirectory()
        let store = SplitProjectStore(directoryURL: directory)
        let document = ProjectLibraryDocument(songs: [
            StoredSongProject(
                url: directory.appendingPathComponent("b.wav"),
                settings: PracticeSettings(pitchSemitones: 2, tempoRate: 0.9)),
            StoredSongProject(
                url: directory.appendingPathComponent("a.wav"),
                settings: PracticeSettings(loopRegion: LoopRegion(start: 1, end: 5))),
        ])

        try await store.save(document)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.version, ProjectLibraryDocument.currentVersion)
        XCTAssertEqual(loaded.songs, document.songs)
        // Per-song layout: one file per song under songs/, plus the index.
        let songFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("songs"), includingPropertiesForKeys: nil)
        XCTAssertEqual(songFiles.filter { $0.pathExtension == "json" }.count, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("library.json").path))
    }

    func testEditingOneSongRewritesOnlyItsFile() async throws {
        let directory = makeTempDirectory()
        let store = SplitProjectStore(directoryURL: directory)
        let songA = StoredSongProject(
            url: directory.appendingPathComponent("a.wav"), settings: PracticeSettings())
        let songB = StoredSongProject(
            url: directory.appendingPathComponent("b.wav"), settings: PracticeSettings())
        try await store.save(ProjectLibraryDocument(songs: [songA, songB]))

        let songsDir = directory.appendingPathComponent("songs")
        let files = try FileManager.default.contentsOfDirectory(
            at: songsDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        // Snapshot each file so we can tell which one the next save touched.
        var before: [URL: (date: Date, bytes: Data)] = [:]
        for url in files {
            before[url] = (
                try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                    as! Date,
                try Data(contentsOf: url)
            )
        }
        let indexURL = directory.appendingPathComponent("library.json")
        let indexDateBefore =
            try FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]
            as! Date

        // Edit only song A.
        var editedA = songA
        editedA.settings.chordProTranspose = 5
        try await store.save(ProjectLibraryDocument(songs: [editedA, songB]))

        var changed = 0
        var unchanged = 0
        for url in files {
            let bytes = try Data(contentsOf: url)
            let date =
                try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                as! Date
            if bytes == before[url]!.bytes {
                // Untouched file: mtime must be identical.
                XCTAssertEqual(date, before[url]!.date)
                unchanged += 1
            } else {
                changed += 1
            }
        }
        XCTAssertEqual(changed, 1, "exactly one song file should be rewritten")
        XCTAssertEqual(unchanged, 1, "the other song file should be untouched")

        // Order didn't change, so the index isn't rewritten either.
        let indexDateAfter =
            try FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]
            as! Date
        XCTAssertEqual(indexDateAfter, indexDateBefore)
    }

    func testRemovingSongDeletesItsFile() async throws {
        let directory = makeTempDirectory()
        let store = SplitProjectStore(directoryURL: directory)
        let songA = StoredSongProject(
            url: directory.appendingPathComponent("a.wav"), settings: PracticeSettings())
        let songB = StoredSongProject(
            url: directory.appendingPathComponent("b.wav"), settings: PracticeSettings())
        try await store.save(ProjectLibraryDocument(songs: [songA, songB]))

        try await store.save(ProjectLibraryDocument(songs: [songA]))
        let loaded = try await store.load()

        XCTAssertEqual(loaded.songs, [songA])
        let songFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("songs"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(songFiles.count, 1)
    }

    func testBestEffortImportOfLegacyFileKeepsBackup() async throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = ProjectLibraryDocument(songs: [
            StoredSongProject(
                url: directory.appendingPathComponent("song.wav"),
                settings: PracticeSettings(pitchSemitones: 4))
        ])
        let encoder = JSONEncoder()
        try encoder.encode(legacy).write(to: directory.appendingPathComponent("projects.json"))

        let loaded = try await SplitProjectStore(directoryURL: directory).load()

        XCTAssertEqual(loaded.songs, legacy.songs)
        // Legacy file is preserved as a backup, never destroyed.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("projects.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("projects.json.premigration-backup").path))
    }
}
