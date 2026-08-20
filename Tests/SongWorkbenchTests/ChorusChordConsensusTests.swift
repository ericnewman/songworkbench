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

    /// The unification win: a near-verbatim ASR variant of a chorus line ("slip flops" for
    /// "flip flops") is the SAME line by the shared matcher (`RepeatedLyricLineGroups`), so its
    /// chords vote with the group. The old exact-text matcher excluded it — a line the chart
    /// labelled Chorus whose chords were invisible to its own chorus's vote.
    func testNearVerbatimVariantLineVotesWithItsGroup() {
        var variant = chorusLine(at: 26.0)
        variant.text = "She makes me want to settle now"  // one garbled word
        let lyrics = [chorusLine(at: 2.0), chorusLine(at: 14.0), variant]
        let chords = [
            EditableChordEvent(time: 2.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 14.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 26.0, chord: "Fm", confidence: 0.4),  // dissenter
        ]
        let out = ChorusChordConsensus.applied(chords: chords, lyrics: lyrics, beatTimes: beats)
        XCTAssertEqual(out.map(\.chord), ["Ab", "Ab", "Ab"])
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

    // MARK: - Direct pitch evidence outranks the vote

    func testProtectedEventResistsAQualityOnlyRewrite() {
        // The third chorus genuinely plays Abm — the arrangement changing, which is exactly the
        // bar an agreement-by-analogy vote overwrites. Its third was confirmed from the chroma
        // (`ChordQualityAudit`), so the vote may not flip it back.
        let lyrics = [chorusLine(at: 2.0), chorusLine(at: 14.0), chorusLine(at: 26.0)]
        let dissenter = EditableChordEvent(time: 26.0, chord: "Abm", confidence: 0.8)
        let chords = [
            EditableChordEvent(time: 2.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 14.0, chord: "Ab", confidence: 0.8),
            dissenter,
        ]
        let out = ChorusChordConsensus.applied(
            chords: chords, lyrics: lyrics, beatTimes: beats, protectedIDs: [dissenter.id])
        XCTAssertEqual(out.map(\.chord), ["Ab", "Ab", "Abm"])

        // Unprotected, the same vote rewrites it — proving the guard is what saved it.
        let unguarded = ChorusChordConsensus.applied(
            chords: chords, lyrics: lyrics, beatTimes: beats)
        XCTAssertEqual(unguarded.map(\.chord), ["Ab", "Ab", "Ab"])
    }

    func testProtectionDoesNotBlockARootRewrite() {
        // The quality audit only ever examined the third, so it must not veto a vote that moves
        // the ROOT — that is still A3's job and its main effect.
        let lyrics = [chorusLine(at: 2.0), chorusLine(at: 14.0), chorusLine(at: 26.0)]
        let dissenter = EditableChordEvent(time: 26.0, chord: "Fm", confidence: 0.4)
        let chords = [
            EditableChordEvent(time: 2.0, chord: "Ab", confidence: 0.8),
            EditableChordEvent(time: 14.0, chord: "Ab", confidence: 0.8),
            dissenter,
        ]
        let out = ChorusChordConsensus.applied(
            chords: chords, lyrics: lyrics, beatTimes: beats, protectedIDs: [dissenter.id])
        XCTAssertEqual(out.map(\.chord), ["Ab", "Ab", "Ab"])
    }
}
