import XCTest

@testable import SongWorkbench

final class ChorusChordConsensusTests: XCTestCase {
    // 120 BPM → 0.5 s beats over 40 s.
    private let beats = stride(from: 0.0, through: 40.0, by: 0.5).map { $0 }

    private func chorusLine(at start: TimeInterval) -> TimedLyricSegment {
        TimedLyricSegment(
            start: start, end: start + 4.0, text: "She makes me want to settle down",
            words: [])
    }

    func testDissentingChorusLabelIsRewrittenToTheConfidentMajority() {
        // Three identical chorus lines; beat offsets 0 and 4 carry chords. The third
        // instance mis-decoded beat 0 as Fm with low confidence — the vote fixes it.
        let lyrics = [chorusLine(at: 2.0), chorusLine(at: 14.0), chorusLine(at: 26.0)]
        let chords = [
            EditableChordEvent(time: 2.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 4.0, chord: "Db", confidence: 0.8),
            EditableChordEvent(time: 14.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 16.0, chord: "Db", confidence: 0.8),
            EditableChordEvent(time: 26.0, chord: "Fm", confidence: 0.4),  // dissenter
            EditableChordEvent(time: 28.0, chord: "Db", confidence: 0.8),
        ]
        let out = ChorusChordConsensus.applied(chords: chords, lyrics: lyrics, beatTimes: beats)
        XCTAssertEqual(out.map(\.chord), ["Ab", "Db", "Ab", "Db", "Ab", "Db"])
        // Times and count untouched — labels only.
        XCTAssertEqual(out.map(\.time), chords.sorted { $0.time < $1.time }.map(\.time))
    }

    func testWeakMajorityLeavesLabelsAlone() {
        // Two instances disagreeing with equal confidence: no clear winner → no rewrite.
        let lyrics = [chorusLine(at: 2.0), chorusLine(at: 14.0)]
        let chords = [
            EditableChordEvent(time: 2.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 14.0, chord: "Fm", confidence: 0.8),
        ]
        let out = ChorusChordConsensus.applied(chords: chords, lyrics: lyrics, beatTimes: beats)
        XCTAssertEqual(Set(out.map(\.chord)), ["Ab", "Fm"])
    }

    func testNonRepeatedLinesAreUntouched() {
        let lyrics = [
            TimedLyricSegment(start: 2, end: 6, text: "First unique line here", words: []),
            TimedLyricSegment(start: 14, end: 18, text: "Second different line here", words: []),
        ]
        let chords = [
            EditableChordEvent(time: 2.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 14.0, chord: "Fm", confidence: 0.8),
        ]
        let out = ChorusChordConsensus.applied(chords: chords, lyrics: lyrics, beatTimes: beats)
        XCTAssertEqual(Set(out.map(\.chord)), ["Ab", "Fm"])
    }
}
