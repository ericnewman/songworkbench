import AVFoundation
import XCTest

@testable import SongWorkbench

/// MANUAL diagnostic: replays the real word-placement passes over a song's CACHED lyrics and its
/// vocals stem, printing word times before and after, so a re-timing change can be verified on
/// real data without going through the app. Run with:
///
///     SW_LYRIC_RETIME_DIAG=1 SW_LYRIC_RETIME_SONG=f3e8daf8 \
///       swift test --filter LyricRetimingDiagnosticTests
final class LyricRetimingDiagnosticTests: XCTestCase {
    private struct SongDocument: Decodable {
        struct Analysis: Decodable {
            var lyrics: [TimedLyricSegment]?
        }
        var sourcePath: String?
        var analysis: Analysis?
    }

    private var container: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench"
            )
    }

    func testReplayWordPlacementOnCachedSong() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SW_LYRIC_RETIME_DIAG"] == "1",
            "manual diagnostic; set SW_LYRIC_RETIME_DIAG=1 (and SW_LYRIC_RETIME_SONG=<hash prefix>)"
        )
        let prefix = environment["SW_LYRIC_RETIME_SONG"] ?? ""

        let fm = FileManager.default
        let songs = try fm.contentsOfDirectory(
            at: container.appendingPathComponent("songs"), includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .filter { prefix.isEmpty || $0.lastPathComponent.hasPrefix(prefix) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(songs.isEmpty, "no matching song document for prefix \(prefix)")

        for url in songs {
            let hash = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                let document = try? JSONDecoder().decode(SongDocument.self, from: data),
                let lyrics = document.analysis?.lyrics, !lyrics.isEmpty
            else { continue }
            let vocals =
                container
                .appendingPathComponent("Analysis/Stems/\(hash)/vocals.wav")
            guard fm.fileExists(atPath: vocals.path) else {
                print("-- \(hash.prefix(8)): no vocals stem, skipped")
                continue
            }

            let voiced =
                (try? VocalActivityEnvelope.voicedIntervals(
                    url: vocals, configuration: .strictVocalPresence)) ?? []
            print(
                "\n== \(hash.prefix(8))  lines=\(lyrics.count)  voicedRegions=\(voiced.count) ==")

            let distributed = VocalAlignmentCorrector.distributeAcrossSignal(
                lyrics, voicedIntervals: voiced)
            let repaired = StrandedLeadingWordRepairer.repaired(
                distributed, voicedIntervals: voiced)

            let limit = min(lyrics.count, Int(environment["SW_LYRIC_RETIME_LINES"] ?? "") ?? 4)
            for index in 0..<limit {
                print("\n[\(index)] \(lyrics[index].text)")
                for (position, word) in lyrics[index].words.enumerated() {
                    let after = repaired[index].words[position]
                    let moved = abs(after.start - word.start) > 0.001 ? "   <-- MOVED" : ""
                    print(
                        String(
                            format: "   %-12@ %.3f -> %.3f%@", word.text as NSString, word.start,
                            after.start, moved as NSString))
                }
            }
        }
    }
}
