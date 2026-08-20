import XCTest

@testable import SongWorkbench

/// The song has ONE bar grid. These pin the estimator's policy and the contract that a phase
/// nobody measured is never handed to the decoder as if it had been.
final class SongBarGridTests: XCTestCase {
    private func beats(_ count: Int, bpm: Double = 120) -> [TimeInterval] {
        (0..<count).map { Double($0) * 60.0 / bpm }
    }

    /// Accents on every 4th beat starting at `phase`.
    private func accents(_ count: Int, phase: Int, strong: Double = 4, weak: Double = 1) -> [Double]
    {
        (0..<count).map { $0 % 4 == phase ? strong : weak }
    }

    func testStrongDrumAccentsSetThePhaseAndAreLabelledAsMeasured() {
        let grid = SongBarGridEstimator.estimate(
            beatTimes: beats(32), beatStrengths: accents(32, phase: 1), lyricLineOnsets: [])
        XCTAssertEqual(grid.barPhase, 1)
        XCTAssertEqual(grid.phaseSource, .drumAccents)
        XCTAssertGreaterThanOrEqual(grid.confidence, SongBarGrid.minimumPhaseConfidence)
    }

    func testFlatAccentsFallBelowTheGateAndAnchorToBeatZero() {
        // A phase-1 accent far too weak to clear the gate: it must NOT win.
        let weakAccents = (0..<32).map { $0 % 4 == 1 ? 1.02 : 1.0 }
        let grid = SongBarGridEstimator.estimate(
            beatTimes: beats(32), beatStrengths: weakAccents, lyricLineOnsets: [])
        XCTAssertLessThan(grid.confidence, SongBarGrid.minimumPhaseConfidence)
        XCTAssertEqual(grid.barPhase, 0)
        XCTAssertEqual(grid.phaseSource, .anchoredToFirstBeat)
    }

    func testNoDrumStemAnchorsToBeatZeroWithZeroConfidence() {
        let grid = SongBarGridEstimator.estimate(
            beatTimes: beats(32), beatStrengths: [], lyricLineOnsets: [])
        XCTAssertEqual(grid.barPhase, 0)
        XCTAssertEqual(grid.confidence, 0)
        XCTAssertEqual(grid.phaseSource, .anchoredToFirstBeat)
        XCTAssertEqual(grid.beatsPerBar, 4)
    }

    /// Beats per bar comes from lyric-line phrasing, not from a hard-coded 4.
    func testFiveBeatPhrasingIsDetectedFromLyricLineOnsets() {
        let beatTimes = beats(60)
        let beatLength = 0.5
        let onsets = stride(from: 0, to: 50, by: 5).map { Double($0) * beatLength }
        let grid = SongBarGridEstimator.estimate(
            beatTimes: beatTimes, beatStrengths: [], lyricLineOnsets: Array(onsets))
        XCTAssertEqual(grid.beatsPerBar, 5)
    }

    func testFourFourPhrasingStaysFourFour() {
        let beatTimes = beats(60)
        let onsets = stride(from: 0, to: 48, by: 4).map { Double($0) * 0.5 }
        let grid = SongBarGridEstimator.estimate(
            beatTimes: beatTimes, beatStrengths: [], lyricLineOnsets: Array(onsets))
        XCTAssertEqual(grid.beatsPerBar, 4)
    }

    /// The contract the refactor exists to enforce: the decoder gets a meter ONLY when the phase
    /// was actually measured. An anchored phase is a display convention, not evidence, and feeding
    /// it to the decoder would let a convention masquerade as a downbeat observation.
    func testAnchoredPhaseIsNotEvidenceForTheDecoder() {
        let anchored = SongBarGridEstimator.estimate(
            beatTimes: beats(32), beatStrengths: [], lyricLineOnsets: [])
        let measured = SongBarGridEstimator.estimate(
            beatTimes: beats(32), beatStrengths: accents(32, phase: 2), lyricLineOnsets: [])
        XCTAssertNotEqual(anchored.phaseSource, .drumAccents)
        XCTAssertEqual(measured.phaseSource, .drumAccents)
    }

    /// A metrical retune rescales the beat grid (old index i ↔ new index i×ratio), so the bar
    /// grid must move with it: same physical downbeats, counted at the new level.
    func testRetunePreservesBarDurationWhenExactlyRepresentable() {
        let grid = SongBarGrid(
            beatsPerBar: 4, barPhase: 2, confidence: 0.4, phaseSource: .drumAccents)
        let retuned = grid.retuned(by: MetricalRatio(3, 2))
        XCTAssertEqual(retuned.beatsPerBar, 6)
        XCTAssertEqual(retuned.barPhase, 3)
        XCTAssertEqual(retuned.confidence, 0.4)
        XCTAssertEqual(retuned.phaseSource, .drumAccents)
    }

    func testRetuneAnchorsHonestlyWhenPhaseFallsBetweenNewBeats() {
        // Phase 1 at x3/2 would be new index 1.5 — not a beat on the new grid. The measured
        // phase is unrepresentable there, so the result must anchor with zero confidence, not
        // round and keep claiming a measurement.
        let grid = SongBarGrid(
            beatsPerBar: 4, barPhase: 1, confidence: 0.4, phaseSource: .drumAccents)
        let retuned = grid.retuned(by: MetricalRatio(3, 2))
        XCTAssertEqual(retuned.barPhase, 0)
        XCTAssertEqual(retuned.confidence, 0)
        XCTAssertEqual(retuned.phaseSource, .anchoredToFirstBeat)
        XCTAssertEqual(retuned.beatsPerBar, 6)
    }

    func testIdentityRetuneIsANoOp() {
        let grid = SongBarGrid(
            beatsPerBar: 5, barPhase: 3, confidence: 0.9, phaseSource: .drumAccents)
        XCTAssertEqual(grid.retuned(by: .identity), grid)
    }

    /// The builder and the view both read the shared grid rather than re-estimating, so a chord
    /// written into "bar N beat 1" is drawn on the barline that claims to be beat 1.
    func testBuilderAndViewReadTheSameGridTheStageStored() {
        let shared = SongBarGrid(
            beatsPerBar: 3, barPhase: 2, confidence: 0.5, phaseSource: .drumAccents)
        var document = SongAnalysisDocument()
        document.barGrid = shared
        let round = try! JSONDecoder().decode(
            SongAnalysisDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(round.barGrid, shared)
    }
}
