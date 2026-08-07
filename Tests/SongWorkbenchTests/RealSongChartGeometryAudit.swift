import SwiftUI
import XCTest

@testable import SongWorkbench

/// Audits EVERY persisted song's chart geometry against the page invariants, through the real
/// pipeline (store → builder → parsed document → the Review chart's own window resolution).
/// This is the verification loop's ground truth: the synthetic invariant tests
/// (`ChartGeometryInvariantTests`) prove the machinery, this proves the user's actual library
/// renders consistently — the two differ whenever real data hits a path the fixture missed.
///
/// Skipped unless `CCS_REAL_SONG_AUDIT=1`: it reads the user's Application Support store, which
/// CI and other machines don't have.
final class RealSongChartGeometryAudit: XCTestCase {
    func testEveryPersistedSongMeetsChartGeometryInvariants() async throws {
        guard ProcessInfo.processInfo.environment["CCS_REAL_SONG_AUDIT"] == "1" else {
            throw XCTSkip("Set CCS_REAL_SONG_AUDIT=1 to audit the local song library.")
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("SongWorkbench", isDirectory: true)
        let document = try await SplitProjectStore(directoryURL: base).load()

        var audited = 0
        var report: [String] = []
        var failures: [String] = []

        for song in document.songs {
            guard let analysis = song.analysis,
                !analysis.chords.isEmpty,
                analysis.beatTimes.count >= 8,
                let bpm = analysis.estimatedBPM, bpm > 0
            else { continue }
            audited += 1
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
            let parsed = try ChordProPreviewDocument(parsing: result.source)
            let items = ChordProPreviewIndexing.indexedBlocks(for: parsed)
            let windowsByLine = Dictionary(
                uniqueKeysWithValues: result.timeline.rows.compactMap { row in
                    row.end > row.start ? (row.number, row.start...row.end) : nil
                })
            let lyricWindows = result.timeline.rows.filter(\.isLyric).map { $0.start...$0.end }
            let beatLength = 60.0 / bpm

            // Resolve every chord-only row exactly as the Review chart does.
            var windows: [(number: Int, start: TimeInterval, end: TimeInterval)] = []
            for (index, item) in items.enumerated()
            where ChordProPreviewIndexing.isChordOnlyRow(items, index) {
                guard let number = item.displayLineNumber,
                    let window = ChordProPreviewLineWindowResolver.chordOnlyLineWindow(
                        items: items,
                        index: index,
                        lyricLineWindows: lyricWindows,
                        timelineWindow: windowsByLine[number],
                        songDuration: analysis.sourceDuration ?? 0,
                        envelopeDurations: [analysis.sourceDuration ?? 0],
                        beatTimes: analysis.beatTimes,
                        beatLengthSeconds: beatLength,
                        chordOnsetTimes: analysis.chords.map(\.time).sorted()
                    )
                else { continue }
                windows.append((number, window.start, window.end))
            }

            // Invariant 1: interior rows of each consecutive run span equal durations.
            var runs: [[(number: Int, start: TimeInterval, end: TimeInterval)]] = []
            for window in windows {
                if let last = runs.last?.last, window.number == last.number + 1 {
                    runs[runs.count - 1].append(window)
                } else {
                    runs.append([window])
                }
            }
            var runSummaries: [String] = []
            for run in runs {
                let durations = run.map { ($0.end - $0.start) }
                runSummaries.append(
                    "rows \(run.first!.number)-\(run.last!.number): "
                        + durations.map { String(format: "%.2fs", $0) }.joined(separator: " "))
                guard run.count > 2 else { continue }
                let interior = run.dropFirst().dropLast().map { $0.end - $0.start }
                if let reference = interior.first {
                    for duration in interior where abs(duration - reference) > 0.05 {
                        failures.append(
                            "\(title): unequal interior rows in run "
                                + "\(run.first!.number)-\(run.last!.number) "
                                + "(\(String(format: "%.2f", duration)) vs "
                                + "\(String(format: "%.2f", reference)))")
                    }
                }
            }
            // Invariant 2: no sliver rows — anything shorter than one beat renders as a
            // near-empty row with a floating chord label.
            for window in windows where window.end - window.start < beatLength {
                failures.append(
                    "\(title): sliver row \(window.number) "
                        + "(\(String(format: "%.2f", window.end - window.start))s)")
            }
            // Invariant 3: consecutive rows tile.
            for (early, late) in zip(windows, windows.dropFirst())
            where late.number == early.number + 1 && abs(early.end - late.start) > 0.05 {
                failures.append(
                    "\(title): gap between rows \(early.number) and \(late.number) "
                        + "(\(String(format: "%.2f", early.end)) → "
                        + "\(String(format: "%.2f", late.start)))")
            }
            report.append(
                "• \(title) — bpm \(String(format: "%.1f", bpm)), "
                    + "\(windows.count) instrumental rows | "
                    + runSummaries.joined(separator: " | "))
        }

        print("=== REAL SONG CHART GEOMETRY AUDIT (\(audited) songs) ===")
        for line in report { print(line) }
        if failures.isEmpty {
            print("ALL INVARIANTS HOLD across \(audited) songs")
        } else {
            print("VIOLATIONS (\(failures.count)):")
            for failure in failures { print("  ✗ \(failure)") }
        }
        XCTAssertGreaterThan(audited, 0, "no songs with analysis found — audit ran on nothing")
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) geometry violations:\n\(failures.joined(separator: "\n"))")
    }

    /// The WINDOW FIT measured on the real library: with the chart scaled so one phrase period
    /// fills the viewport, how wide does each song's rows actually render?
    ///
    /// Asserts the promise — a P-beat row fits — and REPORTS the distribution, because a row that
    /// overruns is not a layout bug: it is a line cut longer than a phrase, which the phrase frame
    /// already flags. The overflow rate here is the same defect counted in pixels.
    func testFittedChartRowWidthsAgainstTheViewport() async throws {
        guard ProcessInfo.processInfo.environment["CCS_REAL_SONG_AUDIT"] == "1" else {
            throw XCTSkip("Set CCS_REAL_SONG_AUDIT=1 to audit the local song library.")
        }
        let viewportWidth = CGFloat(
            Double(ProcessInfo.processInfo.environment["CCS_CHART_VIEWPORT"] ?? "") ?? 1400)
        let inset = ChordProPreviewLineLayout.chartHorizontalInset
        let leading = ChordProPreviewLineLayout.rowLeadingWidth
        let gutterBeats = ChordProPreviewLineLayout.gutterBeats
        let baseCharacterWidth = NSString(string: "M").size(withAttributes: [
            .font: PlatformFont.monospacedSystemFont(
                ofSize: ChordProChartTypography.lyricSize, weight: .regular)
        ]).width

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("SongWorkbench", isDirectory: true)
        let document = try await SplitProjectStore(directoryURL: base).load()

        var audited = 0
        var failures: [String] = []
        print("=== FITTED CHART WIDTH AUDIT (viewport \(Int(viewportWidth)) px, 1× zoom) ===")

        for song in document.songs {
            guard let analysis = song.analysis,
                analysis.beatTimes.count >= 8,
                let bpm = analysis.estimatedBPM, bpm > 0,
                analysis.lyrics.count >= 2
            else { continue }
            let title = URL(fileURLWithPath: song.sourcePath).deletingPathExtension()
                .lastPathComponent
            let beatLength = 60.0 / bpm
            let lines = analysis.lyrics.sorted { $0.start < $1.start }.filter { !$0.words.isEmpty }

            // The chart's own phrase period, including its low-occupancy doubling rule.
            guard
                let phraseFit = SongBeatsPerLine.estimate(
                    beatTimes: analysis.beatTimes, bpm: bpm,
                    lineOnsets: lines.compactMap { $0.words.first?.start })
            else {
                print("• \(title) — no phrase period: chart stays at the fixed 200 px/s axis")
                continue
            }
            let beatsPerLine =
                (phraseFit.occupancy < 0.5 && phraseFit.beatsPerLine < 16)
                ? phraseFit.beatsPerLine * 2 : phraseFit.beatsPerLine
            audited += 1

            let scale = ChordProChartScale(
                fontSize: ChordProChartScale.minimumFontSize,
                fitFactor: ChordProChartScale.fitFactor(
                    availableWidth: viewportWidth,
                    horizontalInset: inset,
                    rowLeadingWidth: leading,
                    beatsPerLine: beatsPerLine,
                    gutterBeats: gutterBeats,
                    beatLengthSeconds: beatLength,
                    basePixelsPerSecond: ChordProPreviewLineLayout.pixelsPerSecond))
            let pixelsPerSecond = scale.scaled(ChordProPreviewLineLayout.pixelsPerSecond)
            let pixelsPerBeat = CGFloat(beatLength) * pixelsPerSecond
            let characterWidth = scale.scaled(baseCharacterWidth)
            let grid = MeasureGrid(beatTimes: analysis.beatTimes, bpm: bpm)
            let rowChrome = scale.scaled(leading) + inset

            // Right edge of each sung row, built the way the chart builds it: the row's own
            // downbeat pinned at the gutter, words placed through the ruler. (Collision nudges
            // are not modelled — they only ever push right, so this is a lower bound.)
            var rightEdges: [CGFloat] = []
            for line in lines {
                let downbeat = grid.nearestDownbeatTime(toTime: line.words[0].start)
                let ruler = ChordRowRuler(
                    grid: grid, originTime: downbeat, gutterPx: gutterBeats * pixelsPerBeat,
                    pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: pixelsPerSecond)
                let wordEnds = line.words.map { word in
                    ruler.x(atTime: word.start) + CGFloat(word.text.count) * characterWidth
                }
                rightEdges.append((wordEnds.max() ?? 0) + rowChrome)
            }
            guard !rightEdges.isEmpty else { continue }

            // The promise: a row exactly one phrase long ends at the viewport's right edge.
            let downbeat = grid.nearestDownbeatTime(toTime: lines[0].words[0].start)
            let ruler = ChordRowRuler(
                grid: grid, originTime: downbeat, gutterPx: gutterBeats * pixelsPerBeat,
                pixelsPerBeat: pixelsPerBeat, pixelsPerSecond: pixelsPerSecond)
            let phraseRowEdge =
                ruler.x(atTime: downbeat + beatLength * Double(beatsPerLine)) + rowChrome
            if phraseRowEdge > viewportWidth + 1 {
                failures.append(
                    "\(title): a \(beatsPerLine)-beat row renders "
                        + "\(String(format: "%.0f", phraseRowEdge)) px in a "
                        + "\(String(format: "%.0f", viewportWidth)) px viewport")
            }

            let sorted = rightEdges.sorted()
            let median = sorted[sorted.count / 2]
            let overflowing = rightEdges.filter { $0 > viewportWidth + 1 }.count
            print(
                "• \(title) — P=\(beatsPerLine) beats, fit \(String(format: "%.2f", scale.fitFactor))×"
                    + " (\(String(format: "%.1f", scale.lyricSize)) pt,"
                    + " \(String(format: "%.0f", pixelsPerBeat)) px/beat) | "
                    + "P-row \(String(format: "%.0f", phraseRowEdge)) px | rows median "
                    + "\(String(format: "%.0f", median)) max "
                    + "\(String(format: "%.0f", sorted.last!)) px | "
                    + "\(overflowing)/\(rightEdges.count) over the window")
        }

        XCTAssertGreaterThan(audited, 0, "no songs with a phrase period — audit ran on nothing")
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) rows do not fit:\n\(failures.joined(separator: "\n"))")
    }
}
