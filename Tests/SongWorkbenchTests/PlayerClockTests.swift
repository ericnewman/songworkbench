import AVFoundation
import XCTest

@testable import SongWorkbench

final class PlayerClockTests: XCTestCase {
    func testElapsedUsesTheTimebaseTheSampleTimeIsExpressedIn() {
        // 48 000 samples at a 48 kHz timebase is exactly 1 s — regardless of any file rate.
        let time = AVAudioTime(sampleTime: 48_000, atRate: 48_000)
        XCTAssertEqual(PlayerClock.elapsedSeconds(playerTime: time), 1.0)
    }

    func testElapsedAtADifferentBusRateStillReadsWallClockCorrectly() {
        // The historical bug: a 48 kHz file on a 44.1 kHz bus produced sampleTime in
        // 44.1 kHz frames that was divided by 48 000 → 0.919 s per real second (drift).
        // PlayerClock divides by the timebase the sampleTime is expressed in: exact.
        let time = AVAudioTime(sampleTime: 44_100, atRate: 44_100)
        XCTAssertEqual(PlayerClock.elapsedSeconds(playerTime: time), 1.0)

        let halfSecond = AVAudioTime(sampleTime: 22_050, atRate: 44_100)
        XCTAssertEqual(PlayerClock.elapsedSeconds(playerTime: halfSecond) ?? 0, 0.5, accuracy: 1e-9)
    }

    func testHostTimeOnlyValueReturnsNil() {
        // No valid sampleTime → no clock reading (never guess).
        let time = AVAudioTime(hostTime: 12_345)
        XCTAssertNil(PlayerClock.elapsedSeconds(playerTime: time))
    }
}
