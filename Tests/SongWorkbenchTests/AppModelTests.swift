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

    /// A dropped song must be visible before its file has finished being copied in. It used to
    /// appear only after localization (a whole-file copy, plus an iCloud download for cloud
    /// sources), which reads as a failed drop and gets retried.
    func testDroppedSongIsListedAsImportingBeforeLocalizationCompletes() async throws {
        let sourceURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let store = DelayedProjectStore(document: ProjectLibraryDocument(songs: []))
        let model = AppModel(store: store)

        model.importSongs(from: [sourceURL])

        // Synchronously after the call — no awaiting, no polling.
        XCTAssertEqual(model.importingSongs.map(\.title), [Song(url: sourceURL).title])
        // ...and NOT in `songs`, which every other part of the app reads as "real, playable".
        XCTAssertTrue(model.songs.isEmpty)

        try await waitUntil { model.importingSongs.isEmpty }
        XCTAssertEqual(model.songs.map(\.title), [Song(url: sourceURL).title])
    }

    /// A failed import must not leave its row spinning forever.
    func testFailedImportClearsTheImportingRow() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Gone.wav")
        let store = DelayedProjectStore(document: ProjectLibraryDocument(songs: []))
        let model = AppModel(store: store)

        model.importSongs(from: [missingURL])

        // The file does not exist, so it never becomes an importing row at all.
        XCTAssertTrue(model.importingSongs.isEmpty)
        XCTAssertTrue(model.songs.isEmpty)
    }

    func testRestoreUsesReadableLocalSourceCacheWhenSavedSourceIsMissing() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Legacy Choir Song.wav")
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cachedDirectory = cacheRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let cachedURL = cachedDirectory.appendingPathComponent(missingURL.lastPathComponent)
        try FileManager.default.createDirectory(
            at: cachedDirectory,
            withIntermediateDirectories: true
        )
        _ = try writeSilentWAV(to: cachedURL, frameCount: 800)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let store = DelayedProjectStore(
            document: ProjectLibraryDocument(songs: [
                StoredSongProject(url: missingURL, settings: PracticeSettings())
            ]))
        let model = AppModel(store: store, sourceRecoveryDirectories: [cacheRoot])

        await model.restoreProjects()

        XCTAssertEqual(model.songs.first?.url.standardizedFileURL, cachedURL.standardizedFileURL)
        XCTAssertEqual(model.selectedSong?.url.standardizedFileURL, cachedURL.standardizedFileURL)
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

    func testDroppingTheSameAudioContentFromTwoPathsImportsOnce() async throws {
        let firstURL = try makeSilentWAV()
        // The same BYTES at a different original path: path-keyed identity sees two songs,
        // only the content digest gives the twin away.
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try FileManager.default.copyItem(at: firstURL, to: copyURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: copyURL)
        }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [firstURL, copyURL])
        try await waitUntil(timeout: .seconds(15)) {
            model.importStatus?.contains("duplicate") == true
        }
        XCTAssertEqual(model.songs.count, 1)
        XCTAssertEqual(model.importStatus, "Added 1 song · 1 duplicate skipped")
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

        // Cancel the drain (select() cancels the in-flight run, whose queue-completion clears
        // the rest of the queue) — REAL analysis engines are installed on dev machines, so a
        // leaked 2-song queue saturates the CPU and starves later tests' 3 s waitUntil polls
        // (measured 2026-08-10: testReimportOfChangedSourceRefreshesStaleLocalCopy's import
        // wait and MusicLibrary's 150 ms provider-error sleep both timed out downstream).
        model.select(try XCTUnwrap(model.songs.first))
        XCTAssertFalse(model.isSongAnalysisRunning)
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

    /// The Review popup's corrections write the same storage the Chords page edits — and unlike
    /// the Chords page's raw binding, they rebuild the generated chart immediately (Eric,
    /// 2026-07-07: edits propagate to every screen).
    func testSetChordNameRewritesTheEventAndTheGeneratedChart() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.lyricSegments = [TimedLyricSegment(start: 0, end: 4, text: "one two")]
        let chord = EditableChordEvent(time: 0, chord: "Cmaj", confidence: 0.9)
        model.chordEvents = [chord]

        model.markChordsReviewed()
        model.setChordName(id: chord.id, name: "C7")

        XCTAssertEqual(model.chordEvents[0].chord, "C7")
        // A rename is an edit: a previously reviewed chart must drop back to draft. (The chart
        // TEXT rebuild is gated on a selected song + succeeded chordPro stage — production
        // conditions covered by the builder tests, not constructible here.)
        XCTAssertEqual(model.chordReviewState, .draft)

        // Whitespace-only names are refused rather than committed as an empty chord.
        model.setChordName(id: chord.id, name: "   ")
        XCTAssertEqual(model.chordEvents[0].chord, "C7")
    }

    /// Hiding removes the chord from the chart, the included count, and the click times, while
    /// the event itself stays for un-hiding from the Chords page.
    func testSetChordHiddenExcludesFromChartCountAndClick() {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.lyricSegments = [TimedLyricSegment(start: 0, end: 4, text: "one two")]
        let hiddenChord = EditableChordEvent(time: 0, chord: "F#dim", confidence: 0.9)
        let kept = EditableChordEvent(time: 2, chord: "G", confidence: 0.9)
        model.chordEvents = [hiddenChord, kept]

        model.setChordHidden(id: hiddenChord.id, hidden: true)

        XCTAssertTrue(model.chordEvents[0].hidden)
        XCTAssertFalse(model.isChordIncludedInChordPro(model.chordEvents[0]))
        XCTAssertEqual(model.includedChordEventCount, 1)
        XCTAssertEqual(model.placedChordTimes, [2], "a hidden chord must not click")

        model.setChordHidden(id: hiddenChord.id, hidden: false)
        XCTAssertTrue(model.isChordIncludedInChordPro(model.chordEvents[0]))
        XCTAssertEqual(model.includedChordEventCount, 2)
        XCTAssertEqual(model.placedChordTimes, [0, 2])
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

    func testAuditioningAPlacementLeavesTheStoredChordsAndReviewStateAlone() {
        // The whole point of the audition being a separate transient property: listening to an
        // alternative placement must not mutate `chordEvents` (whose didSet writes the document)
        // and must not knock a reviewed chart back to draft.
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        var chord = EditableChordEvent(time: 4, chord: "C")
        chord.placementCandidates[ChordPlacementVariant.beatQuantized.rawValue] = 4
        chord.placementCandidates[ChordPlacementVariant.instrumentOnset.rawValue] = 3.8
        model.chordEvents = [chord]
        model.markChordsReviewed()
        let before = model.chordEvents

        model.auditionedPlacement = .instrumentOnset

        XCTAssertEqual(model.chordEvents, before)
        XCTAssertEqual(model.chordReviewState, .reviewed)
        // ...while everything that draws or clicks does move.
        XCTAssertEqual(model.placementTime(for: chord), 3.8)
        XCTAssertEqual(model.placedChordTimes, [3.8])

        model.auditionedPlacement = nil
        XCTAssertEqual(model.placedChordTimes, [4])
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
            "\(ChordProDraftBuilder.algorithmTag)-confidence-80"
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

    func testStaleSixStemAnalysisStillLoadsPresentStemPlaybackWithWarning() async throws {
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
        XCTAssertTrue(model.stemPlayback.isLoaded)
        XCTAssertTrue(model.hasStaleStemPlayback)
        XCTAssertEqual(model.analysisStageRecords[.separation]?.state, .stale)
        XCTAssertEqual(
            model.analysisStageRecords[.separation]?.errorMessage,
            "Saved stems were created by an older separator. Rerun Stems."
        )
    }

    func testStaleSixStemAnalysisWithMissingFilesDoesNotLoadStemPlayback() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        let stemDirectory = try makeStemDirectory()
        defer {
            try? FileManager.default.removeItem(at: songURL)
            try? FileManager.default.removeItem(at: stemDirectory)
        }
        let stems = sixStemFiles(in: stemDirectory)
        try FileManager.default.removeItem(at: stems.vocals)
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
    }

    /// Starting a user-initiated analysis during playback must stop playback (Eric,
    /// 2026-08-10). Deterministic: `stopPlaybackForAnalysis()` runs synchronously inside
    /// `analyzeSelectedSong()` before any async pipeline work.
    func testAnalyzeSelectedSongStopsPlayback() async throws {
        let songURL = try makeSilentWAV(frameCount: 16_000)
        defer { try? FileManager.default.removeItem(at: songURL) }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [songURL])
        try await waitUntil { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)
        model.playback.play()
        XCTAssertTrue(model.playback.isPlaying)

        model.analyzeSelectedSong()

        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertFalse(model.stemPlayback.isPlaying)
        XCTAssertTrue(model.isSongAnalysisRunning)
        // Cancel the in-flight run (select() resets progress state) so this test's analysis
        // doesn't bleed CPU into later tests' short waitUntil timeouts.
        model.select(song)
        XCTAssertFalse(model.isSongAnalysisRunning)
    }

    /// Re-importing a source whose CONTENT changed at the same original path must replace the
    /// stale local copy (localizedSource keys the copy by original path) instead of silently
    /// serving the old audio forever, and must keep a single library entry (same song id).
    func testReimportOfChangedSourceRefreshesStaleLocalCopy() async throws {
        let sourceURL = try makeSilentWAV(frameCount: 8_000)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        model.importSongs(from: [sourceURL])
        // Generous timeouts: imports copy files off-main and dev machines may still be
        // finishing another test's cancelled analysis teardown.
        try await waitUntil(timeout: .seconds(15)) { !model.songs.isEmpty }
        let song = try XCTUnwrap(model.songs.first)
        let localURL = song.url
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int)

        // Replace the source at the SAME path with different content (different length).
        try FileManager.default.removeItem(at: sourceURL)
        _ = try writeSilentWAV(to: sourceURL, frameCount: 24_000)

        model.importSongs(from: [sourceURL])
        try await waitUntil(timeout: .seconds(15)) {
            let size =
                (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size])
                as? Int
            return size != nil && size != originalSize
        }

        XCTAssertEqual(model.songs.count, 1)
        XCTAssertEqual(model.songs.first?.id, song.id)
        // Cancel the auto-analysis the refresh enqueued (select() cancels and clears the
        // queue) so it doesn't bleed CPU into later tests.
        model.select(song)
        XCTAssertFalse(model.isSongAnalysisRunning)
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

    /// Monotonic fingerprint so no two generated WAVs are byte-identical: `importSongs` now
    /// skips content duplicates (the feature under test elsewhere), so two literally silent
    /// fixtures would import as one song and hang every multi-song test.
    private static var wavFingerprint: Float = 0

    private func writeSilentWAV(
        to url: URL,
        frameCount: AVAudioFrameCount
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // One inaudible unique sample (LSB scale) as the fingerprint.
        Self.wavFingerprint += 1e-6
        buffer.floatChannelData?[0][0] = Self.wavFingerprint
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
        func seg(_ start: Double, _ end: Double) -> TimedLyricSegment {
            TimedLyricSegment(start: start, end: end, text: "x", words: [])
        }
        let segments = [seg(0, 2), seg(2, 4), seg(4, 6), seg(6, 8), seg(8, 8.6)]
        let flags = LyricLineDiagnostics.suspectReasons(segments, tempo: 120)
        XCTAssertNotNil(flags[segments[4].id], "the 1.2-beat line should be flagged")
        XCTAssertNil(flags[segments[0].id], "a normal 4-beat line should not be flagged")
    }

    func testLyricDiagnosticsAllowsConsistentLengthPhrasesWithOffbeatPickups() {
        // Vocal phrases routinely begin between beats. Onset phase alone is not evidence of a
        // bad split unless there is an expected phrase template to compare it against.
        let starts = [0.18, 2.37, 4.71, 7.20, 9.44]
        let segments = starts.map {
            TimedLyricSegment(start: $0, end: $0 + 2, text: "normal phrase", words: [])
        }

        let flags = LyricLineDiagnostics.suspectReasons(segments, tempo: 120)

        XCTAssertTrue(flags.isEmpty)
    }

    // MARK: - Background activity status line

    /// The batch position used to be its own early-returning branch, which hid the stage and
    /// percent for every queue-driven run (import auto-analyze AND "Re-analyze All"). One line
    /// now carries all three.
    func testAnalysisStatusLineCombinesBatchPositionStageAndTitle() {
        let line = AppModel.analysisStatusLine(
            batch: AppModel.ReanalyzeAllStatus(index: 3, total: 25, title: "Doc Holiday"),
            progress: SongAnalysisPipelineProgress(
                stage: .separation,
                completedStages: 0,
                totalStages: 4,
                stageFraction: 0.47,
                message: "separating"
            )
        )
        XCTAssertEqual(line, "Re-analyzing 3 of 25 · Stems 47% · Doc Holiday")
    }

    /// Separation is stage 1 of 4, so the whole-pipeline fraction would read 12% here and never
    /// pass ~25% for the longest stage in the app. The stage's own fraction is what's shown.
    func testAnalysisStatusLineUsesStageFractionNotWholePipelineFraction() {
        let progress = SongAnalysisPipelineProgress(
            stage: .separation,
            completedStages: 0,
            totalStages: 4,
            stageFraction: 0.5,
            message: "separating"
        )
        XCTAssertEqual(Int((progress.fractionCompleted * 100).rounded()), 13)
        XCTAssertEqual(
            AppModel.analysisStatusLine(batch: nil, progress: progress),
            "Analyzing · Stems 50%"
        )
    }

    /// Engine phase rawValues ("separating", "loadingModel", "writingOutputs") are never shown.
    func testAnalysisStatusLineNamesStagesNotEnginePhases() {
        func line(_ stage: SongAnalysisStage) -> String {
            AppModel.analysisStatusLine(
                batch: nil,
                progress: SongAnalysisPipelineProgress(
                    stage: stage,
                    completedStages: 0,
                    totalStages: 4,
                    stageFraction: 1,
                    message: stage.rawValue
                )
            )
        }
        XCTAssertEqual(line(.separation), "Analyzing · Stems 100%")
        XCTAssertEqual(line(.transcription), "Analyzing · Lyrics 100%")
        XCTAssertEqual(line(.harmony), "Analyzing · Tempo & Chords 100%")
        XCTAssertEqual(line(.chordPro), "Analyzing · ChordPro 100%")
    }

    /// The queue also backs first-time imports, so a lone song is not "re-analyzed"; and a
    /// stage-less progress (preflight) falls back to its own message.
    func testAnalysisStatusLineHandlesSingleSongAndStagelessProgress() {
        XCTAssertEqual(
            AppModel.analysisStatusLine(
                batch: AppModel.ReanalyzeAllStatus(index: 1, total: 1, title: "Doc Holiday"),
                progress: SongAnalysisPipelineProgress(
                    stage: nil,
                    completedStages: 0,
                    totalStages: 4,
                    stageFraction: 0,
                    message: "Checking source file"
                )
            ),
            "Analyzing · Checking source file · Doc Holiday"
        )
        XCTAssertEqual(
            AppModel.analysisStatusLine(batch: nil, progress: nil),
            "Analyzing"
        )
    }

    func testWaveformStemProgressMapsEnginePhasesToUserFacingMessages() {
        let selectedID = URL(fileURLWithPath: "/tmp/selected.wav")
        func status(_ message: String, fraction: Double = 0.5) -> AppModel.WaveformStemProgress? {
            AppModel.waveformStemProgress(
                selectedSongID: selectedID,
                currentAnalyzedSongID: selectedID,
                isRunning: true,
                progress: SongAnalysisPipelineProgress(
                    stage: .separation,
                    completedStages: 0,
                    totalStages: 4,
                    stageFraction: fraction,
                    message: message
                )
            )
        }

        XCTAssertEqual(
            status(StemSeparationProgress.Phase.preparingAudio.rawValue)?.message,
            "Preparing stems"
        )
        XCTAssertEqual(
            status(StemSeparationProgress.Phase.loadingModel.rawValue)?.message,
            "Preparing stems"
        )
        XCTAssertEqual(
            status(StemSeparationProgress.Phase.separating.rawValue)?.message,
            "Generating stems"
        )
        XCTAssertEqual(
            status(StemSeparationProgress.Phase.refining.rawValue)?.message,
            "Refining stems"
        )
        XCTAssertEqual(
            status(StemSeparationProgress.Phase.writingOutputs.rawValue)?.message,
            "Finalizing stems"
        )
        XCTAssertEqual(status("loadedFromCache")?.message, "Loading saved stems")
        XCTAssertEqual(status("unexpected")?.message, "Preparing stems")
        XCTAssertEqual(
            status(StemSeparationProgress.Phase.separating.rawValue, fraction: 1.4)?
                .fractionCompleted,
            1
        )
        XCTAssertEqual(
            status(StemSeparationProgress.Phase.separating.rawValue, fraction: -0.2)?
                .fractionCompleted,
            0
        )
    }

    func testWaveformStemProgressShowsSelectedQueuedAndBackgroundAnalysis() {
        let selectedID = URL(fileURLWithPath: "/tmp/selected.wav")
        let otherID = URL(fileURLWithPath: "/tmp/other.wav")
        let separation = SongAnalysisPipelineProgress(
            stage: .separation,
            completedStages: 0,
            totalStages: 4,
            stageFraction: 0.25,
            message: StemSeparationProgress.Phase.separating.rawValue
        )
        let lyrics = SongAnalysisPipelineProgress(
            stage: .transcription,
            completedStages: 1,
            totalStages: 4,
            stageFraction: 0.25,
            message: "transcribing"
        )

        XCTAssertNotNil(
            AppModel.waveformStemProgress(
                selectedSongID: selectedID,
                currentAnalyzedSongID: selectedID,
                isRunning: true,
                progress: separation
            )
        )
        XCTAssertEqual(
            AppModel.waveformStemProgress(
                selectedSongID: selectedID,
                currentAnalyzedSongID: otherID,
                selectedSongIsQueued: true,
                isRunning: true,
                progress: separation,
                batch: AppModel.ReanalyzeAllStatus(index: 2, total: 4, title: "Other Song")
            ),
            AppModel.WaveformStemProgress(
                message: "Waiting to analyze this song",
                fractionCompleted: 0,
                isIndeterminate: true
            )
        )
        XCTAssertNil(
            AppModel.waveformStemProgress(
                selectedSongID: selectedID,
                currentAnalyzedSongID: selectedID,
                isRunning: false,
                progress: separation
            )
        )
        XCTAssertEqual(
            AppModel.waveformStemProgress(
                selectedSongID: selectedID,
                currentAnalyzedSongID: selectedID,
                isRunning: true,
                progress: lyrics
            ),
            AppModel.WaveformStemProgress(
                message: "Analyzing Lyrics",
                fractionCompleted: 0.3125
            )
        )
        XCTAssertEqual(
            AppModel.waveformStemProgress(
                selectedSongID: selectedID,
                currentAnalyzedSongID: otherID,
                isRunning: true,
                progress: lyrics,
                batch: AppModel.ReanalyzeAllStatus(index: 2, total: 4, title: "Other Song")
            ),
            AppModel.WaveformStemProgress(
                message: "Analyzing in background · Other Song",
                fractionCompleted: 0.3125
            )
        )
    }

    /// An idle model shows nothing at all — the status row falls back to "Ready".
    func testBackgroundActivityStatusIsNilWhenIdle() async throws {
        let model = AppModel(store: DelayedProjectStore(document: ProjectLibraryDocument()))
        await model.restoreProjects()
        XCTAssertNil(model.backgroundActivityStatus)
    }

    /// The estimate is what makes the analysis options' cost visible before you press Analyze,
    /// so each switch must move it the way the measurements say — and it must scale with the
    /// song, not quote one 3:36 measurement forever.
    func testAnalysisEstimateReflectsTheOptionsAndTheSongLength() {
        func estimate(
            _ duration: TimeInterval,
            vocals: Bool = true,
            drums: Bool = true,
            lowMemory: Bool = false
        ) -> TimeInterval {
            AppModel.estimatedAnalysisSeconds(
                forDuration: duration,
                vocalVoiceSeparation: vocals,
                drumPieceSeparation: drums,
                lowMemorySeparation: lowMemory)
        }

        // The ONNX fallback: 58 + 73 + 172 + 100 s of work.
        XCTAssertEqual(estimate(216), 403, accuracy: 1)
        // Dropping the vocal refiner is the big lever — it must remove its whole 172 s.
        XCTAssertEqual(estimate(216, vocals: false), 231, accuracy: 1)
        XCTAssertLessThan(estimate(216, vocals: false), estimate(216) * 0.7)
        // Drum pieces add on top of whatever else is on.
        XCTAssertGreaterThan(
            estimate(216, vocals: false), estimate(216, vocals: false, drums: false))
        // Low-memory separation only slows the base pass, so it is the smallest of the three.
        let lowMemoryDelta = estimate(216, lowMemory: true) - estimate(216)
        XCTAssertEqual(lowMemoryDelta, 58 * 0.6, accuracy: 1)
        // Everything scales linearly with the song.
        XCTAssertEqual(estimate(432), estimate(216) * 2, accuracy: 0.001)

        XCTAssertEqual(AppModel.formattedAnalysisDuration(45), "45 s")
        XCTAssertEqual(AppModel.formattedAnalysisDuration(403), "7 min")

        // The native Core ML base model measured 37 s on the same song. It does not implement
        // ONNX's low-memory segment option, so that switch cannot inflate the native estimate.
        let native = AppModel.estimatedAnalysisSeconds(
            forDuration: 216,
            vocalVoiceSeparation: true,
            drumPieceSeparation: true,
            lowMemorySeparation: true,
            nativeCoreMLSeparation: true)
        XCTAssertEqual(native, 382, accuracy: 1)
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
