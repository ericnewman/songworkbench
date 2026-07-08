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
        try await waitUntil { model.songs.count >= 2 }

        // `importSongs` always copies its source into local storage (see
        // `AppModel.localizedSource`), so the imported song's final `.id` is the LOCAL copy's
        // URL, not `importedURL` itself — compare by title (the copy keeps the original
        // filename) instead of re-deriving the exact localized path here. The restored song
        // isn't re-localized, so its identity is asserted exactly.
        let titles = Set(model.songs.map(\.title))
        XCTAssertEqual(titles, Set([Song(url: importedURL).title, Song(url: restoredURL).title]))
        XCTAssertTrue(model.songs.contains { $0.id == Song(url: restoredURL).id })
    }

    func testBassNoteSourcePrefersDetectedBassNotes() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        await model.restoreProjects()
        model.importSongs(from: [url])
        try await waitUntil { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)

        // Chord roots imply an "A" bass; the detected bass line plays D2 (midi 38).
        model.chordEvents = [EditableChordEvent(time: 0, chord: "Amaj7", confidence: 1)]
        model.bassNotes = [
            BassNoteObservation(timestamp: 0, midiNote: 38, confidence: 0.9)
        ]

        // No lyrics on a silent import, so chords render in a grid row
        // (`| D |`) rather than inline (`[D]`); assert on the grid token.
        let detectedSource = model.bassNoteChordProSource
        XCTAssertTrue(
            detectedSource.contains("| D |"),
            "Expected the detected bass note D, got: \(detectedSource)"
        )
        XCTAssertFalse(
            detectedSource.contains("| A |"),
            "Detected bass line should replace the chord-root approximation"
        )

        // With no detected bass line, fall back to the chord-root bass.
        model.bassNotes = []
        XCTAssertTrue(model.bassNoteChordProSource.contains("| A |"))
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
        try await waitUntil { model.songs.count >= 2 }
        // `importSongs` always localizes into app storage (see `AppModel.localizedSource`), so
        // the imported song's final `.url` is the LOCAL copy's, not `firstURL`/`secondURL`
        // themselves — match by title (the copy keeps the original filename) instead.
        let first = try XCTUnwrap(model.songs.first { $0.title == Song(url: firstURL).title })
        let second = try XCTUnwrap(model.songs.first { $0.title == Song(url: secondURL).title })

        model.select(first)
        model.select(second)

        XCTAssertEqual(model.recentSongs.first?.id, second.id)
    }

    func testSelectingDifferentSongResetsSelectedSongProgress() async throws {
        let firstURL = try makeSilentWAV()
        let secondURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [firstURL, secondURL])
        try await waitUntil { model.songs.count >= 2 }
        // See `testRecentSongsFollowSelectionOrder`: match by title, not the pre-localization URL.
        let first = try XCTUnwrap(model.songs.first { $0.title == Song(url: firstURL).title })
        let second = try XCTUnwrap(model.songs.first { $0.title == Song(url: secondURL).title })

        model.select(first)
        model.analyzeSelectedSong()
        XCTAssertTrue(model.isSongAnalysisRunning)
        XCTAssertNotNil(model.songAnalysisProgress)

        model.select(second)

        XCTAssertFalse(model.isSongAnalysisRunning)
        XCTAssertNil(model.songAnalysisProgress)
        XCTAssertNil(model.analysisJobSnapshot)
    }

    /// `reanalyzeAllSongs()` and the auto-analyze-on-import path in `importSongs` share one
    /// `analysisQueue` (see the comment on that property) so a drag-drop import landing mid-run
    /// gets queued instead of silently dropped or interrupting the song in progress. This
    /// verifies the queue's dedup: calling `reanalyzeAllSongs()` again while it's already
    /// draining must NOT restart from song 1 or double the total — both `isSongAnalysisRunning`
    /// and `reanalyzeAllStatus` flip synchronously (before any yield), same as
    /// `testSelectingDifferentSongResetsSelectedSongProgress` above, so this is deterministic:
    /// no real analysis pipeline work has had a chance to run yet.
    func testReanalyzeAllSongsQueuesAndReentrantCallDoesNotDuplicateOrRestart() async throws {
        let firstURL = try makeSilentWAV()
        let secondURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [firstURL, secondURL])
        try await waitUntil { model.songs.count >= 2 }

        model.reanalyzeAllSongs()

        XCTAssertTrue(model.isSongAnalysisRunning)
        let firstStatus = try XCTUnwrap(model.reanalyzeAllStatus)
        XCTAssertEqual(firstStatus.index, 1)
        XCTAssertEqual(firstStatus.total, 2)

        // A second call (e.g. the user clicking "Re-analyze All" again, or an import landing)
        // must not re-seed the queue from scratch — same song, same index/total.
        model.reanalyzeAllSongs()

        let secondStatus = try XCTUnwrap(model.reanalyzeAllStatus)
        XCTAssertEqual(secondStatus.index, 1)
        XCTAssertEqual(secondStatus.total, 2)
        XCTAssertEqual(secondStatus.title, firstStatus.title)
    }

    func testRemovingSelectedSongPreservesSourceFileSelectsNeighborAndPersists() async throws {
        let firstURL = try makeSilentWAV()
        let secondURL = try makeSilentWAV()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let store = DelayedProjectStore(document: ProjectLibraryDocument())
        let model = AppModel(store: store)
        await model.restoreProjects()
        model.importSongs(from: [firstURL, secondURL])
        // `importSongs` appends both songs on a background Task — acting on `first`/`second`
        // before it lands races `removeSong`'s index-based neighbor-selection into no-op'ing
        // or picking the wrong neighbor (the exact failure this test used to catch only
        // sometimes: `removeSong` silently does nothing if `first` isn't in `model.songs` yet).
        try await waitUntil { model.songs.count >= 2 }
        // See `testRecentSongsFollowSelectionOrder`: match by title, not the pre-localization URL.
        let first = try XCTUnwrap(model.songs.first { $0.title == Song(url: firstURL).title })
        let second = try XCTUnwrap(model.songs.first { $0.title == Song(url: secondURL).title })
        model.select(first)

        model.removeSong(first)
        // `removeSong` debounces its save ~250ms (`AppModel.scheduleSave`) — poll for it
        // instead of guessing a margin over that debounce.
        try await waitUntil {
            guard let saved = await store.lastSavedDocument() else { return false }
            let ids = Set(saved.songs.map { Song(url: $0.resolvedURL()).id })
            return !ids.contains(first.id) && ids.contains(second.id)
        }

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
        try await waitUntil { !model.songs.isEmpty }

        model.markLyricsReviewed()
        XCTAssertEqual(model.lyricReviewState, .reviewed)

        model.lyricSegments.append(
            TimedLyricSegment(start: 0, end: 1, text: "Edited lyric")
        )

        XCTAssertEqual(model.lyricReviewState, .draft)
    }

    // MARK: - Review chart interactivity (backlog #15 Phase 2 remainder)

    func testToggleLyricAcceptedFlipsTheMatchingSegmentOnly() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        let target = TimedLyricSegment(start: 0, end: 1, text: "line one")
        let other = TimedLyricSegment(start: 1, end: 2, text: "line two")
        model.lyricSegments = [target, other]

        model.toggleLyricAccepted(id: target.id)

        XCTAssertTrue(model.lyricSegments[0].accepted)
        XCTAssertFalse(model.lyricSegments[1].accepted)

        model.toggleLyricAccepted(id: target.id)
        XCTAssertFalse(model.lyricSegments[0].accepted)
    }

    func testToggleLyricAcceptedIsANoOpForAnUnknownID() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.lyricSegments = [TimedLyricSegment(start: 0, end: 1, text: "line")]

        model.toggleLyricAccepted(id: UUID())

        XCTAssertFalse(model.lyricSegments[0].accepted)
    }

    func testSetLyricOverrideTextTrimsAndClearsOnBlank() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        let segment = TimedLyricSegment(start: 0, end: 1, text: "hallo werld")
        model.lyricSegments = [segment]

        model.setLyricOverrideText(id: segment.id, text: "  hello world  ")
        XCTAssertEqual(model.lyricSegments[0].overrideText, "  hello world  ")
        XCTAssertEqual(model.lyricSegments[0].effectiveText, "hello world")

        model.setLyricOverrideText(id: segment.id, text: "   ")
        XCTAssertNil(model.lyricSegments[0].overrideText)
    }

    func testToggleChordAcceptedFlipsTheMatchingEventOnly() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        let target = EditableChordEvent(time: 4, chord: "C")
        let other = EditableChordEvent(time: 8, chord: "G")
        model.chordEvents = [target, other]

        model.toggleChordAccepted(id: target.id)

        XCTAssertTrue(model.chordEvents[0].accepted)
        XCTAssertFalse(model.chordEvents[1].accepted)
    }

    func testSetChordManualTimeSetsAndClearsTheDragOverride() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        let chord = EditableChordEvent(time: 4, chord: "C")
        model.chordEvents = [chord]

        model.setChordManualTime(id: chord.id, manualTime: 4.5)
        XCTAssertEqual(model.chordEvents[0].manualTime, 4.5)
        XCTAssertEqual(model.chordEvents[0].effectiveTime, 4.5)

        model.setChordManualTime(id: chord.id, manualTime: nil)
        XCTAssertNil(model.chordEvents[0].manualTime)
        XCTAssertEqual(model.chordEvents[0].effectiveTime, 4)
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
        try await waitUntil { !model.songs.isEmpty }
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

    /// `setActivePlaybackSource` (the Stem Mix pane's Original/Stems switch) differs from
    /// `toggleRecordingPlayback`/`toggleStemPlayback` above: it must NOT force a play toggle —
    /// switching sources while paused should leave the new source paused too.
    func testSetActivePlaybackSourcePreservesPausedStateAndTransfersPosition() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        let stemDirectory = try makeStemDirectory()
        defer {
            try? FileManager.default.removeItem(at: songURL)
            try? FileManager.default.removeItem(at: stemDirectory)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [songURL])
        try await waitUntil { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)
        try model.importStems(from: stemDirectory)
        model.playback.seek(to: 0.4)

        model.setActivePlaybackSource(.stemMix)

        XCTAssertEqual(model.activePlaybackSource, .stemMix)
        XCTAssertFalse(model.stemPlayback.isPlaying)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertEqual(model.stemPlayback.currentTime, 0.4, accuracy: 0.02)
    }

    /// Switching sources while playing should keep audio flowing — just from the new source,
    /// picked up at the same position — not silently pause.
    func testSetActivePlaybackSourceKeepsPlayingAcrossSwitch() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        let stemDirectory = try makeStemDirectory()
        defer {
            try? FileManager.default.removeItem(at: songURL)
            try? FileManager.default.removeItem(at: stemDirectory)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [songURL])
        try await waitUntil { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)
        try model.importStems(from: stemDirectory)
        model.playback.seek(to: 0.4)
        model.playback.play()

        model.setActivePlaybackSource(.stemMix)

        XCTAssertEqual(model.activePlaybackSource, .stemMix)
        XCTAssertTrue(model.stemPlayback.isPlaying)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertEqual(model.stemPlayback.currentTime, 0.4, accuracy: 0.02)
        model.stemPlayback.pause()
    }

    /// Guard clauses: switching to the already-active source, or to `.stemMix` before stems are
    /// loaded, must be no-ops (no pause/seek side effects on either service).
    func testSetActivePlaybackSourceIsANoOpForCurrentSourceOrUnloadedStems() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        defer { try? FileManager.default.removeItem(at: songURL) }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [songURL])
        try await waitUntil { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)
        model.playback.seek(to: 0.4)
        model.playback.play()

        model.setActivePlaybackSource(.recording)  // already active — no-op
        XCTAssertTrue(model.playback.isPlaying)

        model.setActivePlaybackSource(.stemMix)  // stems never loaded — no-op
        XCTAssertEqual(model.activePlaybackSource, .recording)
        XCTAssertTrue(model.playback.isPlaying)
        model.playback.pause()
    }

    /// `activeClock` is the single source of truth `activePlaybackTime`/`activePlaybackDuration`/
    /// `isActivePlaybackPlaying`/`seekActivePlayback` all delegate through — this verifies it
    /// resolves to the correct concrete service (by identity) in both playback-source states,
    /// so no call site needs its own `activePlaybackSource == .stemMix ? … : …` branch.
    func testActiveClockResolvesToTheCorrectConcreteServiceForBothSources() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        let stemDirectory = try makeStemDirectory()
        defer {
            try? FileManager.default.removeItem(at: songURL)
            try? FileManager.default.removeItem(at: stemDirectory)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [songURL])
        try await waitUntil { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)
        try model.importStems(from: stemDirectory)

        XCTAssertEqual(model.activePlaybackSource, .recording)
        XCTAssertTrue(model.activeClock === model.playback)
        XCTAssertEqual(model.activePlaybackTime, model.playback.currentTime)
        XCTAssertEqual(model.activePlaybackDuration, model.playback.duration)
        XCTAssertEqual(model.isActivePlaybackPlaying, model.playback.isPlaying)

        model.toggleStemPlayback()

        XCTAssertEqual(model.activePlaybackSource, .stemMix)
        XCTAssertTrue(model.activeClock === model.stemPlayback)
        XCTAssertEqual(model.activePlaybackTime, model.stemPlayback.currentTime)
        XCTAssertEqual(model.activePlaybackDuration, model.stemPlayback.duration)
        XCTAssertEqual(model.isActivePlaybackPlaying, model.stemPlayback.isPlaying)

        model.seekActivePlayback(to: 0.3)
        XCTAssertEqual(model.stemPlayback.currentTime, 0.3, accuracy: 0.02)
        model.stemPlayback.pause()
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

    /// Eric, 2026-07-07: "When I edit lyrics on the lyrics tab, I expect those changes to
    /// propagate to all other screens." A lyric edit changes what the chart SHOULD say, so —
    /// unlike an unrelated setting such as the confidence threshold (see
    /// `testChangingConfidenceRebuildsOnlyUnreviewedGeneratedChordPro`, which correctly stays
    /// frozen after review) — editing a lyric line always un-reviews the previously-reviewed
    /// ChordPro draft and regenerates it, the same way editing `chordProSource` directly already
    /// un-reviews itself. This test used to assert the OPPOSITE (a reviewed chart stayed frozen
    /// against a lyric edit forever) — that was the exact bug Eric hit live.
    func testEditingLyricsAlwaysRebuildsGeneratedChordProEvenAfterReview() async throws {
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
        XCTAssertEqual(model.chordProReviewState, .reviewed)
        model.lyricSegments[0] = TimedLyricSegment(start: 0, end: 4, text: "Post-review words")

        XCTAssertTrue(model.chordProSource.contains("[C]Post-review words"))
        XCTAssertFalse(model.chordProSource.contains("Edited words"))
        XCTAssertEqual(
            model.chordProReviewState, .draft,
            "a lyric edit must un-review a previously-reviewed chart, not silently no-op")
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

    func testSongTypeaheadMatchesTitlePrefixCaseInsensitively() {
        let songs = [
            Song(url: URL(fileURLWithPath: "/tmp/Another day above ground.mp3")),
            Song(url: URL(fileURLWithPath: "/tmp/Summertime's her with you.mp3")),
            Song(url: URL(fileURLWithPath: "/tmp/Summer on the lake.mp3")),
        ]
        // Case-insensitive prefix picks the first title starting with it.
        XCTAssertEqual(
            SongTypeahead.firstMatch(prefix: "summ", in: songs)?.title,
            "Summertime's her with you")
        XCTAssertEqual(
            SongTypeahead.firstMatch(prefix: "ANOT", in: songs)?.title,
            "Another day above ground")
        // Empty prefix and non-matches return nil.
        XCTAssertNil(SongTypeahead.firstMatch(prefix: "", in: songs))
        XCTAssertNil(SongTypeahead.firstMatch(prefix: "zz", in: songs))
    }

    private func lyricWord(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ lo: Int)
        -> TimedLyricWord
    {
        TimedLyricWord(text: text, start: start, end: end, characterRange: lo..<(lo + text.count))
    }

    func testLyricLineMergeJoinsTextAndReindexesWords() {
        let a = TimedLyricSegment(
            start: 0, end: 1, text: "She talks",
            words: [lyricWord("She", 0, 0.4, 0), lyricWord("talks", 0.4, 1.0, 4)])
        let b = TimedLyricSegment(
            start: 4, end: 6, text: "about it",
            words: [lyricWord("about", 4, 4.5, 0), lyricWord("it", 4.5, 6, 6)])
        let merged = LyricLineEdit.merged(a, b)
        XCTAssertEqual(merged.text, "She talks about it")
        XCTAssertEqual(merged.start, 0)
        XCTAssertEqual(merged.end, 6)
        XCTAssertEqual(merged.words.count, 4)
        // Each merged word's range still points at its own text.
        for word in merged.words {
            XCTAssertEqual(String(Array(merged.text)[word.characterRange]), word.text)
        }
    }

    func testLyricLineSplitAtLargestGapRoundTrips() {
        let a = TimedLyricSegment(
            start: 0, end: 1, text: "She talks",
            words: [lyricWord("She", 0, 0.4, 0), lyricWord("talks", 0.4, 1.0, 4)])
        let b = TimedLyricSegment(
            start: 4, end: 6, text: "about it",
            words: [lyricWord("about", 4, 4.5, 0), lyricWord("it", 4.5, 6, 6)])
        let merged = LyricLineEdit.merged(a, b)
        guard let (first, second) = LyricLineEdit.split(merged) else {
            return XCTFail("expected a split at the 3s gap")
        }
        XCTAssertEqual(first.text, "She talks")
        XCTAssertEqual(second.text, "about it")
        for word in second.words {
            XCTAssertEqual(String(Array(second.text)[word.characterRange]), word.text)
        }
    }

    func testLyricLineSplitReturnsNilForSingleWord() {
        let seg = TimedLyricSegment(
            start: 0, end: 1, text: "Hey", words: [lyricWord("Hey", 0, 1, 0)])
        XCTAssertNil(LyricLineEdit.split(seg))
    }

    func testLyricDiagnosticsFlagsShortLineNotNormalLines() {
        // 120 BPM → 1 beat = 0.5s. Four 4-beat (2s) lines + one 1.2-beat (0.6s) short line.
        let beats = stride(from: 0.0, through: 12.0, by: 0.5).map { $0 }
        func seg(_ start: Double, _ end: Double) -> TimedLyricSegment {
            TimedLyricSegment(start: start, end: end, text: "x", words: [])
        }
        let segments = [seg(0, 2), seg(2, 4), seg(4, 6), seg(6, 8), seg(8, 8.6)]
        let flags = LyricLineDiagnostics.suspectReasons(segments, beatTimes: beats, tempo: 120)
        XCTAssertNotNil(flags[segments[4].id], "the 1.2-beat line should be flagged")
        XCTAssertNil(flags[segments[0].id], "a normal 4-beat line should not be flagged")
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

    nonisolated func saveBlocking(_ document: ProjectLibraryDocument) throws {}

    func lastSavedDocument() -> ProjectLibraryDocument? {
        savedDocuments.last
    }
}
