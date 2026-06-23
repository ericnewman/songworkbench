import Foundation
import XCTest

@testable import SongWorkbench

final class FluidAudioTranscriptionEngineTests: XCTestCase {
    func testDraftProfilesMapToDistinctFluidAudioConfigurations() {
        let fast = FluidAudioDraftProfile.fastDraft.asrConfig
        XCTAssertEqual(fast.parallelChunkConcurrency, 1)
        XCTAssertFalse(fast.melChunkContext)

        let balanced = FluidAudioDraftProfile.balancedDraft.asrConfig
        XCTAssertEqual(balanced.parallelChunkConcurrency, 1)
        XCTAssertTrue(balanced.melChunkContext)
    }

    func testInstalledModelTranscribesRepresentativeAudioWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let modelPath = environment["CCS_PARAKEET_MODEL_DIRECTORY"],
            let audioPath = environment["CCS_TRANSCRIPTION_AUDIO"]
        else {
            throw XCTSkip(
                "Set CCS_PARAKEET_MODEL_DIRECTORY and CCS_TRANSCRIPTION_AUDIO for production validation."
            )
        }
        let runtime = FluidAudioRuntime(modelDirectory: URL(fileURLWithPath: modelPath))

        let transcript = try await runtime.transcribe(
            audioURL: URL(fileURLWithPath: audioPath)
        ) { _, _ in }

        XCTAssertGreaterThan(transcript.duration, 0)
        XCTAssertFalse(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(transcript.tokens.isEmpty)
    }

    func testModelLayoutUsesExpectedFluidAudioFolderWithoutStaging() throws {
        let directory = URL(fileURLWithPath: "/models/parakeet-tdt-0.6b-v3")

        let layout = try FluidAudioModelLayout.prepare(modelDirectory: directory)

        XCTAssertEqual(layout.loadDirectory, directory)
        XCTAssertNil(layout.stagingDirectory)
    }

    func testModelLayoutStagesRepositoryFolderUnderFluidAudioFolderName() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let modelDirectory = temporaryDirectory.appendingPathComponent(
            "parakeet-tdt-0.6b-v3-coreml",
            isDirectory: true
        )
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let layout = try FluidAudioModelLayout.prepare(
            modelDirectory: modelDirectory,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )

        XCTAssertEqual(layout.loadDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(
            layout.loadDirectory.resolvingSymlinksInPath().standardizedFileURL,
            modelDirectory.standardizedFileURL
        )
        layout.removeStagingDirectory(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: layout.loadDirectory.path))
    }

    func testEngineNormalizesRuntimeTokensIntoSharedTimedResult() async throws {
        let runtime = StubFluidAudioRuntime(
            transcript: FluidAudioTranscript(
                text: "Hello, world!",
                duration: 2,
                confidence: 0.85,
                tokens: [
                    FluidAudioTranscriptToken(
                        text: "Hello",
                        start: 0,
                        end: 0.7,
                        confidence: 0.9
                    ),
                    FluidAudioTranscriptToken(
                        text: ",",
                        start: 0.7,
                        end: 0.8,
                        confidence: 0.8
                    ),
                    FluidAudioTranscriptToken(
                        text: " world!",
                        start: 0.8,
                        end: 2,
                        confidence: 0.85
                    ),
                ]
            )
        )
        let engine = FluidAudioTranscriptionEngine(
            modelDirectory: URL(fileURLWithPath: "/models/parakeet-tdt-0.6b-v3-coreml"),
            modelSizeBytes: 500_000_000,
            runtime: runtime
        )
        let request = TranscriptionRequest(
            audioURL: URL(fileURLWithPath: "/audio/vocals.wav")
        )

        let result = try await engine.transcribe(request: request) { _ in }

        XCTAssertEqual(result.text, "Hello, world!")
        XCTAssertEqual(result.sourceDuration, 2)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].tokens.map(\.text), ["Hello,", "world!"])
        XCTAssertEqual(result.segments[0].tokens[0].endTime, 0.8)
        XCTAssertEqual(result.segments[0].tokens[1].startTime, 0.8)
        XCTAssertEqual(result.segments[0].confidence, 0.85)
        XCTAssertEqual(result.engine.engineName, "FluidAudio")
        XCTAssertEqual(result.engine.modelVersion, "v3-int8")
        XCTAssertEqual(result.engine.engineVersion, "2")
    }

    func testSentencePieceFragmentsAreCombinedIntoTimedWords() {
        let words = FluidAudioWordTokenGrouper.group([
            FluidAudioTranscriptToken(text: " Tak", start: 1, end: 1.2, confidence: 0.8),
            FluidAudioTranscriptToken(text: "e", start: 1.2, end: 1.4, confidence: 1),
            FluidAudioTranscriptToken(text: " me", start: 1.4, end: 1.7, confidence: 0.9),
            FluidAudioTranscriptToken(text: ".", start: 1.7, end: 1.8, confidence: 0.7),
        ])

        XCTAssertEqual(words.map(\.text), ["Take", "me."])
        XCTAssertEqual(words[0].start, 1)
        XCTAssertEqual(words[0].end, 1.4)
        XCTAssertEqual(words[0].confidence, 0.9, accuracy: 0.001)
        XCTAssertEqual(words[1].start, 1.4)
        XCTAssertEqual(words[1].end, 1.8)
    }
}

private struct StubFluidAudioRuntime: FluidAudioTranscribing {
    let transcript: FluidAudioTranscript

    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FluidAudioTranscript {
        progress(1, "complete")
        return transcript
    }
}
