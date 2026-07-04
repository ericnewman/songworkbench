import XCTest

@testable import SongWorkbench

final class BassNoteRowFormatterTests: XCTestCase {
    private func note(_ timestamp: TimeInterval, midiNote: Int) -> BassNoteObservation {
        BassNoteObservation(timestamp: timestamp, midiNote: midiNote, confidence: 0.8)
    }

    func testNoNotesInWindowReturnsNil() {
        let label = BassNoteRowFormatter.label(
            for: [note(0, midiNote: 40)], inWindow: 10...12)
        XCTAssertNil(label)
    }

    func testEmptyBassNotesReturnsNil() {
        XCTAssertNil(BassNoteRowFormatter.label(for: [], inWindow: 0...10))
    }

    func testNotesWithinWindowAreJoinedInOnsetOrder() {
        // E2 = MIDI 40, A2 = MIDI 45, D3 = MIDI 50.
        let notes = [
            note(1.0, midiNote: 45),
            note(0.2, midiNote: 40),
            note(1.8, midiNote: 50),
        ]
        let label = BassNoteRowFormatter.label(for: notes, inWindow: 0...2)
        XCTAssertEqual(label, "E · A · D")
    }

    func testNotesOutsideWindowAreExcluded() {
        let notes = [
            note(0.5, midiNote: 40),  // before the window
            note(2.0, midiNote: 45),  // inside
            note(5.0, midiNote: 50),  // after the window
        ]
        let label = BassNoteRowFormatter.label(for: notes, inWindow: 1...3)
        XCTAssertEqual(label, "A")
    }

    func testWindowBoundsAreInclusive() {
        // E (MIDI 40 % 12 == 4) and F (MIDI 41 % 12 == 5), both exactly on the window edges.
        let notes = [note(1.0, midiNote: 40), note(3.0, midiNote: 41)]
        let label = BassNoteRowFormatter.label(for: notes, inWindow: 1...3)
        XCTAssertEqual(label, "E · F")
    }
}
