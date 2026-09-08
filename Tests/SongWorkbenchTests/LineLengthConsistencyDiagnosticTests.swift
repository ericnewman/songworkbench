import Foundation
import XCTest

@testable import SongWorkbench

/// Diagnostic: are the chart's rows the same number of beats long in the ChordPro/timeline as in
/// the Review preview's phrase frame? Compares, per real song, the period the pipeline recut the
/// lines on (`PhrasePeriodLineRecutter`: raw `SongBeatsPerLine` fit on the regrouped segments)
/// with the period the preview draws every row against (`ChordProAppPreview.phraseBeats`: fit on
/// the displayed first-word onsets, doubled when occupancy < 0.5), then measures how long the
/// timeline's lyric rows actually are in beats.
///
///     SW_LINE_LENGTH_DIAG=1 swift test --skip-build --filter LineLengthConsistencyDiagnosticTests
final class LineLengthConsistencyDiagnosticTests: XCTestCase {
    private struct StoredSong: Decodable {
        let analysis: SongAnalysisDocument
        let sourcePath: String
    }

    func testRowLengthsAgainstBothPeriods() throws {
        guard ProcessInfo.processInfo.environment["SW_LINE_LENGTH_DIAG"] == "1" else {
            throw XCTSkip("Set SW_LINE_LENGTH_DIAG=1 to run this diagnostic")
        }
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/songs"
        )
        var report =
            "| song | bpm | P recut | fit occ. | P preview | lyric rows | rows ≈P | rows ≈2P | rows <P | rows >P (max, beats) | median row beats |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
        for file in try FileManager.default.contentsOfDirectory(atPath: store.path).sorted() {
            let data = try Data(contentsOf: store.appendingPathComponent(file))
            guard let stored = try? JSONDecoder().decode(StoredSong.self, from: data) else {
                continue
            }
            let document = stored.analysis
            guard let bpm = document.estimatedBPM, bpm > 0, !document.chords.isEmpty,
                let beatLength = MetricalLevelReconciler.medianBeatLength(
                    beatTimes: document.beatTimes, bpm: bpm)
            else { continue }
            let name = URL(fileURLWithPath: stored.sourcePath).deletingPathExtension()
                .lastPathComponent
            // Pipeline side: what the recutter fitted on (regrouped segments' starts).
            let regrouped = TimedLyricSegmentGrouper.regroup(document.lyrics)
            let recutFit = SongBeatsPerLine.estimate(
                beatTimes: document.beatTimes, bpm: bpm,
                lineOnsets: regrouped.map(SongBeatsPerLine.lineOnset))
            let recutBeats = SongBeatsPerLine.rowBeats(
                beatTimes: document.beatTimes, bpm: bpm,
                lineOnsets: regrouped.map(SongBeatsPerLine.lineOnset))
            // Preview side: `phraseBeats` on the displayed lines' first-word onsets.
            let previewBeats = SongBeatsPerLine.rowBeats(
                beatTimes: document.beatTimes, bpm: bpm,
                lineOnsets: document.lyrics.map(SongBeatsPerLine.lineOnset))
            // Actual rows, exactly as the chart builds them.
            let input = ChordProDraftInput(
                title: name, tempo: bpm, lyrics: document.lyrics, chords: document.chords,
                beatTimes: document.beatTimes, sourceDuration: document.sourceDuration,
                untranscribedVocalRegions: document.untranscribedVocalRegions,
                barGrid: document.barGrid, bassNotes: document.bassNotes)
            let rows = ChordProDraftBuilder().buildResult(input).timeline.rows
            let lyricBeats = rows.compactMap { row -> Double? in
                guard case .lyric = row.kind, row.end > row.start else { return nil }
                return (row.end - row.start) / beatLength
            }.sorted()
            guard let recutP = recutBeats, let previewP = previewBeats,
                !lyricBeats.isEmpty
            else {
                report += "| \(name) | \(Int(bpm)) | — | — | — | \(lyricBeats.count) | | | | | |\n"
                continue
            }
            let p = Double(previewP)
            let near = { (target: Double) in lyricBeats.filter { abs($0 - target) <= 0.5 }.count }
            let shorter = lyricBeats.filter { $0 < p - 0.5 }.count
            let longer = lyricBeats.filter { $0 > p + 0.5 && abs($0 - 2 * p) > 0.5 }.count
            report += String(
                format: "| %@ | %d | %d | %.2f | %d | %d | %d | %d | %d | %d (%.1f) | %.1f |\n",
                name, Int(bpm.rounded()), recutP, recutFit?.occupancy ?? 0, previewP,
                lyricBeats.count, near(p), near(2 * p), shorter, longer, lyricBeats.last ?? 0,
                lyricBeats[lyricBeats.count / 2])
        }
        print(report)
        try report.write(
            toFile: "/tmp/line-length-consistency.md", atomically: true, encoding: .utf8)
    }
}
