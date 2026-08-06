import SwiftUI
import XCTest

@testable import SongWorkbench

/// Renders the REAL `ChordProAppPreview` view for real library songs to PNG via `ImageRenderer` —
/// pixel-level verification of the chart with no screen-recording permissions and no running app.
/// The PNGs land in the path given by `CCS_CHART_RENDER_DIR` for visual inspection; the test
/// itself asserts only that rendering succeeds and produces a non-trivial image.
///
/// Skipped unless `CCS_REAL_SONG_AUDIT=1` (reads the user's Application Support store).
final class ChartPixelRenderAudit: XCTestCase {
    @MainActor
    func testRenderRealSongChartsToPNG() async throws {
        guard ProcessInfo.processInfo.environment["CCS_REAL_SONG_AUDIT"] == "1" else {
            throw XCTSkip("Set CCS_REAL_SONG_AUDIT=1 to render the local song library.")
        }
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["CCS_CHART_RENDER_DIR"]
                ?? NSTemporaryDirectory() + "/chart-renders")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("SongWorkbench", isDirectory: true)
        let document = try await SplitProjectStore(directoryURL: base).load()

        var rendered = 0
        for song in document.songs {
            guard let analysis = song.analysis,
                !analysis.chords.isEmpty,
                analysis.beatTimes.count >= 8,
                let bpm = analysis.estimatedBPM, bpm > 0,
                !analysis.lyrics.isEmpty
            else { continue }
            let title = URL(fileURLWithPath: song.sourcePath).deletingPathExtension()
                .lastPathComponent

            let input = ChordProDraftInput(
                title: title,
                tempo: bpm,
                lyrics: analysis.lyrics,
                chords: analysis.chords,
                beatTimes: analysis.beatTimes,
                sourceDuration: analysis.sourceDuration,
                untranscribedVocalRegions: analysis.untranscribedVocalRegions
            )
            let result = ChordProDraftBuilder().buildResult(input)
            let sortedLyrics = analysis.lyrics.sorted { $0.start < $1.start }

            let chordTimesByLine: [Int: [TimeInterval]] = Dictionary(
                uniqueKeysWithValues: result.timeline.rows.map { ($0.number, $0.chordTimes) })
            let windowsByLine: [Int: ClosedRange<TimeInterval>] = Dictionary(
                uniqueKeysWithValues: result.timeline.rows.compactMap { row in
                    row.end > row.start ? (row.number, row.start...row.end) : nil
                })
            var preview = ChordProAppPreview(source: result.source)
            preview.eagerLayoutForRendering = true
            preview.rhythmicSpacing = true
            preview.lyricLineWords = sortedLyrics.map(\.words)
            preview.lyricLineWindows = sortedLyrics.map { $0.start...$0.end }
            preview.songDuration = analysis.sourceDuration ?? 0
            preview.bpm = bpm
            preview.beatTimes = analysis.beatTimes
            preview.chordOnsetTimes = analysis.chords.map(\.time).sorted()
            preview.timelineChordTimesByLine = chordTimesByLine
            preview.timelineRowWindowsByLine = windowsByLine
            preview.lyricSegments = sortedLyrics

            // Width-only proposal: the eager (VStack) render path has intrinsic height, and a
            // fixed-height frame CENTER-clips content taller than itself — the first renders
            // silently showed only each chart's bottom 6000 px. Dark scheme (light renders
            // white-on-white).
            let framed =
                preview
                .frame(width: 2400, alignment: .topLeading)
                .background(Color.black)
                .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: framed)
            renderer.scale = 1
            guard let cgImage = renderer.cgImage else {
                XCTFail("\(title): ImageRenderer produced no image")
                continue
            }
            XCTAssertGreaterThan(cgImage.height, 200, "\(title): render suspiciously short")
            let representation = NSBitmapImageRep(cgImage: cgImage)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                XCTFail("\(title): PNG encode failed")
                continue
            }
            let safeTitle = title.replacingOccurrences(
                of: "[^A-Za-z0-9 _-]", with: "_", options: .regularExpression)
            try png.write(to: outputDirectory.appendingPathComponent("\(safeTitle).png"))
            rendered += 1
        }
        print("=== CHART PIXEL RENDER: \(rendered) songs → \(outputDirectory.path) ===")
        XCTAssertGreaterThan(rendered, 0, "no songs rendered")
    }
}
