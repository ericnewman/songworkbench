import AVFoundation
import Foundation

/// Common transport surface shared by `AudioPlaybackService` (the original recording) and
/// `StemPlaybackService` (the separated stem mix). `AppModel.activeClock` resolves to
/// whichever one backs `activePlaybackSource`, so call sites that mean "act on whichever is
/// currently active" go through this protocol instead of re-deriving
/// `activePlaybackSource == .stemMix ? stemPlayback.x : playback.x` at every call site. Not to
/// be confused with `PlayerClock` below, which is unrelated sample-time arithmetic used
/// inside both services' `currentTime` implementations.
@MainActor
protocol PlaybackClock: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func seek(to time: TimeInterval)
}

/// Single source of truth for reading an `AVAudioPlayerNode`'s elapsed playback time.
///
/// `playerTime.sampleTime` is expressed in the timebase of the player's OUTPUT BUS —
/// which is whatever format the node was connected with, not necessarily the audio
/// file's sample rate. Dividing a sampleTime by a rate it wasn't expressed in scales
/// the clock by the ratio of the two rates (e.g. a 48 kHz file on a 44.1 kHz bus reads
/// 8.2 % slow, drifting ~5 s behind per minute). `AVAudioTime` carries its own
/// `sampleRate`, so the only correct division is `sampleTime / playerTime.sampleRate`.
enum PlayerClock {
    /// Seconds of audio the player has rendered since its last `stop()`/schedule reset,
    /// or `nil` when the node has no render time yet (not attached/started).
    static func elapsedSeconds(_ player: AVAudioPlayerNode) -> TimeInterval? {
        guard
            let renderTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return nil }
        return elapsedSeconds(playerTime: playerTime)
    }

    /// Testable core: elapsed seconds from a player-timebase `AVAudioTime`.
    static func elapsedSeconds(playerTime: AVAudioTime) -> TimeInterval? {
        guard playerTime.isSampleTimeValid, playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
