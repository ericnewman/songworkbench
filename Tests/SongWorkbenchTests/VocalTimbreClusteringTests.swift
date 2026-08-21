import Foundation
import XCTest

@testable import SongWorkbench

final class VocalTimbreClusteringTests: XCTestCase {
    // Two singers with clearly separated harmonic envelopes, plus a little per-note jitter so the
    // vectors are not literally identical within a singer.
    private func timbre(_ base: [Float], jitter: Float) -> [Float] {
        let raw = base.enumerated().map { $0.offset == 2 ? $0.element + jitter : $0.element }
        let norm = sqrt(raw.reduce(Float(0)) { $0 + $1 * $1 })
        return raw.map { $0 / norm }
    }

    private func lowSinger(_ jitter: Float) -> [Float] { timbre([1, 0, 0, 0], jitter: jitter) }
    private func highSinger(_ jitter: Float) -> [Float] { timbre([0, 1, 0, 0], jitter: jitter) }

    /// The core regression. Two singers hold simultaneous notes; their pitch lines cross halfway
    /// through, so plain pitch-rank assignment swaps their rows mid-phrase. Timbre must keep each
    /// singer on one row for the whole phrase.
    func testCrossingVoicesStayOnTheirOwnRow() {
        let singerA = [60, 62, 67, 69]  // starts below, ends above
        let singerB = [72, 70, 64, 62]  // starts above, ends below
        var notes: [VocalTimbreClustering.Note] = []
        for step in 0..<4 {
            let start = TimeInterval(step)
            notes.append(
                .init(
                    start: start,
                    end: start + 1,
                    pitch: singerA[step],
                    timbre: lowSinger(Float(step) * 0.01)
                )
            )
            notes.append(
                .init(
                    start: start,
                    end: start + 1,
                    pitch: singerB[step],
                    timbre: highSinger(Float(step) * 0.01)
                )
            )
        }

        let rows = VocalTimbreClustering.rows(for: notes, maximumRows: 2)
        let aRows = stride(from: 0, to: notes.count, by: 2).map { rows[$0] }
        let bRows = stride(from: 1, to: notes.count, by: 2).map { rows[$0] }
        XCTAssertEqual(aRows, [0, 0, 0, 0], "Singer A must hold one row across the crossing")
        XCTAssertEqual(bRows, [1, 1, 1, 1], "Singer B must hold one row across the crossing")

        // Prove this test would fail under plain pitch-rank assignment: strip the timbre and the
        // rows swap at the crossing.
        let untimbred = notes.map {
            VocalTimbreClustering.Note(start: $0.start, end: $0.end, pitch: $0.pitch, timbre: nil)
        }
        let pitchRows = VocalTimbreClustering.rows(for: untimbred, maximumRows: 2)
        let aPitchRows = stride(from: 0, to: notes.count, by: 2).map { pitchRows[$0] }
        XCTAssertEqual(aPitchRows, [0, 0, 1, 1], "Pitch rank swaps singer A onto the upper row")
    }

    func testAllNilTimbreFallsBackToExactPitchRank() {
        let notes: [VocalTimbreClustering.Note] = [
            .init(start: 0, end: 2, pitch: 64),
            .init(start: 0, end: 2, pitch: 60),
            .init(start: 0, end: 2, pitch: 67),
            .init(start: 3, end: 4, pitch: 72),  // alone: rank 0 despite being highest
        ]
        XCTAssertEqual(VocalTimbreClustering.rows(for: notes, maximumRows: 4), [1, 0, 2, 0])
    }

    func testSingleTimbredNoteStillUsesPitchRank() {
        // Fewer than two timbre vectors means there is nothing to cluster.
        let notes: [VocalTimbreClustering.Note] = [
            .init(start: 0, end: 1, pitch: 67, timbre: lowSinger(0)),
            .init(start: 0, end: 1, pitch: 60),
        ]
        XCTAssertEqual(VocalTimbreClustering.rows(for: notes, maximumRows: 3), [1, 0])
    }

    func testOverlappingNotesNeverShareARow() {
        // Three voices, one of which shares a timbre with another - the collision rule, not the
        // clustering, has to keep them apart.
        let notes: [VocalTimbreClustering.Note] = [
            .init(start: 0, end: 2, pitch: 60, timbre: lowSinger(0)),
            .init(start: 0.5, end: 2.5, pitch: 64, timbre: lowSinger(0.02)),
            .init(start: 1, end: 3, pitch: 71, timbre: highSinger(0)),
            .init(start: 2.6, end: 3.5, pitch: 62, timbre: lowSinger(0.01)),
        ]
        let rows = VocalTimbreClustering.rows(for: notes, maximumRows: 4)
        for i in notes.indices {
            for j in notes.indices where j > i {
                guard notes[i].start < notes[j].end, notes[j].start < notes[i].end else { continue }
                XCTAssertNotEqual(rows[i], rows[j], "Notes \(i) and \(j) overlap and share a row")
            }
        }
    }

    func testRowsStayWithinBounds() {
        let notes: [VocalTimbreClustering.Note] = (0..<12).map { index in
            .init(
                start: TimeInterval(index) * 0.25,
                end: TimeInterval(index) * 0.25 + 2,
                pitch: 55 + index * 2,
                timbre: index.isMultiple(of: 3) ? nil : lowSinger(Float(index) * 0.05)
            )
        }
        for cap in 2...4 {
            let rows = VocalTimbreClustering.rows(for: notes, maximumRows: cap)
            XCTAssertEqual(rows.count, notes.count)
            XCTAssertTrue(rows.allSatisfy { (0..<cap).contains($0) }, "cap \(cap) produced \(rows)")
        }
    }

    func testEmptyInputAndDegenerateCap() {
        XCTAssertEqual(VocalTimbreClustering.rows(for: [], maximumRows: 3), [])
        let notes: [VocalTimbreClustering.Note] = [
            .init(start: 0, end: 1, pitch: 60, timbre: lowSinger(0)),
            .init(start: 0, end: 1, pitch: 67, timbre: highSinger(0)),
        ]
        XCTAssertEqual(VocalTimbreClustering.rows(for: notes, maximumRows: 0), [0, 0])
    }

    func testTwoRowCapWithThreeSimultaneousVoices() {
        let notes: [VocalTimbreClustering.Note] = [
            .init(start: 0, end: 1, pitch: 60, timbre: lowSinger(0)),
            .init(start: 0, end: 1, pitch: 64, timbre: timbre([0, 0, 0, 1], jitter: 0)),
            .init(start: 0, end: 1, pitch: 71, timbre: highSinger(0)),
        ]
        let rows = VocalTimbreClustering.rows(for: notes, maximumRows: 2)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0 == 0 || $0 == 1 })
        // With more voices than rows the third one has to double up somewhere; all we require is
        // that two of the three still land on separate rows.
        XCTAssertEqual(Set(rows).count, 2)
    }

    func testDeterministicAcrossRuns() {
        var notes: [VocalTimbreClustering.Note] = []
        for index in 0..<20 {
            let start = TimeInterval(index % 7) * 0.5
            let pitch: Int = 58 + (index * 5) % 19
            var vector: [Float]?
            if !index.isMultiple(of: 4) {
                let jitter = Float(index) * 0.01
                vector = index.isMultiple(of: 2) ? lowSinger(jitter) : highSinger(jitter)
            }
            notes.append(.init(start: start, end: start + 1.25, pitch: pitch, timbre: vector))
        }
        let first = VocalTimbreClustering.rows(for: notes, maximumRows: 4)
        let second = VocalTimbreClustering.rows(for: notes, maximumRows: 4)
        XCTAssertEqual(first, second)
    }

    /// The bug the per-window clustering caused: the SAME notes, split into two display windows,
    /// used to re-derive centroids and re-rank them, so a singer swapped rows between lyric lines.
    /// Song-level `voices` must be identical whether or not the phrase is later windowed.
    func testSongLevelVoicesAreStableRegardlessOfWindowing() {
        let low: [Float] = [0.9, 0.3, 0.2, 0.1]
        let high: [Float] = [0.1, 0.2, 0.3, 0.9]
        let notes = [
            VocalTimbreClustering.Note(start: 0, end: 1, pitch: 55, timbre: low),
            VocalTimbreClustering.Note(start: 0, end: 1, pitch: 67, timbre: high),
            VocalTimbreClustering.Note(start: 1, end: 2, pitch: 60, timbre: low),
            VocalTimbreClustering.Note(start: 1, end: 2, pitch: 64, timbre: high),
            // The lines cross here: the low-timbre singer goes above the high-timbre one.
            VocalTimbreClustering.Note(start: 2, end: 3, pitch: 69, timbre: low),
            VocalTimbreClustering.Note(start: 2, end: 3, pitch: 57, timbre: high),
        ]

        let whole = VocalTimbreClustering.voices(for: notes, maximumVoices: 2)
        XCTAssertEqual(whole[0], whole[2])
        XCTAssertEqual(whole[0], whole[4])
        XCTAssertEqual(whole[1], whole[3])
        XCTAssertEqual(whole[1], whole[5])
        XCTAssertNotEqual(whole[0], whole[1])

        // Feeding the persisted voices back through `rows` per window must preserve them.
        for window in [Array(notes[0..<2]), Array(notes[2..<4]), Array(notes[4..<6])] {
            let offset = notes.firstIndex {
                $0.pitch == window[0].pitch && $0.start == window[0].start
            }!
            let preassigned = (offset..<offset + window.count).map { Optional(whole[$0]) }
            let rows = VocalTimbreClustering.rows(
                for: window, maximumRows: 2, preassigned: preassigned)
            XCTAssertEqual(rows, [whole[offset], whole[offset + 1]])
        }
    }

    /// A separate lead/backing stem is a whole model's opinion about who is singing; timbre must
    /// never merge notes from two different stems into one voice.
    func testDifferentVocalStemsNeverShareAVoice() {
        // Deliberately IDENTICAL timbre, so only the stem label can separate them.
        let same: [Float] = [0.5, 0.5, 0.5, 0.5]
        let notes = [
            VocalTimbreClustering.Note(
                start: 0, end: 1, pitch: 60, timbre: same, source: "vocals.lead"),
            VocalTimbreClustering.Note(
                start: 0, end: 1, pitch: 64, timbre: same, source: "vocals.backing"),
            VocalTimbreClustering.Note(
                start: 1, end: 2, pitch: 62, timbre: same, source: "vocals.lead"),
            VocalTimbreClustering.Note(
                start: 1, end: 2, pitch: 67, timbre: same, source: "vocals.backing"),
        ]

        let voices = VocalTimbreClustering.voices(for: notes, maximumVoices: 2)
        XCTAssertEqual(voices[0], voices[2], "both lead notes belong to one voice")
        XCTAssertEqual(voices[1], voices[3], "both backing notes belong to one voice")
        XCTAssertNotEqual(voices[0], voices[1], "lead and backing must not merge")
    }
}
