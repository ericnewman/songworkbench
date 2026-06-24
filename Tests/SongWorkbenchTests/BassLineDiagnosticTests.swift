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
}
