import Foundation
import XCTest

@testable import SongWorkbench

final class WhisperCPPTranscriptionEngineTests: XCTestCase {
    func testInstalledModelTranscribesRepresentativeAudioWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let modelPath = environment["CCS_WHISPER_MODEL"],
            let audioPath = environment["CCS_TRANSCRIPTION_AUDIO"]
        else {
            throw XCTSkip(
                "Set CCS_WHISPER_MODEL and CCS_TRANSCRIPTION_AUDIO for production validation."
            )
        }
        let modelURL = URL(fileURLWithPath: modelPath)
        let modelSize = try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let engine = WhisperCPPTranscriptionEngine(
            modelURL: modelURL,
            modelSizeBytes: UInt64(modelSize),
            useGPU: false
        )

        let result = try await engine.transcribe(
            request: TranscriptionRequest(audioURL: URL(fileURLWithPath: audioPath))
        ) { _ in }

        XCTAssertGreaterThan(result.sourceDuration, 0)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertFalse(result.text.contains("[_BEG_]"))
        XCTAssertFalse(result.text.contains("[_TT_]"))
    }

    func testSpecialAndTimestampTokenIDsAreExcluded() {
        XCTAssertTrue(WhisperCPPTokenFilter.isText(tokenID: 100, endOfTextTokenID: 50_000))
        XCTAssertFalse(WhisperCPPTokenFilter.isText(tokenID: 50_000, endOfTextTokenID: 50_000))
        XCTAssertFalse(WhisperCPPTokenFilter.isText(tokenID: 50_100, endOfTextTokenID: 50_000))
    }

    func testRapidFourthPhraseRepetitionIsRemoved() {
        let phrase = [" Oh", " take", " me", " where", " we", " belong"]
        let tokens = (0..<5).flatMap { repetition in
            phrase.enumerated().map { offset, text in
                let start = Double(repetition * phrase.count + offset)
                return WhisperCPPTranscriptToken(
                    text: text,
                    start: start,
                    end: start + 0.5,
                    confidence: 0.8
                )
            }
        }
        let source = WhisperCPPTranscript(
            text: tokens.map(\.text).joined(),
            duration: 40,
            languageCode: "en",
            segments: [
                WhisperCPPTranscriptSegment(
                    text: tokens.map(\.text).joined(),
                    start: 0,
                    end: 30,
                    tokens: tokens
                )
            ]
        )

        let filtered = WhisperCPPRepetitionFilter.filter(source)

        XCTAssertEqual(filtered.segments.flatMap(\.tokens).count, phrase.count * 3)
        XCTAssertEqual(filtered.text, phrase.joined() + phrase.joined() + phrase.joined())
    }

    func testAccuracyEngineUsesNoContextAndNormalizesTimedTokens() async throws {
        let runtime = StubWhisperRuntime(
            transcript: WhisperCPPTranscript(
                text: " Sing it again",
                duration: 3,
                languageCode: "en",
                segments: [
                    WhisperCPPTranscriptSegment(
                        text: " Sing it again",
                        start: 0.5,
                        end: 3,
                        tokens: [
                            WhisperCPPTranscriptToken(
                                text: " Sing",
                                start: 0.5,
                                end: 1.2,
                                confidence: 0.91
                            ),
                            WhisperCPPTranscriptToken(
                                text: " it",
                                start: 1.2,
                                end: 1.8,
                                confidence: 0.88
                            ),
                            WhisperCPPTranscriptToken(
                                text: " again",
                                start: 1.8,
                                end: 3,
                                confidence: 0.86
                            ),
                        ]
                    )
                ]
            )
        )
        let engine = WhisperCPPTranscriptionEngine(
            modelURL: URL(fileURLWithPath: "/models/ggml-large-v3-turbo-q5_0.bin"),
            modelSizeBytes: 574_041_195,
            runtime: runtime
        )

        let result = try await engine.transcribe(
            request: TranscriptionRequest(audioURL: URL(fileURLWithPath: "/audio/song.wav"))
        ) { _ in }

        let receivedNoContext = await runtime.receivedNoContext()
        XCTAssertTrue(receivedNoContext)
        XCTAssertEqual(result.text, "Sing it again")
        XCTAssertEqual(result.languageCode, "en")
        XCTAssertEqual(result.segments[0].tokens.map(\.text), ["Sing", "it", "again"])
        XCTAssertEqual(result.segments[0].tokens[0].startTime, 0.5)
        XCTAssertEqual(result.engine.engineName, "whisper.cpp")
    }

    func testAccuracyEngineRejectsOverAggressiveEarlyRepetitionCutoff() async throws {
        let repeatedPhrase = [" Oh", " take", " me", " where", " we", " belong"]
        let repeatedTokens = (0..<5).flatMap { repetition in
            repeatedPhrase.enumerated().map { offset, text in
                let start = Double(repetition * repeatedPhrase.count + offset)
                return WhisperCPPTranscriptToken(
                    text: text,
                    start: start,
                    end: start + 0.5,
                    confidence: 0.82
                )
            }
        }
        let laterTokens = [
            WhisperCPPTranscriptToken(text: " The", start: 150, end: 150.5, confidence: 0.9),
            WhisperCPPTranscriptToken(text: " bridge", start: 150.5, end: 151, confidence: 0.9),
            WhisperCPPTranscriptToken(text: " still", start: 151, end: 151.5, confidence: 0.9),
            WhisperCPPTranscriptToken(text: " matters", start: 151.5, end: 152, confidence: 0.9),
        ]
        let runtime = StubWhisperRuntime(
            transcript: WhisperCPPTranscript(
                text: (repeatedTokens + laterTokens).map(\.text).joined(),
                duration: 180,
                languageCode: "en",
                segments: [
                    WhisperCPPTranscriptSegment(
                        text: repeatedTokens.map(\.text).joined(),
                        start: 0,
                        end: 30,
                        tokens: repeatedTokens
                    ),
                    WhisperCPPTranscriptSegment(
                        text: laterTokens.map(\.text).joined(),
                        start: 150,
                        end: 152,
                        tokens: laterTokens
                    ),
                ]
            )
        )
        let engine = WhisperCPPTranscriptionEngine(
            modelURL: URL(fileURLWithPath: "/models/ggml-large-v3-turbo-q5_0.bin"),
            modelSizeBytes: 574_041_195,
            runtime: runtime
        )

        let result = try await engine.transcribe(
            request: TranscriptionRequest(audioURL: URL(fileURLWithPath: "/audio/song.wav"))
        ) { _ in }

        XCTAssertTrue(result.text.contains("bridge still matters"))
        XCTAssertEqual(result.segments.flatMap(\.tokens).last?.text, "matters")
        XCTAssertEqual(result.engine.engineVersion, "3")
    }
}

private actor StubWhisperRuntime: WhisperCPPTranscribing {
    let transcript: WhisperCPPTranscript
    private var noContext = false

    init(transcript: WhisperCPPTranscript) {
        self.transcript = transcript
    }

    func transcribe(
        audioURL: URL,
        noContext: Bool,
        cancellation: WhisperCPPCancellationToken
    ) async throws -> WhisperCPPTranscript {
        self.noContext = noContext
        return transcript
    }

    func receivedNoContext() -> Bool {
        noContext
    }
}
