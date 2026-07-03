import XCTest

@testable import SongWorkbench

final class MeasureGridTests: XCTestCase {
    // MARK: MeasureGrid mapping

    func testBeatIndexMapsBeatsToIntegersAndInterpolates() {
        // Uniform grid at 0.5s spacing (120 bpm): 0.0, 0.5, 1.0, 1.5, 2.0
        let grid = MeasureGrid(beatTimes: [0, 0.5, 1.0, 1.5, 2.0], bpm: 120)
        XCTAssertEqual(grid.beatIndex(atTime: 0.0), 0, accuracy: 1e-9)
        XCTAssertEqual(grid.beatIndex(atTime: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(grid.beatIndex(atTime: 2.0), 4, accuracy: 1e-9)
        // Midway between beats 1 and 2.
        XCTAssertEqual(grid.beatIndex(atTime: 0.75), 1.5, accuracy: 1e-9)
    }

    func testBeatIndexExtrapolatesBeyondEnds() {
        let grid = MeasureGrid(beatTimes: [1.0, 1.5, 2.0], bpm: 120)  // beatLength 0.5
        // 0.5s before the first beat → one beat earlier.
        XCTAssertEqual(grid.beatIndex(atTime: 0.5), -1, accuracy: 1e-9)
        // 0.5s after the last beat → one beat later (index 3).
        XCTAssertEqual(grid.beatIndex(atTime: 2.5), 3, accuracy: 1e-9)
    }

    func testTimeAtBeatIndexIsInverse() {
        let grid = MeasureGrid(beatTimes: [0, 0.5, 1.0, 1.5, 2.0], bpm: 120)
        for t in stride(from: -0.4, through: 2.4, by: 0.13) {
            let round = grid.time(atBeatIndex: grid.beatIndex(atTime: t))
            XCTAssertEqual(round, t, accuracy: 1e-6)
        }
    }

    func testDownbeatsAndNearestDownbeatResolvePickupsForward() {
        // barPhase 0, 4/4: downbeats at indices 0, 4, 8...
        let grid = MeasureGrid(
            beatTimes: Array(stride(from: 0.0, through: 6.0, by: 0.5)), bpm: 120, barPhase: 0)
        XCTAssertTrue(grid.isDownbeat(beatIndex: 0))
        XCTAssertTrue(grid.isDownbeat(beatIndex: 4))
        XCTAssertFalse(grid.isDownbeat(beatIndex: 3))
        // A pickup on beat index 3 (one before downbeat 4) resolves FORWARD to 4.
        XCTAssertEqual(grid.nearestDownbeatIndex(toBeatIndex: 3), 4)
        // Beat index 5 (mid next bar) resolves back to 4.
        XCTAssertEqual(grid.nearestDownbeatIndex(toBeatIndex: 5), 4)
    }

    func testBarPhaseShiftsDownbeatColumn() {
        let grid = MeasureGrid(
            beatTimes: Array(stride(from: 0.0, through: 8.0, by: 0.5)), bpm: 120, barPhase: 2)
        // Downbeats now at 2, 6, 10...
        XCTAssertTrue(grid.isDownbeat(beatIndex: 2))
        XCTAssertTrue(grid.isDownbeat(beatIndex: 6))
        XCTAssertFalse(grid.isDownbeat(beatIndex: 0))
    }

    // MARK: DownbeatEstimator

    func testBarPhaseDetectsAllOnDownbeatTwo() {
        // Grid at 0.5s spacing; onsets land exactly on beat indices 2, 6, 10 (residue 2).
        let beats = Array(stride(from: 0.0, through: 12.0, by: 0.5))
        let onsets = [1.0, 3.0, 5.0, 7.0]  // times of beat indices 2, 6, 10, 14
        XCTAssertEqual(DownbeatEstimator.barPhase(beatTimes: beats, onsets: onsets), 2)
    }

    func testBarPhasePrefersDownbeatOverPickup() {
        // Half the onsets on residue 0 (downbeat), half on residue 3 (pickup before it).
        // The estimator must choose phase 0 (downbeat), not phase 3.
        let beats = Array(stride(from: 0.0, through: 20.0, by: 0.5))
        var onsets: [TimeInterval] = []
        for bar in 0..<5 {
            let base = Double(bar) * 4 * 0.5  // downbeat time of this bar
            onsets.append(base)  // residue 0
            onsets.append(base + 3 * 0.5)  // residue 3 (pickup into next downbeat)
        }
        XCTAssertEqual(DownbeatEstimator.barPhase(beatTimes: beats, onsets: onsets), 0)
    }

    func testBarPhaseOnRealisticAnacrusisCadence() {
        // "She thinks I'm a millionaire": bpm 105.46875, first beat ~0.325.
        // Vocal-line first-word onsets cluster on downbeat (residue 0) and pickup (residue 3).
        let bpm = 105.46875
        let beatLen = 60.0 / bpm
        let first = 0.3250793
        let beats = (0..<343).map { first + Double($0) * beatLen }
        let onsets: [TimeInterval] = [
            22.54, 27.58, 31.66, 36.40, 40.58, 45.58, 49.08, 55.16, 59.24, 63.32,
            68.84, 77.00, 82.08, 86.52, 91.08, 95.56, 100.28, 104.36, 109.88,
        ]
        // Downbeat is residue 0 under this phase, so the detected bar phase is 0.
        XCTAssertEqual(DownbeatEstimator.barPhase(beatTimes: beats, onsets: onsets), 0)
    }

    func testDegenerateInputReturnsZeroPhase() {
        XCTAssertEqual(DownbeatEstimator.barPhase(beatTimes: [], onsets: [1, 2]), 0)
        XCTAssertEqual(DownbeatEstimator.barPhase(beatTimes: [0, 0.5], onsets: []), 0)
    }

    // MARK: DownbeatEstimator — accent-strength (drums/bass) phase

    func testBarPhaseFromBeatStrengthsPicksAccentedDownbeat() {
        // Strong accent on every 4th beat starting at index 1 (phase 1), weak elsewhere.
        var strengths = [Double]()
        for i in 0..<16 {
            strengths.append(i % 4 == 1 ? 1.0 : 0.2)
        }
        XCTAssertEqual(DownbeatEstimator.barPhase(beatStrengths: strengths), 1)
    }

    func testDownbeatConfidenceHighForClearAccentLowForFlat() {
        var clear = [Double]()
        for i in 0..<16 { clear.append(i % 4 == 0 ? 1.0 : 0.1) }
        let flat = [Double](repeating: 0.5, count: 16)
        XCTAssertGreaterThan(DownbeatEstimator.downbeatConfidence(beatStrengths: clear), 0.5)
        XCTAssertLessThan(DownbeatEstimator.downbeatConfidence(beatStrengths: flat), 0.05)
    }

    func testBeatStrengthsDegenerateReturnsZero() {
        XCTAssertEqual(DownbeatEstimator.barPhase(beatStrengths: []), 0)
        XCTAssertEqual(DownbeatEstimator.downbeatConfidence(beatStrengths: [1, 2]), 0)
    }

    // MARK: DownbeatEstimator — beats-per-bar (phrase period) estimation

    func testEstimateBeatsPerBarKeepsFourForFourBeatPhrasing() {
        // 120 BPM grid, lines every 4 beats (2s).
        let beats = stride(from: 0.0, through: 40.0, by: 0.5).map { $0 }
        let onsets = stride(from: 4.0, through: 36.0, by: 2.0).map { $0 }
        XCTAssertEqual(
            DownbeatEstimator.estimateBeatsPerBar(beatTimes: beats, onsets: onsets), 4)
    }

    func testEstimateBeatsPerBarDetectsFiveBeatPhrasing() {
        // The Summertime symptom: tactus 0.534s (112.35 BPM), lyric lines every ~2.7s = 5 beats.
        let beats = stride(from: 0.0, through: 80.0, by: 0.534).map { $0 }
        let onsets = [24.56, 27.22, 29.95, 32.65, 35.02, 37.72, 40.37, 43.20]
        XCTAssertEqual(
            DownbeatEstimator.estimateBeatsPerBar(beatTimes: beats, onsets: onsets), 5)
    }

    func testEstimateBeatsPerBarFallsBackOnSparseInput() {
        XCTAssertEqual(DownbeatEstimator.estimateBeatsPerBar(beatTimes: [], onsets: [1, 2, 3]), 4)
        XCTAssertEqual(
            DownbeatEstimator.estimateBeatsPerBar(
                beatTimes: [0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
                onsets: [1.0]),
            4)
    }

    // MARK: DownbeatEstimator — beat alignment (metric vs first-word anchoring)

    func testBeatAlignmentHighWhenOnsetsSitOnBeats() {
        let beats = stride(from: 0.0, through: 40.0, by: 0.5).map { $0 }
        // On-beat onsets with slight jitter (±0.05s = ±0.1 beat).
        let onsets: [TimeInterval] = [4.03, 6.0, 7.97, 10.05, 12.0, 14.02, 16.0, 17.95]
        XCTAssertGreaterThan(
            DownbeatEstimator.beatAlignment(beatTimes: beats, onsets: onsets), 0.7)
    }

    func testBeatAlignmentLowForRubatoOnsets() {
        let beats = stride(from: 0.0, through: 40.0, by: 0.5).map { $0 }
        // The measured Summertime pattern: deviations spread across the full ±half-beat range.
        let onsets: [TimeInterval] = [4.22, 6.17, 8.24, 10.05, 12.21, 14.13, 16.24, 17.88]
        XCTAssertLessThan(
            DownbeatEstimator.beatAlignment(beatTimes: beats, onsets: onsets), 0.3)
    }

    func testBeatAlignmentDegenerateReturnsZero() {
        XCTAssertEqual(DownbeatEstimator.beatAlignment(beatTimes: [], onsets: [1]), 0)
        XCTAssertEqual(DownbeatEstimator.beatAlignment(beatTimes: [0, 0.5], onsets: []), 0)
    }

    func testEstimateBeatsPerBarIgnoresSectionScaleGaps() {
        // Four-beat phrasing with one 13s section break must still return 4.
        let beats = stride(from: 0.0, through: 60.0, by: 0.5).map { $0 }
        var onsets = stride(from: 4.0, through: 16.0, by: 2.0).map { $0 }
        onsets += stride(from: 29.0, through: 41.0, by: 2.0).map { $0 }
        XCTAssertEqual(
            DownbeatEstimator.estimateBeatsPerBar(beatTimes: beats, onsets: onsets), 4)
    }
}
