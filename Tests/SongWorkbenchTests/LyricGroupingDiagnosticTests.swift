import XCTest

@testable import SongWorkbench

/// Regression + diagnostic for line GROUPING, driven by the app's REAL cached transcriptions.
///
/// `LyricRetimingDiagnosticTests` starts from the already-grouped lines in the song document and
/// therefore cannot observe a grouping defect at all. This starts from the raw cached
/// `TranscriptionResult`, which is the actual input to `TimedLyricSegmentGrouper.group`.
///
/// The dump is manual:
///
///     SW_LYRIC_GROUP_DIAG=1 swift test --filter LyricGroupingDiagnosticTests
final class LyricGroupingDiagnosticTests: XCTestCase {
    private struct CacheFile: Decodable {
        struct Key: Decodable {
            struct Engine: Decodable {
                let identifier: String
                let version: String
            }
            let sourceSHA256: String
            let engine: Engine
        }
        struct Value: Decodable {
            let segments: [TimedTranscriptionSegment]
            let sourceDuration: TimeInterval
        }
        let key: Key
        let value: Value
    }

    private var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/Caches/SongWorkbench/Analysis"
            )
    }

    /// Whisper's segmentation is what produced the shipping lyrics; `opening-rescue` is the decode
    /// pass whose result production actually kept (it recovers the post-intro opening — see
    /// tasks/lessons.md, 2026-07-28). Scoring the non-rescue pass measures a transcript the app
    /// discarded.
    private func loadTranscriptionCaches() throws -> [CacheFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        return
            urls
            .compactMap { try? decoder.decode(CacheFile.self, from: Data(contentsOf: $0)) }
            .filter { $0.key.engine.identifier.hasPrefix("transcription") }
            .filter { $0.key.engine.identifier.contains("whisper.cpp") }
            .filter { $0.key.engine.version.contains("opening-rescue") }
            .sorted { $0.value.sourceDuration < $1.value.sourceDuration }
    }

    private func lines(_ cache: CacheFile) -> [TimedLyricSegment] {
        TimedLyricSegmentGrouper.group(
            tokens: cache.value.segments.flatMap(\.tokens),
            lineStartOnsets: TimedLyricSegmentGrouper.lineStartOnsets(of: cache.value.segments)
        )
    }

    /// FIELD-DATA REGRESSION for the overlapping-segment merge defect (2026-07-31).
    ///
    /// Doc Holiday's cached Whisper transcription splits the opening couplet into two segments
    /// whose spans OVERLAP — "He walks in" 27.563-30.483, then "Whiskey in trouble, ..."
    /// 30.000-36.620. The negative gap made `mergedConjunctionContinuations`' `gap <= 1.0` guard
    /// vacuously true, so a line ending on "in" was welded to the next segment and the boundary
    /// the engine itself reported was lost.
    ///
    /// Skips (does not fail) when the cache is absent, so this is inert on a machine without the
    /// app's container.
    func testOverlappingSegmentBoundarySurvivesGrouping() throws {
        let caches = (try? loadTranscriptionCaches()) ?? []
        let docHoliday = try XCTUnwrap(
            caches.first { abs($0.value.sourceDuration - 298.9695625) < 0.01 },
            "Doc Holiday's cached Whisper transcription not found")

        let onsets = TimedLyricSegmentGrouper.lineStartOnsets(of: docHoliday.value.segments)
        XCTAssertTrue(
            onsets.contains { abs($0 - 30.0) < 0.01 },
            "precondition: the engine reported a segment onset at 30.000 ('Whiskey')")

        let texts = lines(docHoliday).map(\.text)
        XCTAssertFalse(
            texts.contains { $0.hasPrefix("He walks in Whiskey") },
            "the overlapping segment boundary was merged away: "
                + texts.prefix(6).joined(separator: " | "))
        XCTAssertTrue(texts.contains("He walks in"), texts.prefix(6).joined(separator: " | "))
        XCTAssertTrue(
            texts.contains { $0.hasPrefix("Whiskey in trouble") },
            texts.prefix(6).joined(separator: " | "))
    }

    /// Manual: dump grouped lines for every cached song, to eyeball a grouping change's blast
    /// radius beyond the one song under test.
    func testDumpGroupedLines() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SW_LYRIC_GROUP_DIAG"] == "1",
            "manual diagnostic; set SW_LYRIC_GROUP_DIAG=1")
        for cache in try loadTranscriptionCaches() {
            let grouped = lines(cache)
            print(
                "\n---- \(cache.key.sourceSHA256.prefix(8)) "
                    + "dur=\(String(format: "%.1f", cache.value.sourceDuration)) "
                    + "lines=\(grouped.count) ----")
            for line in grouped {
                print(String(format: "  %7.3f-%7.3f  %@", line.start, line.end, line.text))
            }
        }
    }
}
