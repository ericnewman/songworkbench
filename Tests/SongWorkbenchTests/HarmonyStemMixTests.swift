import XCTest

@testable import SongWorkbench

final class HarmonyStemMixTests: XCTestCase {
    /// Constant-amplitude square-ish signal at `level`, so RMS is exactly `level`.
    private func tone(_ level: Float, count: Int = 1_000) -> [Float] {
        (0..<count).map { $0.isMultiple(of: 2) ? level : -level }
    }

    private func contributor(_ label: String, _ weight: Float, _ samples: [Float])
        -> HarmonyStemMix.Contributor
    {
        HarmonyStemMix.Contributor(label: label, weight: weight, samples: samples)
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    // MARK: - Weighting

    func testWeightsExpressPriorityRegardlessOfHowLoudTheStemWas() {
        // A quiet-but-real piano at a 0.6 weight must contribute 0.6x the guitar, not 0.6x its own
        // (tiny) mix level. Both stems are the same waveform at wildly different levels, so the
        // mix is guitar*1.0 + piano*0.6 in the same phase — 1.6x a unit-RMS signal.
        let loudGuitar = tone(0.8)
        let quietPiano = tone(0.05)
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, loudGuitar),
            contributor("piano", 0.6, quietPiano),
        ])
        XCTAssertEqual(mix.included, ["guitar", "piano"])
        XCTAssertTrue(mix.excludedAsLeakage.isEmpty)
        // Peak normalization divides by 1.6, so RMS lands back at 1.0 relative to the peak.
        XCTAssertEqual(rms(mix.samples), 1.0, accuracy: 1e-4)
    }

    func testZeroWeightStemNeverReachesTheMix() {
        // The shipped bass weight. Bass must not enter the chroma by default.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("bass", 0.0, tone(0.9)),
        ])
        XCTAssertEqual(mix.included, ["guitar"])
    }

    func testBassIsShippedAtZeroWeight() {
        let bass = HarmonyStemMix.defaultWeights.first { $0.kind == .bass }
        XCTAssertEqual(
            bass?.weight, 0, "bass in the chroma manufactures inversions as root changes")
        XCTAssertEqual(HarmonyStemMix.defaultWeights.map(\.kind), [.guitar, .piano, .bass])
    }

    // MARK: - Leakage gate

    func testStemFarBelowTheLoudestIsDroppedAsLeakage() {
        // 40 dB down: separation bleed, not a part. Without the gate, unit-RMS normalization
        // would amplify it to full level and double-count the guitar.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, tone(0.005)),
        ])
        XCTAssertEqual(mix.included, ["guitar"])
        XCTAssertEqual(mix.excludedAsLeakage, ["piano"])
    }

    func testStemJustInsideTheFloorIsKept() {
        // 20 dB down is a quiet but genuine part, above the -25 dB floor.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, tone(0.05)),
        ])
        XCTAssertEqual(mix.included, ["guitar", "piano"])
    }

    func testLeakageGateIsRelativeNotAbsolute() {
        // A quiet recording: both stems are low level, but neither is bleed relative to the other.
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.01)),
            contributor("piano", 0.6, tone(0.008)),
        ])
        XCTAssertEqual(mix.included, ["guitar", "piano"])
    }

    // MARK: - Degenerate input

    func testSilentAndEmptyContributorsAreIgnored() {
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, []),
            contributor("other", 0.4, [Float](repeating: 0, count: 1_000)),
        ])
        XCTAssertEqual(mix.included, ["guitar"])
    }

    func testNothingUsableYieldsAnEmptyMix() {
        XCTAssertTrue(HarmonyStemMix.mixed([]).samples.isEmpty)
        XCTAssertTrue(
            HarmonyStemMix.mixed([contributor("guitar", 0, tone(0.5))]).samples.isEmpty)
        XCTAssertTrue(
            HarmonyStemMix.mixed([
                contributor("guitar", 1, [Float](repeating: 0, count: 100))
            ]).samples.isEmpty)
    }

    func testMixLengthIsTheShortestIncludedContributor() {
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5, count: 1_000)),
            contributor("piano", 0.6, tone(0.5, count: 600)),
        ])
        XCTAssertEqual(mix.samples.count, 600)
    }

    func testMixStaysInsideUnitRange() {
        let mix = HarmonyStemMix.mixed([
            contributor("guitar", 1.0, tone(0.5)),
            contributor("piano", 0.6, tone(0.4)),
            contributor("other", 0.5, tone(0.3)),
        ])
        XCTAssertLessThanOrEqual(mix.samples.map(abs).max() ?? 0, 1.0)
    }
}
