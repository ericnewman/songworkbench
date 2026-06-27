import AVFoundation
import XCTest

@testable import SongWorkbench

@MainActor
final class LiveCaptureTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// A C-major triad (C-E-G), the kind of harmonic content the chord path expects.
    private func triad(count: Int = 4_410) -> CaptureBuffer {
        let freqs = [261.63, 329.63, 392.0]  // C4, E4, G4
        let samples = (0..<count).map { index -> Float in
            let t = Double(index) / sampleRate
            let value = freqs.reduce(0.0) { $0 + sin(2 * Double.pi * $1 * t) }
            return Float(value / Double(freqs.count)) * 0.6
        }
        return CaptureBuffer(samples: samples, sampleRate: sampleRate)
    }

    private func silence(count: Int = 4_410) -> CaptureBuffer {
        CaptureBuffer(samples: Array(repeating: 0, count: count), sampleRate: sampleRate)
    }

    // (a) A tone stream yields chord events through the incremental analyzer.
    func testToneStreamYieldsChordEvents() {
        let analyzer = LiveHarmonyAnalyzer()
        // ~1.2 s of audio so several frames (8192/4096) accrue.
        for _ in 0..<12 { analyzer.append(triad()) }
        let fresh = analyzer.drainNewObservations()
        XCTAssertFalse(fresh.isEmpty, "frames should classify into observations")
        XCTAssertTrue(analyzer.sawLiveSignal)

        let analysis = analyzer.finish()
        let events = ChordEventReducer().events(from: analysis)
        XCTAssertFalse(events.isEmpty, "a sustained tone should reduce to at least one chord")
    }

    // Incremental framing only consumes newly-complete frames each drain (no double-counting).
    func testDrainIsIncremental() {
        let analyzer = LiveHarmonyAnalyzer()
        analyzer.append(triad(count: 8_192 + 4_096))  // exactly 2 frames available
        let first = analyzer.drainNewObservations()
        XCTAssertEqual(first.count, 2)
        let second = analyzer.drainNewObservations()
        XCTAssertTrue(second.isEmpty, "no new frames since last drain")
        analyzer.append(triad(count: 4_096))  // one more hop -> one more frame
        XCTAssertEqual(analyzer.drainNewObservations().count, 1)
    }

    // (b) Silence yields the muted outcome and NO chart.
    func testSilentStreamReportsMutedAndNoChart() {
        let synthetic = SyntheticCaptureSource(kind: .loopbackDevice)
        let session = LiveCaptureSession(makeSource: { _ in synthetic })
        session.start()
        for _ in 0..<40 { synthetic.feed(silence()) }  // 4 s of digital silence
        session.tick()

        XCTAssertEqual(session.signalState, .silent)
        XCTAssertTrue(session.liveChords.isEmpty)

        let outcome = session.stop()
        XCTAssertEqual(outcome, .muted)
        XCTAssertEqual(session.phase, .muted)
        XCTAssertFalse(LiveCaptureSession.mutedMessage.isEmpty)
    }

    // (d) Source selection + start/stop lifecycle produces a chart from live signal.
    func testStartStopLifecycleProducesChart() {
        let synthetic = SyntheticCaptureSource(kind: .loopbackDevice)
        let session = LiveCaptureSession(makeSource: { _ in synthetic })
        XCTAssertEqual(session.phase, .idle)

        session.start()
        XCTAssertEqual(session.phase, .capturing)
        XCTAssertTrue(synthetic.feed(triad()), "source delivers while started")
        for _ in 0..<12 { synthetic.feed(triad()) }
        session.tick()
        XCTAssertEqual(session.signalState, .live)
        XCTAssertFalse(session.liveChords.isEmpty)

        let outcome = session.stop()
        guard case .chart = outcome else {
            return XCTFail("expected a chart, got \(outcome)")
        }
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertFalse(synthetic.feed(triad()), "source stops delivering after stop")
    }

    // (c) The derived chart round-trips through ProjectStore as liveCapture / draft, with no
    // audio reference ever created.
    func testLiveChartRoundTripsAsLiveCaptureDraft() async throws {
        let url = try writeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MemoryProjectStore()
        let model = AppModel(store: store)
        await model.restoreProjects()
        model.importSongs(from: [url])
        try await Task.sleep(for: .milliseconds(50))
        let song = try XCTUnwrap(model.songs.first)
        model.select(song)

        let observations = (0..<20).map { index in
            ChordObservation(
                timestamp: Double(index) * 0.1,
                chord: Chord(root: .c, quality: .major),
                confidence: 0.9
            )
        }
        let analysis = SongAudioAnalysis(beat: nil, chords: observations)
        XCTAssertTrue(model.applyLiveCaptureChart(analysis))

        XCTAssertFalse(model.chordEvents.isEmpty)
        XCTAssertEqual(model.chordReviewState, .draft)
        XCTAssertEqual(
            model.analysisStageRecords[.harmony]?.provenance?.sourceKind, .liveCapture)

        await model.saveProjects()
        let lastSaved = await store.last
        let saved = try XCTUnwrap(lastSaved)
        let storedSong = try XCTUnwrap(
            saved.songs.first { Song(url: $0.resolvedURL()).id == song.id })
        let document = try XCTUnwrap(storedSong.analysis)
        XCTAssertFalse(document.chords.isEmpty)
        XCTAssertEqual(document.chordReviewState, .draft)
        let provenance = try XCTUnwrap(document.stageRecords[.harmony]?.provenance)
        XCTAssertEqual(provenance.sourceKind, .liveCapture)
        XCTAssertFalse(provenance.loadedFromCache)
        XCTAssertNil(document.stems, "live capture must never create an audio reference")
    }

    private func writeSilentWAV(frameCount: AVAudioFrameCount = 800) throws -> URL {
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

private actor MemoryProjectStore: ProjectStore {
    private(set) var saved: [ProjectLibraryDocument] = []

    func load() async throws -> ProjectLibraryDocument { ProjectLibraryDocument() }
    func save(_ document: ProjectLibraryDocument) async throws { saved.append(document) }
    nonisolated func saveBlocking(_ document: ProjectLibraryDocument) throws {}
    var last: ProjectLibraryDocument? { saved.last }
}
