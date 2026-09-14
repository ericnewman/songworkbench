import AVFoundation
import XCTest

@testable import SongWorkbench

@MainActor
final class StemPlaybackServiceTests: XCTestCase {
    func testLoadPublishesDurationAndSupportsSeekPitchAndTempo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StemPlaybackService()
        try service.load(try makeStemFiles(in: directory), mixer: StemMixerModel())
        service.seek(to: 0.5)
        service.setPitch(semitones: 3)
        service.setTempo(rate: 0.8)

        XCTAssertEqual(service.duration, 1, accuracy: 0.01)
        XCTAssertEqual(service.currentTime, 0.5, accuracy: 0.01)
        XCTAssertEqual(service.pitchSemitones, 3)
        XCTAssertEqual(service.tempoRate, 0.8, accuracy: 0.001)
    }

    func testPlaybackPublishesProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StemPlaybackService()
        try service.load(
            try makeStemFiles(in: directory, seconds: liveFixtureSeconds), mixer: StemMixerModel())
        let started = Date()
        service.play()
        let progressed = await waitUntil { service.currentTime > 0.05 }
        service.pause()
        let wallClock = Date().timeIntervalSince(started)

        XCTAssertTrue(progressed, "playhead never advanced")
        XCTAssertGreaterThan(service.currentTime, 0.05)
        XCTAssertLessThan(service.currentTime, service.duration)
        // The playhead follows rendered audio, so it cannot run ahead of real time by more than
        // an output buffer.
        XCTAssertLessThan(service.currentTime, wallClock + 0.25)
    }

    func testMeterLevelUsesRootMeanSquareAcrossChannels() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for channel in 0..<2 {
            for frame in 0..<4 {
                buffer.floatChannelData![channel][frame] = 0.5
            }
        }

        XCTAssertEqual(StemPlaybackService.meterLevel(from: buffer), 0.5, accuracy: 0.001)
    }

    func testPlaybackPublishesStemLevelsAndResetsOnPause() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StemPlaybackService()
        try service.load(
            try makeStemFiles(in: directory, sampleValue: 0.4, seconds: liveFixtureSeconds),
            mixer: StemMixerModel())
        service.play()
        let metered = await waitUntil {
            (service.stemLevels[StemKind.vocals.id] ?? 0) > 0.05
                && (service.stemLevels[StemKind.drums.id] ?? 0) > 0.05
        }

        XCTAssertTrue(metered, "stem meters never rose above 0.05")
        XCTAssertTrue(service.isPlaying)

        service.pause()

        XCTAssertEqual(service.stemLevels[StemKind.vocals.id] ?? 1, 0)
        XCTAssertEqual(service.stemLevels[StemKind.drums.id] ?? 1, 0)
    }

    func testMasterGainAttenuatesMeteredStemLevels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = StemPlaybackService()
        try service.load(
            try makeStemFiles(in: directory, sampleValue: 0.4, seconds: liveFixtureSeconds),
            mixer: StemMixerModel())
        service.play()
        _ = await waitUntil { (service.stemLevels[StemKind.vocals.id] ?? 0) > 0.05 }
        let fullLevel = service.stemLevels[StemKind.vocals.id] ?? 0
        XCTAssertGreaterThan(fullLevel, 0.05)

        // Pulling the master fader down must attenuate the metered level too — the meters
        // read straight from the source file (not an engine tap), so they need the master
        // gain applied explicitly to stay honest about what's actually audible.
        var halved = StemMixerModel()
        halved.setMasterGain(0.5)
        service.apply(halved)
        // The fixture is a constant signal, so the level only changes when a meter tick reads the
        // new master gain (or playback stops, which `isPlaying` below catches).
        _ = await waitUntil { (service.stemLevels[StemKind.vocals.id] ?? 0) != fullLevel }
        let halvedLevel = service.stemLevels[StemKind.vocals.id] ?? 0
        XCTAssertTrue(service.isPlaying)
        service.pause()

        XCTAssertEqual(halvedLevel, fullLevel * 0.5, accuracy: 0.05)
    }

    func testFailedReloadClearsPreviouslyLoadedState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validFiles = try makeStemFiles(in: directory)
        let service = StemPlaybackService()
        try service.load(validFiles, mixer: StemMixerModel())
        XCTAssertTrue(service.isLoaded)

        let missingBass = StemFiles(
            vocals: validFiles.vocals,
            drums: validFiles.drums,
            bass: directory.appendingPathComponent("missing.wav"),
            other: validFiles.other
        )
        XCTAssertThrowsError(try service.load(missingBass, mixer: StemMixerModel()))
        XCTAssertFalse(service.isLoaded)
        XCTAssertFalse(service.isPlaying)
    }

    func testClickSampleMemoryDoesNotScaleWithSongDuration() throws {
        let sampleRate = 44_100.0
        let sample = try XCTUnwrap(
            StemPlaybackService.makeClickSample(sampleRate: sampleRate)
        )

        XCTAssertEqual(sample.frameLength, AVAudioFrameCount(sampleRate * 0.03))
        XCTAssertLessThan(sample.frameCapacity, 2_000)
    }

    // MARK: - Beat click: metronome grid vs. detected beats

    /// Drum-snapped beats with ±20 ms jitter around a 120 BPM grid whose beat 0 is a pickup:
    /// beat 1 (the bar grid's first downbeat) is index 1 at 1.0 s.
    private let jitteredBeats: [TimeInterval] = [0.51, 1.0, 1.48, 2.02, 2.49, 3.01, 3.52, 3.98]
    private let downbeatAtIndexOne = SongBarGrid(
        beatsPerBar: 4, barPhase: 1, confidence: 0.5, phaseSource: .drumAccents)

    func testMetronomeGridIsRigidAtBPMAndAnchoredToBarGridDownbeat() {
        let grid = MetronomeGrid.clickTimes(
            beatTimes: jitteredBeats, bpm: 120, barGrid: downbeatAtIndexOne, duration: 6)

        // Period is exactly 60/bpm — none of the input jitter survives.
        for index in 1..<grid.count {
            XCTAssertEqual(grid[index] - grid[index - 1], 0.5, accuracy: 1e-9)
        }
        // Phase: the downbeat beat (index 1 → 1.0 s) is ON the grid, exactly.
        XCTAssertTrue(grid.contains { abs($0 - 1.0) < 1e-9 })
        // Covers the whole song, both directions from the anchor.
        XCTAssertEqual(grid.first!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(grid.last!, 6.0, accuracy: 1e-9)
        XCTAssertEqual(grid.count, 13)
    }

    func testMetronomeGridFallsBackToMedianIntervalWithoutBPM() throws {
        let grid = MetronomeGrid.clickTimes(
            beatTimes: jitteredBeats, bpm: nil, barGrid: downbeatAtIndexOne, duration: 4)

        let intervals = zip(grid.dropFirst(), grid).map { $0 - $1 }
        let period = try XCTUnwrap(intervals.first)
        XCTAssertEqual(period, 0.5, accuracy: 0.03)  // median of the jittered IBIs
        for interval in intervals { XCTAssertEqual(interval, period, accuracy: 1e-9) }
        XCTAssertTrue(grid.contains { abs($0 - 1.0) < 1e-9 })  // still anchored on beat 1
    }

    func testMetronomeGridClampsAnchorIndexAndHandlesDegenerateInput() {
        // barPhase past the end must not crash; it clamps to the last beat.
        let outOfRange = SongBarGrid(
            beatsPerBar: 4, barPhase: 99, confidence: 0, phaseSource: .anchoredToFirstBeat)
        let grid = MetronomeGrid.clickTimes(
            beatTimes: [0.5, 1.0], bpm: 120, barGrid: outOfRange, duration: 2)
        XCTAssertTrue(grid.contains { abs($0 - 1.0) < 1e-9 })

        XCTAssertEqual(
            MetronomeGrid.clickTimes(beatTimes: [], bpm: 120, barGrid: nil, duration: 2),
            [])
        // One beat and no tempo: nothing to fit, so that beat is the whole grid.
        XCTAssertEqual(
            MetronomeGrid.clickTimes(
                beatTimes: [0.7], bpm: nil, barGrid: nil, duration: 2),
            [0.7])
    }

    func testPeriodicGridDoesNotDriftOverALongSong() {
        // 4 minutes at 127 BPM: index arithmetic keeps the last beat on the exact multiple.
        let period = 60.0 / 127
        let grid = MetronomeGrid.periodicGrid(period: period, anchor: 0.3, duration: 240)
        let lastIndex = Double(grid.count - 1)
        XCTAssertEqual(grid.last!, grid.first! + lastIndex * period, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(grid.first!, 0)
        XCTAssertLessThanOrEqual(grid.last!, 240)
    }

    func testBeatClickIsAlwaysTheMetronomeGrid() throws {
        // The detected-beat click is gone: whatever beats go in, the grid comes out. Jittered
        // input is the discriminator — verbatim beats would reproduce the jitter, the metronome
        // replaces it with one rigid period.
        let grid = MetronomeGrid.clickTimes(
            beatTimes: jitteredBeats, bpm: 120, barGrid: downbeatAtIndexOne, duration: 6)
        XCTAssertNotEqual(grid, jitteredBeats)
        let intervals = zip(grid, grid.dropFirst()).map { $1 - $0 }
        for interval in intervals { XCTAssertEqual(interval, 0.5, accuracy: 1e-9) }

        // Sanity: the service accepts the same inputs without an engine loaded (empty click).
        let service = StemPlaybackService()
        service.loadClickTrack(beatTimes: jitteredBeats, bpm: 120, barGrid: downbeatAtIndexOne)
        service.unload()
    }

    /// Live-engine fixtures run far longer than the tests wait. The test host gets late wakeups
    /// (a 180 ms sleep measured up to ~1 s, and a whole test up to 4.5 s), and a 1 s fixture then
    /// finished playing mid-test: `currentTime` snapped to `duration` and the meters reset to 0.
    private let liveFixtureSeconds: TimeInterval = 20

    /// Polls published state instead of sleeping a fixed time, so wall-clock jitter changes how
    /// long a test takes but not what it observes.
    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func makeStemFiles(
        in directory: URL, sampleValue: Float = 0, seconds: TimeInterval = 1
    ) throws -> StemFiles {
        var urls: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let url = directory.appendingPathComponent("\(kind.rawValue).wav")
            try writeWAV(to: url, sampleValue: sampleValue, seconds: seconds)
            urls[kind] = url
        }
        return StemFiles(
            vocals: urls[.vocals]!,
            drums: urls[.drums]!,
            bass: urls[.bass]!,
            guitar: urls[.guitar]!,
            piano: urls[.piano]!,
            other: urls[.other]!
        )
    }

    private func writeWAV(to url: URL, sampleValue: Float, seconds: TimeInterval) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            buffer.floatChannelData![channel].update(repeating: sampleValue, count: Int(frames))
        }
        try file.write(from: buffer)
    }
}
