import XCTest

@testable import SongWorkbench

/// MANUAL diagnostic: replays the REAL `AppModel.applyAnalysis` lyric pipeline over the app's own
/// cached song documents and prints the before/after phrase-period numbers per song, so the
/// re-cut can be verified on real data rather than on synthetic uniform input (which is exactly
/// what hid an earlier idempotency defect — tasks/lessons.md).
///
///     SW_RECUT_DIAG=1 swift test --filter PhrasePeriodLineRecutterDiagnosticTests
///
/// `SW_RECUT_UNGATED=1` additionally reports what the pass WOULD have done on songs the accept
/// gate rejected.
final class PhrasePeriodLineRecutterDiagnosticTests: XCTestCase {

    /// `RhymeDetector.shared` reads its table from `Bundle.main`, which under `swift test` is the
    /// test runner — so it loads EMPTY and every rhyme lookup returns nil, silently disabling the
    /// rhyme licence. Load the real dictionary from the repo instead, or this diagnostic measures
    /// the rhyme path as a no-op and reports no change.
    private func repoRhymeDetector() throws -> RhymeDetector {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.pathComponents.count > 1 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/cmudict_rhyme.tsv")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let text = try String(contentsOf: candidate, encoding: .utf8)
                return RhymeDetector(table: RhymeDetector.parseTable(text))
            }
        }
        throw XCTSkip("cmudict_rhyme.tsv not found next to the sources")
    }
    private struct SongDocument: Decodable {
        struct Analysis: Decodable {
            var lyrics: [TimedLyricSegment]?
            var beatTimes: [TimeInterval]?
            var estimatedBPM: Double?
            var chords: [EditableChordEvent]?
        }
        var sourcePath: String?
        var analysis: Analysis?
    }

    private var songsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/"
                    + "Application Support/SongWorkbench/songs")
    }

    /// The exact prefix of `applyAnalysis` that produces the lines this pass consumes.
    private func pipelineInput(_ analysis: SongDocument.Analysis) -> (
        lines: [TimedLyricSegment], beats: [TimeInterval], bpm: Double?
    ) {
        let regrouped = TimedLyricSegmentGrouper.regroup(analysis.lyrics ?? [])
        let beats = analysis.beatTimes ?? []
        let verdict = MetricalLevelReconciler.reconcile(
            bpm: analysis.estimatedBPM ?? 0, beatTimes: beats,
            lineOnsets: regrouped.map(\.start))
        let bpm = verdict?.isRetune == true ? verdict?.bpm : analysis.estimatedBPM
        let reconciledBeats =
            verdict?.isRetune == true
            ? MetricalLevelReconciler.reconciledBeatTimes(beatTimes: beats, ratio: verdict!.ratio)
            : beats
        // `LyricPhraseGrouper` was deleted 2026-08-07 (it fired on zero real songs); the real
        // pipeline now goes straight from the regroup to the recutter, and so does this replica.
        return (regrouped, reconciledBeats, bpm)
    }

    /// Sensitivity sweep for the "is this a real gap" floor, kept because it is what settled
    /// `minimumGapSeconds`: 0.05 and 0.08 both fire on 4 of 5 songs, 0.12 and above drop to 3 by
    /// silencing Flip Flops entirely. 0.08 is the lower of the two that still means something
    /// against the measured gap distribution (p90 ≈ 0.12 s).
    func testGapFloorSweep() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SW_RECUT_SWEEP"] == "1", "manual sweep")
        let urls = try FileManager.default.contentsOfDirectory(
            at: songsDirectory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let detector = try repoRhymeDetector()
        for floor in [0.05, 0.08, 0.12, 0.18, 0.25] {
            var fired = 0
            var summary: [String] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                    let document = try? JSONDecoder().decode(SongDocument.self, from: data),
                    let analysis = document.analysis
                else { continue }
                let input = pipelineInput(analysis)
                let (_, report) = PhrasePeriodLineRecutter.recutReporting(
                    input.lines, beatTimes: input.beats, tempo: input.bpm,
                    configuration: .init(minimumGapSeconds: floor), detector: detector)
                guard let report else { continue }
                if report.accepted { fired += 1 }
                summary.append(
                    String(
                        format: "%@ s%d/m%d %.0f->%.0f%% %.2f->%.2fx",
                        (report.accepted ? "+" : "-") as NSString, report.splits, report.merges,
                        100 * report.outlierRateBefore, 100 * report.outlierRateAfter,
                        report.spanRatioBefore, report.spanRatioAfter))
            }
            print("floor=\(floor)  fired=\(fired)  " + summary.joined(separator: " | "))
        }
    }

    func testRecutOnRealSongs() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SW_RECUT_DIAG"] == "1", "manual diagnostic; set SW_RECUT_DIAG=1")
        let ungated = environment["SW_RECUT_UNGATED"] == "1"
        let detector = try repoRhymeDetector()
        let urls = try FileManager.default.contentsOfDirectory(
            at: songsDirectory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(urls.isEmpty, "no cached song documents")

        var fired = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                let document = try? JSONDecoder().decode(SongDocument.self, from: data),
                let analysis = document.analysis, let lyrics = analysis.lyrics, !lyrics.isEmpty
            else { continue }
            let title = (document.sourcePath as NSString?)?.lastPathComponent ?? "?"
            let input = pipelineInput(analysis)
            let (lines, report) = PhrasePeriodLineRecutter.recutReporting(
                input.lines, beatTimes: input.beats, tempo: input.bpm, detector: detector)
            let fit = SongBeatsPerLine.estimate(
                beatTimes: input.beats, bpm: input.bpm ?? 0,
                lineOnsets: input.lines.map(\.start))
            print(
                String(
                    format: "\n-- %@ bpm=%.1f fit=%@", title.prefix(34) as NSString,
                    input.bpm ?? 0,
                    String(describing: fit) as NSString))
            guard let report else {
                print("\n== \(title.prefix(34)): no period / nothing to re-cut")
                continue
            }
            if report.accepted { fired += 1 }
            print("\n== \(title.prefix(34))  P=\(report.beatsPerLine) beats")
            print(
                String(
                    format: "   lines %d -> %d   splits=%d merges=%d   "
                        + "candidates=%d blocked=%d (noBoundary=%d narrow=%d cost=%d)  GATE=%@",
                    input.lines.count, lines.count, report.splits, report.merges,
                    report.splitCandidates, report.splitBlocked.blocked,
                    report.splitBlocked.blockedNoBoundary,
                    report.splitBlocked.blockedGapTooNarrow, report.splitBlocked.blockedCost,
                    (report.accepted ? "FIRED" : "rejected") as NSString))
            let period = Double(report.beatsPerLine) * report.beatLength
            func spans(_ set: [TimedLyricSegment]) -> [Double] {
                set.compactMap { line in
                    guard let a = line.words.first, let b = line.words.last else { return nil }
                    return (b.end - a.start) / period
                }.sorted(by: >)
            }
            func p90OverMedian(_ set: [TimedLyricSegment]) -> Double {
                let s = spans(set).sorted()
                guard s.count >= 4 else { return 1 }
                let median = s[s.count / 2]
                return median > 0 ? s[Int(0.9 * Double(s.count - 1))] / median : 1
            }
            print(
                String(
                    format: "   p90/median span %.2fx -> %.2fx", p90OverMedian(input.lines),
                    p90OverMedian(lines)))
            print(
                "   widest rows (periods) before: "
                    + spans(input.lines).prefix(5).map { String(format: "%.2f", $0) }
                    .joined(separator: " ")
                    + "  after: "
                    + spans(lines).prefix(5).map { String(format: "%.2f", $0) }
                    .joined(separator: " "))
            print(
                String(
                    format: "   outlier rate %.0f%% -> %.0f%%    max/median span %.2fx -> %.2fx",
                    100 * report.outlierRateBefore, 100 * report.outlierRateAfter,
                    report.spanRatioBefore, report.spanRatioAfter))
            if ungated, !report.accepted {
                print("   (ungated result would have been the numbers above)")
            }

            // IDEMPOTENCY ON REAL DATA — the whole point of running here rather than on
            // synthetic uniform onsets, which hide exactly this.
            let again = PhrasePeriodLineRecutter.recut(
                lines, beatTimes: input.beats, tempo: input.bpm)
            XCTAssertEqual(
                again.map(\.start), lines.map(\.start),
                "re-running the re-cut on \(title) moved line onsets")
            XCTAssertEqual(
                again.map(\.text), lines.map(\.text),
                "re-running the re-cut on \(title) changed line text")
        }
        print("\n== gate fired on \(fired) of \(urls.count) songs ==")
    }
}
