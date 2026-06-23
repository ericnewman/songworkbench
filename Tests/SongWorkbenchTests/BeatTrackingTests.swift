import XCTest

@testable import SongWorkbench

final class BeatTrackingTests: XCTestCase {
    func testTrackerFindsSynthetic120BPMClickTrack() throws {
        let sampleRate = 8_000.0
        let duration = 12.0
        var samples = [Float](repeating: 0, count: Int(sampleRate * duration))
        let beatInterval = Int(sampleRate * 0.5)
        for start in stride(from: 0, to: samples.count, by: beatInterval) {
            for offset in 0..<min(80, samples.count - start) {
                samples[start + offset] = Float(1 - Double(offset) / 80)
            }
        }

        let estimate = try XCTUnwrap(
            BeatTracker(
                minimumBPM: 90,
                maximumBPM: 150,
                frameLength: 256,
                hopLength: 64
            ).analyze(samples: samples, sampleRate: sampleRate))

        XCTAssertEqual(estimate.bpm, 120, accuracy: 2)
        XCTAssertGreaterThan(estimate.beatTimes.count, 20)
        XCTAssertGreaterThan(estimate.confidence, 0)
    }

    func testTrackerRejectsSilence() {
        XCTAssertNil(
            BeatTracker().analyze(
                samples: [Float](repeating: 0, count: 8_192),
                sampleRate: 44_100
            ))
    }
}
