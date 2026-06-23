import Foundation
import XCTest

@testable import SongWorkbench

final class StemSeparationTests: XCTestCase {
    func testProgressFractionIsNormalized() {
        XCTAssertEqual(progress(completed: -1, total: 10).fractionCompleted, 0)
        XCTAssertEqual(progress(completed: 5, total: 10).fractionCompleted, 0.5)
        XCTAssertEqual(progress(completed: 20, total: 10).fractionCompleted, 1)
        XCTAssertEqual(progress(completed: 0, total: 0).fractionCompleted, 0)
    }

    func testLegacyStemFilesRemainValidAndSixSourceFilesExposeNewTracks() {
        let root = URL(fileURLWithPath: "/tmp/stems")
        let files = StemFiles(
            vocals: root.appendingPathComponent("vocals.wav"),
            drums: root.appendingPathComponent("drums.wav"),
            bass: root.appendingPathComponent("bass.wav"),
            other: root.appendingPathComponent("other.wav")
        )

        XCTAssertEqual(files.availableKinds, StemKind.legacyRequired)
        XCTAssertFalse(files.isSixSource)

        let sixSource = StemFiles(
            vocals: files.vocals,
            drums: files.drums,
            bass: files.bass,
            guitar: root.appendingPathComponent("guitar.wav"),
            piano: root.appendingPathComponent("piano.wav"),
            other: files.other
        )
        XCTAssertEqual(sixSource.availableKinds, StemKind.allCases)
        XCTAssertTrue(sixSource.isSixSource)
    }

    private func progress(completed: Int, total: Int) -> StemSeparationProgress {
        StemSeparationProgress(
            phase: .separating,
            completedUnits: completed,
            totalUnits: total
        )
    }
}
