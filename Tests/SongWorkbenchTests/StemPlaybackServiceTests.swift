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
        try service.load(try makeStemFiles(in: directory), mixer: StemMixerModel())
        service.play()
        try await Task.sleep(for: .milliseconds(180))
        service.pause()

        XCTAssertGreaterThan(service.currentTime, 0.05)
        XCTAssertLessThan(service.currentTime, service.duration)
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
            try makeStemFiles(in: directory, sampleValue: 0.4), mixer: StemMixerModel())
        service.play()
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertGreaterThan(service.stemLevels[StemKind.vocals.id] ?? 0, 0.05)

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
            try makeStemFiles(in: directory, sampleValue: 0.4), mixer: StemMixerModel())
        service.play()
        try await Task.sleep(for: .milliseconds(180))
        let fullLevel = service.stemLevels[StemKind.vocals.id] ?? 0
        XCTAssertGreaterThan(fullLevel, 0.05)

        // Pulling the master fader down must attenuate the metered level too — the meters
        // read straight from the source file (not an engine tap), so they need the master
        // gain applied explicitly to stay honest about what's actually audible.
        var halved = StemMixerModel()
        halved.setMasterGain(0.5)
        service.apply(halved)
        try await Task.sleep(for: .milliseconds(180))
        let halvedLevel = service.stemLevels[StemKind.vocals.id] ?? 0
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

    func testBeatClickTimesUseDetectedBeatsVerbatimWhenMetronomeIsOff() {
        let source = StemPlaybackService.BeatClickSource(
            beatTimes: jitteredBeats.reversed(), bpm: 120, barGrid: downbeatAtIndexOne)

        XCTAssertEqual(
            StemPlaybackService.beatClickTimes(for: source, metronome: false, duration: 6),
            jitteredBeats)
        XCTAssertEqual(
            StemPlaybackService.beatClickTimes(for: source, metronome: true, duration: 6),
            MetronomeGrid.clickTimes(
                beatTimes: jitteredBeats, bpm: 120, barGrid: downbeatAtIndexOne, duration: 6))
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

    func testMetronomeToggleRebuildsClickAndPersists() throws {
        let key = StemPlaybackService.metronomeDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)

        let service = StemPlaybackService()
        XCTAssertTrue(service.metronomeEnabled)
        service.loadClickTrack(beatTimes: jitteredBeats, bpm: 120, barGrid: downbeatAtIndexOne)
        XCTAssertEqual(
            service.beatClickSource,
            .init(beatTimes: jitteredBeats, bpm: 120, barGrid: downbeatAtIndexOne))

        service.metronomeEnabled = false
        XCTAssertEqual(UserDefaults.standard.bool(forKey: key), false)
        // The source survives the toggle — that is what lets the toggle rebuild by itself.
        XCTAssertNotNil(service.beatClickSource)
        service.unload()
        XCTAssertNil(service.beatClickSource)
    }

    private func makeStemFiles(in directory: URL, sampleValue: Float = 0) throws -> StemFiles {
        var urls: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let url = directory.appendingPathComponent("\(kind.rawValue).wav")
            try writeWAV(to: url, sampleValue: sampleValue)
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

    private func writeWAV(to url: URL, sampleValue: Float) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = sampleValue
            }
        }
        try file.write(from: buffer)
    }
}
