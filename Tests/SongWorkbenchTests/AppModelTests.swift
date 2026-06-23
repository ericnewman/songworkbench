import AVFoundation
import XCTest

@testable import SongWorkbench

@MainActor
final class AppModelTests: XCTestCase {
    func testImportDuringRestoreIsMergedInsteadOfDiscarded() async throws {
        let importedURL = try makeSilentWAV()
        let restoredURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: importedURL)
            try? FileManager.default.removeItem(at: restoredURL)
        }
        let stored = ProjectLibraryDocument(songs: [
            StoredSongProject(url: restoredURL, settings: PracticeSettings())
        ])
        let store = DelayedProjectStore(document: stored)
        let model = AppModel(store: store)

        model.importSongs(from: [importedURL])
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            Set(model.songs.map(\.id)),
            Set([Song(url: importedURL).id, Song(url: restoredURL).id])
        )
    }

    func testRecentSongsFollowSelectionOrder() async throws {
        let firstURL = try makeSilentWAV()
        let secondURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [firstURL, secondURL])
        try await Task.sleep(for: .milliseconds(120))
        let first = try XCTUnwrap(model.songs.first { $0.url == firstURL })
        let second = try XCTUnwrap(model.songs.first { $0.url == secondURL })

        model.select(first)
        model.select(second)

        XCTAssertEqual(model.recentSongs.first?.id, second.id)
    }

    func testRemovingSelectedSongPreservesSourceFileSelectsNeighborAndPersists() async throws {
        let firstURL = try makeSilentWAV()
        let secondURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let first = Song(url: firstURL)
        let second = Song(url: secondURL)
        let store = DelayedProjectStore(document: ProjectLibraryDocument())
        let model = AppModel(store: store)
        await model.restoreProjects()
        model.importSongs(from: [firstURL, secondURL])
        model.select(first)

        model.removeSong(first)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertFalse(model.songs.contains(first))
        XCTAssertEqual(model.selectedSongID, second.id)
        XCTAssertEqual(model.playback.loadedURL.map { Song(url: $0).id }, second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let lastSavedDocument = await store.lastSavedDocument()
        let saved = try XCTUnwrap(lastSavedDocument)
        XCTAssertFalse(saved.songs.contains { Song(url: $0.resolvedURL()).id == first.id })
        XCTAssertTrue(saved.songs.contains { Song(url: $0.resolvedURL()).id == second.id })
    }

    func testRemovingOnlySongClearsSelectedWorkspaceState() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let song = Song(url: url)
        let store = DelayedProjectStore(
            document: ProjectLibraryDocument(songs: [
                StoredSongProject(url: url, settings: PracticeSettings())
            ]))
        let model = AppModel(store: store)
        await model.restoreProjects()
        model.lyricSegments = [TimedLyricSegment(start: 0, end: 1, text: "Lyric")]
        model.chordProSource = "chart"

        model.removeSong(song)

        XCTAssertTrue(model.songs.isEmpty)
        XCTAssertNil(model.selectedSongID)
        XCTAssertNil(model.playback.loadedURL)
        XCTAssertTrue(model.lyricSegments.isEmpty)
        XCTAssertTrue(model.chordProSource.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testEditingReviewedLyricsReturnsThemToDraft() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [url])
        try await Task.sleep(for: .milliseconds(120))

        model.markLyricsReviewed()
        XCTAssertEqual(model.lyricReviewState, .reviewed)

        model.lyricSegments.append(
            TimedLyricSegment(start: 0, end: 1, text: "Edited lyric")
        )

        XCTAssertEqual(model.lyricReviewState, .draft)
    }

    func testPlaybackSourceSwitchTransfersPositionAndPreventsDualPlayback() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        let stemDirectory = try makeStemDirectory()
        defer {
            try? FileManager.default.removeItem(at: songURL)
            try? FileManager.default.removeItem(at: stemDirectory)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [songURL])
        try await Task.sleep(for: .milliseconds(120))
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)
        try model.importStems(from: stemDirectory)
        model.playback.seek(to: 0.4)

        model.toggleStemPlayback()

        XCTAssertEqual(model.activePlaybackSource, .stemMix)
        XCTAssertTrue(model.stemPlayback.isPlaying)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertEqual(model.stemPlayback.currentTime, 0.4, accuracy: 0.02)

        model.toggleRecordingPlayback()

        XCTAssertEqual(model.activePlaybackSource, .recording)
        XCTAssertTrue(model.playback.isPlaying)
        XCTAssertFalse(model.stemPlayback.isPlaying)
        XCTAssertEqual(model.playback.currentTime, 0.4, accuracy: 0.05)
        model.playback.pause()
    }

    func testChangingConfidenceRebuildsOnlyUnreviewedGeneratedChordPro() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let generatedRecord = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: "source",
                sourceKind: .recording,
                engineIdentifier: "chordpro-draft-builder",
                engineVersion: "2",
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier: "confidence-50",
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(timeIntervalSince1970: 1),
                loadedFromCache: false
            ),
            confidence: nil,
            errorMessage: nil
        )
        let analysis = SongAnalysisDocument(
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "One two")],
            chords: [
                EditableChordEvent(time: 0, chord: "C", confidence: 0.7),
                EditableChordEvent(time: 2, chord: "G", confidence: 0.9),
            ],
            chordProSource: "original\n",
            stageRecords: [.chordPro: generatedRecord]
        )
        let store = DelayedProjectStore(
            document: ProjectLibraryDocument(songs: [
                StoredSongProject(url: url, settings: PracticeSettings(), analysis: analysis)
            ]))
        let model = AppModel(store: store)
        await model.restoreProjects()

        model.chordConfidenceThreshold = 0.8

        XCTAssertFalse(model.chordProSource.contains("[C]"))
        XCTAssertTrue(model.chordProSource.contains("[G]"))
        XCTAssertEqual(
            model.analysisStageRecords[.chordPro]?.provenance?.configurationIdentifier,
            "confidence-80"
        )

        model.markChordProReviewed()
        let reviewedSource = model.chordProSource
        model.chordConfidenceThreshold = 0.95
        XCTAssertEqual(model.chordProSource, reviewedSource)
    }

    func testEditingLyricsRebuildsOnlyUnreviewedGeneratedChordPro() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let generatedRecord = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: "source",
                sourceKind: .recording,
                engineIdentifier: "chordpro-draft-builder",
                engineVersion: "2",
                modelIdentifier: nil,
                modelVersion: nil,
                configurationIdentifier: "confidence-50",
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(timeIntervalSince1970: 1),
                loadedFromCache: false
            ),
            confidence: nil,
            errorMessage: nil
        )
        let analysis = SongAnalysisDocument(
            lyrics: [TimedLyricSegment(start: 0, end: 4, text: "Original words")],
            chords: [EditableChordEvent(time: 0, chord: "C", confidence: 0.9)],
            chordProSource: "[C]Original words\n",
            stageRecords: [.chordPro: generatedRecord]
        )
        let store = DelayedProjectStore(
            document: ProjectLibraryDocument(songs: [
                StoredSongProject(url: url, settings: PracticeSettings(), analysis: analysis)
            ]))
        let model = AppModel(store: store)
        await model.restoreProjects()

        model.lyricSegments[0] = TimedLyricSegment(start: 0, end: 4, text: "Edited words")

        XCTAssertTrue(model.chordProSource.contains("[C]Edited words"))
        XCTAssertFalse(model.chordProSource.contains("Original words"))
        XCTAssertEqual(model.lyricReviewState, .draft)
        XCTAssertEqual(model.chordProReviewState, .draft)

        model.markChordProReviewed()
        let reviewedSource = model.chordProSource
        model.lyricSegments[0] = TimedLyricSegment(start: 0, end: 4, text: "Protected words")

        XCTAssertEqual(model.chordProSource, reviewedSource)
    }

    func testStaleSixStemAnalysisDoesNotLoadStemPlayback() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        let stemDirectory = try makeStemDirectory()
        defer {
            try? FileManager.default.removeItem(at: songURL)
            try? FileManager.default.removeItem(at: stemDirectory)
        }
        let stems = sixStemFiles(in: stemDirectory)
        let staleRecord = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: "source",
                sourceKind: .recording,
                engineIdentifier: "onnxruntime-coreml-htdemucs-6s",
                engineVersion: "1",
                modelIdentifier: ONNXSixStemSeparationEngine.cpuMetadata.modelIdentifier,
                modelVersion: ONNXSixStemSeparationEngine.cpuMetadata.modelVersion,
                configurationIdentifier: "six-stem-44.1k-stereo",
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(timeIntervalSince1970: 1),
                loadedFromCache: false
            ),
            confidence: nil,
            errorMessage: nil
        )
        let analysis = SongAnalysisDocument(
            stems: StoredStemFiles(files: stems),
            stageRecords: [.separation: staleRecord]
        )
        let store = DelayedProjectStore(
            document: ProjectLibraryDocument(songs: [
                StoredSongProject(url: songURL, settings: PracticeSettings(), analysis: analysis)
            ]))

        let model = AppModel(store: store)
        await model.restoreProjects()

        XCTAssertNotNil(model.stemFiles)
        XCTAssertFalse(model.stemPlayback.isLoaded)
        XCTAssertTrue(model.hasStaleStemPlayback)
        XCTAssertEqual(model.analysisStageRecords[.separation]?.state, .stale)
        XCTAssertEqual(
            model.analysisStageRecords[.separation]?.errorMessage,
            "Saved stems were created by an older separator. Rerun Stems."
        )
    }

    private func makeSilentWAV(frameCount: AVAudioFrameCount = 800) throws -> URL {
        try writeSilentWAV(
            to: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav"),
            frameCount: frameCount
        )
    }

    private func makeStemDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in StemKind.allCases {
            _ = try writeSilentWAV(
                to: directory.appendingPathComponent("\(kind.rawValue).wav"),
                frameCount: 16_000
            )
        }
        return directory
    }

    private func sixStemFiles(in directory: URL) -> StemFiles {
        StemFiles(
            vocals: directory.appendingPathComponent("vocals.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            guitar: directory.appendingPathComponent("guitar.wav"),
            piano: directory.appendingPathComponent("piano.wav"),
            other: directory.appendingPathComponent("other.wav"),
            accompaniment: nil
        )
    }

    private func writeSilentWAV(
        to url: URL,
        frameCount: AVAudioFrameCount
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file?.write(from: buffer)
        file = nil
        return url
    }
}

private actor DelayedProjectStore: ProjectStore {
    let document: ProjectLibraryDocument
    private(set) var savedDocuments: [ProjectLibraryDocument] = []

    init(document: ProjectLibraryDocument) {
        self.document = document
    }

    func load() async throws -> ProjectLibraryDocument {
        try await Task.sleep(for: .milliseconds(80))
        return document
    }

    func save(_ document: ProjectLibraryDocument) async throws {
        savedDocuments.append(document)
    }

    func lastSavedDocument() -> ProjectLibraryDocument? {
        savedDocuments.last
    }
}
