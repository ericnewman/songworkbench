import XCTest

@testable import SongWorkbench

final class BeatThisTrackerTests: XCTestCase {
    /// Reference values from beat_this's own `LogMelSpect` (torchaudio) on the same signal: two
    /// seconds of 440 Hz + 1234.5 Hz with a click every 5,000 samples, at 22,050 Hz.
    func testLogMelMatchesBeatThisPreprocessing() {
        let rate = 22_050
        var samples = (0..<(2 * rate)).map { index -> Float in
            let time = Double(index) / Double(rate)
            return Float(0.3 * sin(2 * .pi * 440 * time) + 0.2 * sin(2 * .pi * 1234.5 * time))
        }
        for index in stride(from: 0, to: samples.count, by: 5_000) { samples[index] += 0.8 }

        let spectrogram = BeatThisMel.spectrogram(samples: samples)

        XCTAssertEqual(spectrogram.count, 101)
        let expected: [(frame: Int, band: Int, value: Float)] = [
            (0, 0, 5.507750), (10, 5, 0.392759), (10, 20, 1.698838), (37, 40, 1.015628),
            (50, 64, 0.026462), (77, 100, 0.000944), (99, 127, 0.705825), (100, 30, 1.392522),
        ]
        for cell in expected {
            XCTAssertEqual(
                spectrogram[cell.frame][cell.band], cell.value, accuracy: 0.002,
                "frame \(cell.frame), band \(cell.band)")
        }
    }

    /// beat_this's `split_piece(chunk_size: 1500, border_size: 6, avoid_short_end: true)`.
    func testChunksStartWhereBeatThisSplitsAPiece() {
        XCTAssertEqual(BeatThisTracker.chunkStarts(frameCount: 100), [-6])
        XCTAssertEqual(BeatThisTracker.chunkStarts(frameCount: 1_488), [-6])
        XCTAssertEqual(BeatThisTracker.chunkStarts(frameCount: 1_500), [-6, 6])
        XCTAssertEqual(BeatThisTracker.chunkStarts(frameCount: 4_000), [-6, 1_482, 2_506])
        XCTAssertEqual(
            BeatThisTracker.chunkStarts(frameCount: 15_000),
            [-6, 1_482, 2_970, 4_458, 5_946, 7_434, 8_922, 10_410, 11_898, 13_386, 13_506])
    }

    /// The Key West Bar failure: the model also fires on the half beats for a stretch. The decoder
    /// keeps one tempo for the whole song and finds the bar from the downbeat probabilities.
    func testDecoderKeepsOneTempoWhenHalfBeatsFireForAStretch() throws {
        let fps = BeatThisDecoder.framesPerSecond
        let bpm = 94.0
        let seconds = 120.0
        let frameCount = Int(seconds * fps)
        var beat = [Float](repeating: 0.02, count: frameCount)
        var downbeat = [Float](repeating: 0.02, count: frameCount)
        let beatLength = 60 / bpm
        var index = 0
        var time = 0.4
        while time < seconds - 0.1 {
            let frame = Int((time * fps).rounded())
            beat[frame] = 0.95
            // Bars start on the second beat (phase 1).
            if index % 4 == 1 { downbeat[frame] = 0.9 }
            // From 40 s to 80 s the half beats look like beats too.
            let half = Int(((time + beatLength / 2) * fps).rounded())
            if (40.0..<80.0).contains(time), half < frameCount { beat[half] = 0.9 }
            index += 1
            time += beatLength
        }

        let grid = try XCTUnwrap(BeatThisDecoder.decode(beat: beat, downbeat: downbeat))

        XCTAssertEqual(grid.bpm, bpm, accuracy: 0.5)
        let intervals = zip(grid.beatTimes.dropFirst(), grid.beatTimes).map { $0 - $1 }
        XCTAssertEqual(intervals.min() ?? 0, beatLength, accuracy: 0.05)
        XCTAssertEqual(intervals.max() ?? 0, beatLength, accuracy: 0.05)
        XCTAssertEqual(grid.barGrid.beatsPerBar, 4)
        XCTAssertEqual(grid.barGrid.barPhase, 1)
        XCTAssertEqual(grid.barGrid.phaseSource, .beatModel)
    }

    func testDecoderFindsNoPulseInSilence() {
        let silence = [Float](repeating: 0.01, count: 3_000)
        XCTAssertNil(BeatThisDecoder.decode(beat: silence, downbeat: silence))
    }
}
