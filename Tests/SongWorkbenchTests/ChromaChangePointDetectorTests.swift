import XCTest

@testable import SongWorkbench

/// Deterministic PRNG (xorshift32) so jitter tests are reproducible across runs instead of
/// depending on `SystemRandomNumberGenerator`'s per-run seed — a flaky failure here would be very
/// hard to reproduce and debug.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

final class ChromaChangePointDetectorTests: XCTestCase {
    /// Builds a step function over chroma vectors: each `(chord, duration)` holds a fixed
    /// chroma pattern for `duration` seconds at `hop`-second frames, so the TRUE change-point
    /// times are known exactly (the start of each segment after the first).
    private func syntheticFrames(
        segments: [(chord: [Float], duration: TimeInterval)],
        hop: TimeInterval = 0.05
    ) -> [ChromaVector] {
        var frames: [ChromaVector] = []
        var time: TimeInterval = 0
        for segment in segments {
            let frameCount = max(1, Int((segment.duration / hop).rounded()))
            for _ in 0..<frameCount {
                frames.append(ChromaVector(timestamp: time, values: segment.chord))
                time += hop
            }
        }
        return frames
    }

    private func triad(root: Int, third: Int, fifth: Int = 7) -> [Float] {
        var values = [Float](repeating: 0.02, count: 12)
        values[root] = 1
        values[(root + third) % 12] = 0.8
        values[(root + fifth) % 12] = 0.7
        let total = values.reduce(0, +)
        return values.map { $0 / total }
    }

    func testDetectsKnownChangePointsInCleanStepFunction() {
        // C major (0-2s) -> G major (2-4s) -> A minor (4-6s), no noise. With smoothing off
        // (the default), a clean step function is detected EXACTLY, not just approximately —
        // there is no smoothing-window lag to bias the reported time.
        let cMajor = triad(root: 0, third: 4)
        let gMajor = triad(root: 7, third: 4)
        let aMinor = triad(root: 9, third: 3)
        let frames = syntheticFrames(segments: [
            (cMajor, 2.0), (gMajor, 2.0), (aMinor, 2.0),
        ])

        let changePoints = ChromaChangePointDetector.changePoints(frames: frames)

        XCTAssertEqual(changePoints.count, 2)
        XCTAssertEqual(changePoints[0], 2.0, accuracy: 0.000_001)
        XCTAssertEqual(changePoints[1], 4.0, accuracy: 0.000_001)
    }

    func testIgnoresRepeatedStrumsOfTheSameChordSameNotes() {
        // The same chord "re-struck" every 0.5s should look identical frame-to-frame (chroma is
        // pitch content, not onset energy), so no change-points fire within the sustain — only
        // the single real chord change at 3s should be detected.
        let cMajor = triad(root: 0, third: 4)
        let gMajor = triad(root: 7, third: 4)
        var frames: [ChromaVector] = []
        var time: TimeInterval = 0
        while time < 3.0 {
            frames.append(ChromaVector(timestamp: time, values: cMajor))
            time += 0.05
        }
        while time < 6.0 {
            frames.append(ChromaVector(timestamp: time, values: gMajor))
            time += 0.05
        }

        let changePoints = ChromaChangePointDetector.changePoints(frames: frames)

        XCTAssertEqual(changePoints.count, 1)
        XCTAssertEqual(changePoints[0], 3.0, accuracy: 0.000_001)
    }

    /// Applies small independent per-pitch-class noise to a chroma vector, floored at 0 (chroma
    /// energy cannot be negative).
    private func jittered(
        _ base: [Float],
        range: ClosedRange<Float> = -0.01...0.01,
        using generator: inout SeededGenerator
    ) -> [Float] {
        base.map { value in max(0, value + Float.random(in: range, using: &generator)) }
    }

    func testToleratesSmallJitterWithoutSpuriousChangePoints() {
        // Small per-frame noise around a sustained chord must not manufacture change-points; only
        // the one deliberate chord change should survive the adaptive threshold.
        let cMajor = triad(root: 0, third: 4)
        let fMajor = triad(root: 5, third: 4)
        var generator = SeededGenerator(seed: 42)
        var frames: [ChromaVector] = []
        var time: TimeInterval = 0
        while time < 2.5 {
            frames.append(
                ChromaVector(timestamp: time, values: jittered(cMajor, using: &generator)))
            time += 0.05
        }
        while time < 5.0 {
            frames.append(
                ChromaVector(timestamp: time, values: jittered(fMajor, using: &generator)))
            time += 0.05
        }

        let changePoints = ChromaChangePointDetector.changePoints(frames: frames)

        XCTAssertEqual(changePoints.count, 1)
        XCTAssertEqual(changePoints[0], 2.5, accuracy: 0.05)
    }

    func testToleratesJitterAcrossManyIndependentSeeds() {
        // Robustness check: the adaptive threshold must clear jitter noise (not just for one lucky
        // seed) while still catching the one genuine change, across many independent noise draws.
        let cMajor = triad(root: 0, third: 4)
        let fMajor = triad(root: 5, third: 4)
        for seed in UInt64(1)...30 {
            var generator = SeededGenerator(seed: seed)
            var frames: [ChromaVector] = []
            var time: TimeInterval = 0
            while time < 2.5 {
                frames.append(
                    ChromaVector(timestamp: time, values: jittered(cMajor, using: &generator)))
                time += 0.05
            }
            while time < 5.0 {
                frames.append(
                    ChromaVector(timestamp: time, values: jittered(fMajor, using: &generator)))
                time += 0.05
            }

            let changePoints = ChromaChangePointDetector.changePoints(frames: frames)

            XCTAssertEqual(changePoints.count, 1, "seed \(seed) produced \(changePoints)")
            if let only = changePoints.first {
                XCTAssertEqual(only, 2.5, accuracy: 0.1, "seed \(seed)")
            }
        }
    }

    func testDetectsEveryChangeInARealisticChordProgressionWithJitter() {
        // I-V-vi-IV progression, 2s/bar, repeated 4x (15 real changes across 16 bars), all frames
        // independently jittered — the shape closest to a real analyzed guitar stem's per-frame
        // chroma. Validates the detector doesn't just work on a single isolated transition.
        let cMajor = triad(root: 0, third: 4)
        let gMajor = triad(root: 7, third: 4)
        let aMinor = triad(root: 9, third: 3)
        let fMajor = triad(root: 5, third: 4)
        let progression = [cMajor, gMajor, aMinor, fMajor]
        var generator = SeededGenerator(seed: 7)

        var frames: [ChromaVector] = []
        var time: TimeInterval = 0
        var expectedChangePoints: [TimeInterval] = []
        for barIndex in 0..<16 {
            let chord = progression[barIndex % progression.count]
            if barIndex > 0 { expectedChangePoints.append(time) }
            let barEnd = time + 2.0
            while time < barEnd {
                frames.append(
                    ChromaVector(timestamp: time, values: jittered(chord, using: &generator)))
                time += 0.05
            }
        }

        let changePoints = ChromaChangePointDetector.changePoints(frames: frames)

        XCTAssertEqual(changePoints.count, expectedChangePoints.count)
        for (detected, expected) in zip(changePoints, expectedChangePoints) {
            XCTAssertEqual(detected, expected, accuracy: 0.05)
        }
    }

    func testEmptyOrSingleFrameReturnsNoChangePoints() {
        XCTAssertEqual(ChromaChangePointDetector.changePoints(frames: []), [])
        XCTAssertEqual(
            ChromaChangePointDetector.changePoints(
                frames: [ChromaVector(timestamp: 0, values: triad(root: 0, third: 4))]),
            [])
    }

    func testSilentSequenceProducesNoChangePoints() {
        let silence = [Float](repeating: 0, count: 12)
        let frames = syntheticFrames(segments: [(silence, 3.0)])

        XCTAssertEqual(ChromaChangePointDetector.changePoints(frames: frames), [])
    }

    func testUnorderedFramesAreSortedBeforeDetection() {
        let cMajor = triad(root: 0, third: 4)
        let gMajor = triad(root: 7, third: 4)
        let ordered = syntheticFrames(segments: [(cMajor, 2.0), (gMajor, 2.0)])
        let shuffled = ordered.shuffled()

        let changePoints = ChromaChangePointDetector.changePoints(frames: shuffled)

        XCTAssertEqual(changePoints.count, 1)
        XCTAssertEqual(changePoints[0], 2.0, accuracy: 0.000_001)
    }

    func testSharedNoteChordChangeStillDetected() {
        // C major -> A minor share two of three notes (C, E); the chroma still moves enough
        // (root C drops out, A rises in) to register as a real change-point, unlike a crude
        // broadband-energy detector which cannot see this at all (loudness barely changes).
        let cMajor = triad(root: 0, third: 4)
        let aMinor = triad(root: 9, third: 3)
        let frames = syntheticFrames(segments: [(cMajor, 2.0), (aMinor, 2.0)])

        let changePoints = ChromaChangePointDetector.changePoints(frames: frames)

        XCTAssertEqual(changePoints.count, 1)
        XCTAssertEqual(changePoints[0], 2.0, accuracy: 0.000_001)
    }
}

final class ChordChangePointAuditTests: XCTestCase {
    func testPerfectAlignmentYieldsZeroErrorAndFullHitRate() {
        let result = ChordChangePointAudit.audit(
            chordEventTimes: [2.0, 4.0, 6.0],
            changePoints: [2.0, 4.0, 6.0]
        )

        let unwrapped = try! XCTUnwrap(result)
        XCTAssertEqual(unwrapped.signedMedianError, 0, accuracy: 0.000_001)
        XCTAssertEqual(unwrapped.medianAbsoluteError, 0, accuracy: 0.000_001)
        XCTAssertEqual(unwrapped.hitRate, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(unwrapped.eventCount, 3)
    }

    func testSystematicLagIsCapturedAsSignedError() {
        // Every chord event fires 100ms AFTER the true harmonic change (change-point precedes the
        // event), which should show up as a negative signed median (nearest - event < 0).
        let result = ChordChangePointAudit.audit(
            chordEventTimes: [2.1, 4.1, 6.1],
            changePoints: [2.0, 4.0, 6.0],
            tolerance: 0.05
        )

        let unwrapped = try! XCTUnwrap(result)
        XCTAssertEqual(unwrapped.signedMedianError, -0.1, accuracy: 0.000_001)
        XCTAssertEqual(unwrapped.medianAbsoluteError, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(unwrapped.hitRate, 0, accuracy: 0.000_001)
    }

    func testHitRateReflectsToleranceWindow() {
        // Two events land within 150ms, one lands 500ms away.
        let result = ChordChangePointAudit.audit(
            chordEventTimes: [2.05, 4.10, 6.50],
            changePoints: [2.0, 4.0, 6.0],
            tolerance: 0.15
        )

        let unwrapped = try! XCTUnwrap(result)
        XCTAssertEqual(unwrapped.hitRate, 2.0 / 3.0, accuracy: 0.000_001)
    }

    func testEmptyInputsReturnNil() {
        XCTAssertNil(ChordChangePointAudit.audit(chordEventTimes: [], changePoints: [1, 2]))
        XCTAssertNil(ChordChangePointAudit.audit(chordEventTimes: [1, 2], changePoints: []))
    }

    func testUnsortedChangePointsStillMatchNearestCorrectly() {
        let result = ChordChangePointAudit.audit(
            chordEventTimes: [5.0],
            changePoints: [9.0, 1.0, 5.02]
        )

        let unwrapped = try! XCTUnwrap(result)
        XCTAssertEqual(unwrapped.medianAbsoluteError, 0.02, accuracy: 0.000_001)
    }
}
