import XCTest

@testable import SongWorkbench

final class ReferenceChartComparatorTests: XCTestCase {
    private func chart(_ lines: [String]) -> String {
        (["{title: Test}"] + lines).joined(separator: "\n") + "\n"
    }

    func testPerfectAgreementScoresFullRootAgreementAndNoFindings() throws {
        let generated = chart(["[C]Hello darkness my old [G]friend", "[Am]I've come to [F]talk"])
        let comparison = try ReferenceChartComparator.compare(
            generated: generated, reference: generated)
        XCTAssertEqual(comparison.rootAgreement, 1.0, accuracy: 0.0001)
        XCTAssertNil(comparison.detectedTransposition)
        XCTAssertEqual(comparison.densityRatio, 1.0, accuracy: 0.0001)
        XCTAssertTrue(comparison.systemicFindings.isEmpty, "\(comparison.systemicFindings)")
    }

    func testConstantTranspositionIsDetectedAndCompensated() throws {
        let reference = chart(["[C]Hello darkness my old [G]friend", "[Am]I've come to [F]talk"])
        let generated = chart(["[D]Hello darkness my old [A]friend", "[Bm]I've come to [G]talk"])
        let comparison = try ReferenceChartComparator.compare(
            generated: generated, reference: reference)
        XCTAssertEqual(comparison.detectedTransposition, 2)
        // After compensation the roots all agree.
        XCTAssertEqual(comparison.rootAgreement, 1.0, accuracy: 0.0001)
        XCTAssertTrue(
            comparison.systemicFindings.contains { $0.contains("transposed +2") },
            "\(comparison.systemicFindings)")
    }

    func testOverSegmentationShowsInDensityRatio() throws {
        let reference = chart(["[C]Hello darkness my old friend again tonight"])
        let generated = chart(["[C]Hello [G]darkness [C]my old [F]friend again tonight"])
        let comparison = try ReferenceChartComparator.compare(
            generated: generated, reference: reference)
        XCTAssertEqual(comparison.densityRatio, 4.0, accuracy: 0.0001)
        XCTAssertTrue(
            comparison.systemicFindings.contains { $0.contains("splitting changes") },
            "\(comparison.systemicFindings)")
    }

    func testSystematicQualityCollapseIsCounted() throws {
        let reference = chart([
            "[Cmaj7]Line one words here tonight",
            "[Fmaj7]Line two words here tonight",
            "[Gmaj7]Line three words here tonight",
        ])
        let generated = chart([
            "[C]Line one words here tonight",
            "[F]Line two words here tonight",
            "[G]Line three words here tonight",
        ])
        let comparison = try ReferenceChartComparator.compare(
            generated: generated, reference: reference)
        XCTAssertEqual(comparison.rootAgreement, 1.0, accuracy: 0.0001)
        XCTAssertEqual(comparison.qualityMismatches.first?.referenceSuffix, "maj7")
        XCTAssertEqual(comparison.qualityMismatches.first?.generatedSuffix, "")
        XCTAssertEqual(comparison.qualityMismatches.first?.count, 3)
        XCTAssertTrue(
            comparison.systemicFindings.contains { $0.contains("quality shift") },
            "\(comparison.systemicFindings)")
    }

    func testUnmatchedReferenceLinesAreReported() throws {
        let reference = chart([
            "[C]Hello darkness my old friend",
            "[F]A totally different bridge nobody detected",
        ])
        let generated = chart(["[C]Hello darkness my old friend"])
        let comparison = try ReferenceChartComparator.compare(
            generated: generated, reference: reference)
        XCTAssertEqual(comparison.unmatchedReferenceLines.count, 1)
        XCTAssertTrue(
            comparison.systemicFindings.contains { $0.contains("matched no generated line") })
    }

    func testSlashBassAndAccidentalsParse() {
        XCTAssertEqual(ReferenceChartComparator.rootPitchClass("F#m7"), 6)
        XCTAssertEqual(ReferenceChartComparator.rootPitchClass("Bb/D"), 10)
        XCTAssertEqual(ReferenceChartComparator.suffix(of: "F#m7"), "m7")
        XCTAssertEqual(ReferenceChartComparator.suffix(of: "Bb/D"), "")
        XCTAssertEqual(ReferenceChartComparator.suffix(of: "Cmaj7/G"), "maj7")
    }
}
