import XCTest

@testable import SongWorkbench

final class BassLineDiagnosticTests: XCTestCase {
    func testAnalyzeRealBassStemWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["CCS_BASS_STEM"] else {
            throw XCTSkip("Set CCS_BASS_STEM to a bass stem path to run this diagnostic.")
        }
        let url = URL(fileURLWithPath: path)
        let observations = try BassLineAnalyzer().analyze(url: url)
        let names = observations.prefix(20).map {
            "\(BassNoteNaming.name(forMidiNote: $0.midiNote))@\(String(format: "%.1f", $0.timestamp))"
        }
        print("BASS_DIAG count=\(observations.count) first=\(names)")
        XCTAssertGreaterThan(observations.count, 0)
    }

    /// Exercises the exact path the harmony stage uses: wrap the stem in a
    /// StoredStemFiles (security-scoped bookmark), resolve it, and analyze the
    /// resolved bass URL.
    func testAnalyzeBassViaStoredStemRoundTripWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["CCS_BASS_STEM"] else {
            throw XCTSkip("Set CCS_BASS_STEM to a bass stem path to run this diagnostic.")
        }
        let url = URL(fileURLWithPath: path)
        let files = StemFiles(vocals: url, drums: url, bass: url, other: url)
        let stored = StoredStemFiles(files: files)
        let resolvedBass = stored.resolved().bass
        print(
            "BASS_DIAG stored.bass.path=\(resolvedBass.path) "
                + "isReadable=\(FileManager.default.isReadableFile(atPath: resolvedBass.path)) "
                + "fileExists=\(FileManager.default.fileExists(atPath: resolvedBass.path))")
        let observations = try BassLineAnalyzer().analyze(url: resolvedBass)
        print("BASS_DIAG roundtrip count=\(observations.count)")
        XCTAssertGreaterThan(observations.count, 0)
    }
}
