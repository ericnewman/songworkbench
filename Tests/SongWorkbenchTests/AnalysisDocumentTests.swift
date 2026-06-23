import Foundation
import XCTest

@testable import SongWorkbench

final class AnalysisDocumentTests: XCTestCase {
    func testLegacyDocumentDecodesWithDraftReviewAndNoFabricatedProvenance() throws {
        let json = """
            {
              "lyrics": [{"id":"00000000-0000-0000-0000-000000000001","start":1,"end":3,"text":"Legacy lyric"}],
              "chords": [{"id":"00000000-0000-0000-0000-000000000002","time":1,"chord":"C"}],
              "chordProSource": "{title: Legacy}\\n",
              "estimatedBPM": 100
            }
            """

        let document = try JSONDecoder().decode(
            SongAnalysisDocument.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(document.lyrics.first?.text, "Legacy lyric")
        XCTAssertEqual(document.chords.first?.chord, "C")
        XCTAssertEqual(document.estimatedKey, MusicalKey(root: .c, quality: .major))
        XCTAssertEqual(document.lyricReviewState, .draft)
        XCTAssertEqual(document.chordReviewState, .draft)
        XCTAssertEqual(document.chordProReviewState, .draft)
        XCTAssertEqual(document.chordConfidenceThreshold, 0.5)
        XCTAssertTrue(document.stageRecords.isEmpty)
    }

    func testReviewStateAndProvenanceRoundTrip() throws {
        let completedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let provenance = AnalysisProvenance(
            sourceDigest: "abc123",
            sourceKind: .vocalsStem,
            engineIdentifier: "transcriber",
            engineVersion: "1.2.3",
            modelIdentifier: "model",
            modelVersion: "4",
            configurationIdentifier: "accurate",
            resultSchemaVersion: 2,
            completedAt: completedAt,
            loadedFromCache: false
        )
        let source = SongAnalysisDocument(
            estimatedKey: MusicalKey(root: .e, quality: .minor),
            chordConfidenceThreshold: 0.72,
            lyricReviewState: .reviewed,
            stageRecords: [
                .transcription: AnalysisStageRecord(
                    state: .succeeded,
                    provenance: provenance,
                    confidence: AnalysisConfidenceSummary(
                        average: 0.92,
                        lowConfidenceCount: 1,
                        totalCount: 12
                    ),
                    errorMessage: nil
                )
            ]
        )

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SongAnalysisDocument.self, from: encoded)

        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.stageRecords[.transcription]?.provenance, provenance)
    }
}
