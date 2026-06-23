import AVFoundation
import XCTest

@testable import SongWorkbench

final class PracticeWorkspaceTests: XCTestCase {
    func testProjectSchemaVersionIncludesAnalysisProvenance() {
        XCTAssertEqual(ProjectLibraryDocument.currentVersion, 3)
    }

    func testLoopRegionClampsAndRejectsTinyRanges() {
        XCTAssertEqual(
            LoopRegion(start: -2, end: 20).clamped(to: 10),
            LoopRegion(start: 0, end: 10)
        )
        XCTAssertNil(LoopRegion(start: 4, end: 4.05).clamped(to: 10))
    }

    func testPracticeSettingsNormalizeSupportedRanges() {
        var settings = PracticeSettings(pitchSemitones: 40, tempoRate: 0.1)
        settings.normalize()
        XCTAssertEqual(settings.pitchSemitones, 12)
        XCTAssertEqual(settings.tempoRate, 0.5)
    }

    func testJSONProjectStoreRoundTripsDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONProjectStore(fileURL: directory.appendingPathComponent("projects.json"))
        let source = directory.appendingPathComponent("song.wav")
        let document = ProjectLibraryDocument(songs: [
            StoredSongProject(
                url: source,
                settings: PracticeSettings(
                    pitchSemitones: 3,
                    tempoRate: 0.9,
                    loopRegion: LoopRegion(start: 2, end: 8)
                )
            )
        ])

        try await store.save(document)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.version, ProjectLibraryDocument.currentVersion)
        XCTAssertEqual(loaded.songs.first?.sourcePath, source.path)
        XCTAssertEqual(loaded.songs.first?.settings, document.songs.first?.settings)
    }

    func testVersionOneProjectDocumentMigratesToCurrentVersion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("projects.json")
        let json = #"{"version":1,"songs":[]}"#
        try Data(json.utf8).write(to: url)

        let document = try await JSONProjectStore(fileURL: url).load()

        XCTAssertEqual(document.version, ProjectLibraryDocument.currentVersion)
    }

    func testStoredStemFilesRetainFallbackPaths() {
        let root = URL(fileURLWithPath: "/tmp/stems")
        let original = StemFiles(
            vocals: root.appendingPathComponent("vocals.wav"),
            drums: root.appendingPathComponent("drums.wav"),
            bass: root.appendingPathComponent("bass.wav"),
            other: root.appendingPathComponent("other.wav")
        )

        XCTAssertEqual(StoredStemFiles(files: original).resolved(), original)
    }

    func testCancelledOfflineExportPreservesExistingDestination() async throws {
        let source = try makeSineWAV(duration: 2)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: destination)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let task = Task {
            try await OfflineAudioExporter().export(
                sourceURL: source,
                destinationURL: destination,
                settings: OfflineExportSettings(pitchSemitones: 0, tempoRate: 0.5)
            )
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        }
    }

    func testWaveformAnalyzerReturnsBoundedPeaksAndDuration() async throws {
        let url = try makeSineWAV(duration: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }

        let envelope = try await WaveformAnalyzer().analyze(url: url, targetSampleCount: 64)

        XCTAssertEqual(envelope.peaks.count, 64)
        XCTAssertEqual(envelope.duration, 0.25, accuracy: 0.001)
        XCTAssertGreaterThan(envelope.peaks.max() ?? 0, 0.4)
        XCTAssertLessThanOrEqual(envelope.peaks.max() ?? 0, 0.51)
    }

    func testOfflineExporterProducesReadableAudio() async throws {
        let source = try makeSineWAV(duration: 0.25)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try await OfflineAudioExporter().export(
            sourceURL: source,
            destinationURL: destination,
            settings: OfflineExportSettings(pitchSemitones: 2, tempoRate: 1)
        )

        let output = try AVAudioFile(forReading: destination)
        XCTAssertGreaterThan(output.length, 0)
        XCTAssertEqual(
            Double(output.length) / output.processingFormat.sampleRate,
            0.25,
            accuracy: 0.03
        )
    }

    private func makeSineWAV(
        duration: TimeInterval,
        sampleRate: Double = 44_100
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        let angularFrequency = 2.0 * Double.pi * 440.0 / sampleRate
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(0.5 * sin(angularFrequency * Double(frame)))
        }
        try file?.write(from: buffer)
        file = nil
        return url
    }
}
