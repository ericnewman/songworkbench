import XCTest

@testable import SongWorkbench

/// Measures the SECTION structure the builder infers across the real library, because that is the
/// thing a listener judges — "a verse with one line", "a chorus that runs too long" — and no
/// existing diagnostic reports it. The recutter diagnostic reports LINE geometry, which is only
/// the input to this.
///
///     SW_STRUCTURE_DIAG=1 swift test --filter testStructureOnRealSongs
final class SongStructureDiagnosticTests: XCTestCase {
    private struct SongDocument: Decodable {
        struct Analysis: Decodable {
            var lyrics: [TimedLyricSegment]?
        }
        var sourcePath: String?
        var analysis: Analysis?
    }

    /// Both stores are read: the app writes the sandboxed container path, but an unsandboxed
    /// debug build writes the plain one, and whichever the user last ran is the interesting one.
    private var songDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/"
                    + "Application Support/SongWorkbench/songs"),
            home.appendingPathComponent("Library/Application Support/SongWorkbench/songs"),
        ]
    }

    func testStructureOnRealSongs() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SW_STRUCTURE_DIAG"] == "1",
            "manual diagnostic; set SW_STRUCTURE_DIAG=1")
        let urls =
            songDirectories
            .flatMap {
                (try? FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: nil)) ?? []
            }
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(urls.isEmpty, "no cached song documents")

        let analyzer = SongStructureAnalyzer()
        var oneLineSections = 0
        var totalSections = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                let document = try? JSONDecoder().decode(SongDocument.self, from: data),
                let analysis = document.analysis, let lyrics = analysis.lyrics, !lyrics.isEmpty
            else { continue }
            let title = (document.sourcePath as NSString?)?.lastPathComponent ?? "?"
            let lines = lyrics.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
            let sections = analyzer.vocalSections(for: lines)
            guard !sections.isEmpty else { continue }

            // Lines per section: a section owns every line from its start up to the next start.
            var counts: [(String, Int, TimeInterval)] = []
            for (index, section) in sections.enumerated() {
                let end = index + 1 < sections.count ? sections[index + 1].start : .infinity
                let owned = lines.filter { $0.start >= section.start && $0.start < end }
                let span = (owned.last?.end ?? section.start) - section.start
                counts.append((section.label, owned.count, span))
                totalSections += 1
                if owned.count <= 1 { oneLineSections += 1 }
            }
            let longestLine = lines.map { $0.end - $0.start }.max() ?? 0
            print(
                String(
                    format: "\n-- %@  lines=%d  longest_line=%.1fs", title.prefix(34) as NSString,
                    lines.count, longestLine))
            for (label, count, span) in counts {
                let flag = count <= 1 ? "  <-- ONE LINE" : ""
                print(
                    String(
                        format: "   %-10@ lines=%d span=%.1fs%@",
                        label as NSString, count, span, flag as NSString))
            }
        }
        print(
            "\n=== structure summary: \(oneLineSections)/\(totalSections) sections hold "
                + "one line or fewer ===")
    }
}
