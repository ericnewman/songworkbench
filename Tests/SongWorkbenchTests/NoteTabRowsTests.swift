import XCTest

@testable import SongWorkbench

final class NoteTabRowsTests: XCTestCase {
    /// Half-beat buckets at 120 BPM: a click every 0.25 s for 4 s.
    private func grid(stems: [StemBucketNotes]) -> BucketNoteTimeline {
        BucketNoteTimeline(
            gridKey: BucketGridKey(bpm: 120, anchor: 0, duration: 4),
            clickTimes: (0...16).map { Double($0) * 0.25 }, stems: stems)
    }

    private func bucket(_ index: Int, _ midi: Int) -> StemBucketNote {
        StemBucketNote(
            bucketIndex: index, midiNote: midi, pitchClasses: [midi % 12], confidence: 1,
            coverage: 1)
    }

    func testBassTabFretsTheNoteRowOnFourStringsAndHoldsARepeatedNote() throws {
        // E1 open, then A1 held for two buckets, then C2.
        let timeline = grid(stems: [
            StemBucketNotes(
                stemID: StemKind.bass.id,
                notes: [bucket(0, 28), bucket(1, 33), bucket(2, 33), bucket(3, 36)])
        ])
        let block = try XCTUnwrap(
            NoteTabFormatter.block(
                for: StemKind.bass.id, bucketNotes: timeline, noteEvents: nil, inWindow: 0...0.9))
        XCTAssertEqual(block.stringLabels, ["G", "D", "A", "E"])
        XCTAssertEqual(block.columns.count, 4)
        // Each note on a playable string; the held A gets no second fret.
        let lines = block.lines
        XCTAssertEqual(lines.count, 4)
        let frettedColumns = block.columns.map {
            $0.cells.contains { $0 != SoloTabRowFormatter.rest }
        }
        XCTAssertEqual(frettedColumns, [true, true, false, true])
        for (column, midi) in zip(block.columns, [28, 33, nil, 36]) {
            guard let midi else { continue }
            let row = try XCTUnwrap(column.cells.firstIndex { $0 != SoloTabRowFormatter.rest })
            let fret = Int(column.cells[row].filter(\.isNumber))!
            let tuning = NoteTabFormatter.bassTuning.reversed() as [Int]
            XCTAssertEqual(tuning[row] + fret, midi, "the fret sounds the note row's pitch")
        }
    }

    func testGuitarTabPutsAChordOnDistinctStringsFromTheTranscribedNotes() throws {
        let timeline = grid(stems: [StemBucketNotes(stemID: StemKind.guitar.id, notes: [])])
        // A G major chord (G2 B2 D3 G3) struck at 0.5 s, then a single E4 at 1.0 s.
        let events =
            [43, 47, 50, 55].map {
                NoteEvent(
                    onset: 0.5, offset: 0.9, midiNote: $0, confidence: 1, pitchBendSemitones: nil)
            } + [
                NoteEvent(
                    onset: 1.0, offset: 1.2, midiNote: 64, confidence: 1, pitchBendSemitones: nil)
            ]
        let block = try XCTUnwrap(
            NoteTabFormatter.block(
                for: StemKind.guitar.id, bucketNotes: timeline,
                noteEvents: [NoteEventTimeline(stemID: StemKind.guitar.id, events: events)],
                inWindow: 0...1.4))
        XCTAssertEqual(block.stringLabels.count, 6)
        let chordColumn = try XCTUnwrap(block.columns.first { $0.time == 0.5 })
        let tuning = GuitarTabAssigner.standardTuning.reversed() as [Int]
        let sounded = chordColumn.cells.enumerated().compactMap { row, cell -> Int? in
            cell == SoloTabRowFormatter.rest ? nil : tuning[row] + Int(cell.filter(\.isNumber))!
        }
        XCTAssertEqual(sounded.sorted(), [43, 47, 50, 55], "every chord tone on its own string")
        // Without transcribed notes there is no guitar tab.
        XCTAssertNil(
            NoteTabFormatter.block(
                for: StemKind.guitar.id, bucketNotes: timeline, noteEvents: nil, inWindow: 0...1.4))
    }

    func testTabStringsShowEvenWhereNothingIsPlayed() throws {
        let timeline = grid(stems: [
            StemBucketNotes(stemID: StemKind.bass.id, notes: [bucket(0, 40)])
        ])
        let block = try XCTUnwrap(
            NoteTabFormatter.block(
                for: StemKind.bass.id, bucketNotes: timeline, noteEvents: nil, inWindow: 2.0...2.9))
        XCTAssertEqual(block.columns.count, 4)
        XCTAssertTrue(
            block.columns.allSatisfy { $0.cells.allSatisfy { $0 == SoloTabRowFormatter.rest } })
    }

    func testTabStaysInsideTheRowWindow() throws {
        let timeline = grid(stems: [
            StemBucketNotes(
                stemID: StemKind.bass.id, notes: (0..<16).map { bucket($0, 40 + $0 % 3) })
        ])
        let block = try XCTUnwrap(
            NoteTabFormatter.block(
                for: StemKind.bass.id, bucketNotes: timeline, noteEvents: nil, inWindow: 1.0...1.9))
        XCTAssertEqual(block.columns.map(\.time), [1.0, 1.25, 1.5, 1.75])
    }

    func testTheFretAssignerTakesABassTuning() {
        let notes = [28, 33, 38, 43]
        let placements = GuitarTabAssigner.assign(
            midiNotes: notes, tuning: NoteTabFormatter.bassTuning)
        // Each placement sounds its note on the bass's strings (a run stays in one position,
        // so A, D and G land at fret 5 rather than on open strings mid-run).
        for (note, placement) in zip(notes, placements) {
            XCTAssertEqual(NoteTabFormatter.bassTuning[placement.string] + placement.fret, note)
        }
        XCTAssertTrue(placements.allSatisfy { (0..<4).contains($0.string) })
    }

    func testTheChordLaneLeadsWithTheChordStillSoundingAndSkipsHiddenChords() {
        let chords = [
            EditableChordEvent(time: 0.2, chord: "G", confidence: 1),
            EditableChordEvent(time: 1.4, chord: "C", confidence: 1),
            EditableChordEvent(time: 1.6, chord: "Am", confidence: 1, hidden: true),
        ]
        let lane = NoteTabFormatter.chordLane(chords, inWindow: 1.0...1.9)
        XCTAssertEqual(lane.map(\.label), ["G", "C"])
        XCTAssertEqual(lane.map(\.isHeld), [true, false])
        XCTAssertEqual(lane.first?.time, 1.0)
    }

    func testTabTransposesWithTheChartNotesAndChordsAlike() throws {
        let timeline = grid(stems: [
            StemBucketNotes(stemID: StemKind.bass.id, notes: [bucket(0, 39)])  // Eb2
        ])
        let block = try XCTUnwrap(
            NoteTabFormatter.block(
                for: StemKind.bass.id, bucketNotes: timeline, noteEvents: nil,
                chords: [EditableChordEvent(time: 0, chord: "Eb", confidence: 1)],
                inWindow: 0...0.9, transposedBy: 1))
        XCTAssertEqual(block.chords.map(\.label), ["E"])
        let column = try XCTUnwrap(block.columns.first)
        let row = try XCTUnwrap(column.cells.firstIndex { $0 != SoloTabRowFormatter.rest })
        let tuning = NoteTabFormatter.bassTuning.reversed() as [Int]
        XCTAssertEqual(tuning[row] + Int(column.cells[row].filter(\.isNumber))!, 40, "Eb2 up to E2")
    }
}
