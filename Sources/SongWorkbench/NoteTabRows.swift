import Foundation

/// Bass and guitar note rows as tablature, beside their note names (Eric, 2026-10-07: "for Bass
/// and Guitar Note strips on the Preview page, can we show these as Tablature as well").
///
/// One column per half-beat bucket, on the same grid as the note row. Bass reads its note row
/// (one real pitch per bucket). Guitar reads Basic Pitch notes, because its note row keeps only
/// pitch classes, which have no octave and so no fret. The chord lane's names follow the chart's
/// transposition; the frets follow only the instrument's tuning, so they stay as played (Eric,
/// 2026-10-08: "leave the tabs in E as played").
enum NoteTabFormatter {
    /// E1 A1 D2 G2, low to high.
    static let bassTuning = [28, 33, 38, 43]
    static let bassLabels = ["G", "D", "A", "E"]

    enum Instrument: Equatable, Sendable {
        case bass
        case guitar

        var tuning: [Int] {
            self == .bass ? NoteTabFormatter.bassTuning : GuitarTabAssigner.standardTuning
        }

        var labels: [String] {
            self == .bass ? NoteTabFormatter.bassLabels : SoloTabRowFormatter.stringLabels
        }
    }

    static func instrument(for id: StemID) -> Instrument? {
        func isKind(_ kind: StemKind) -> Bool {
            id == kind.id || id.rawValue.hasPrefix(kind.id.rawValue + ".")
        }
        if isKind(.bass) { return .bass }
        if isKind(.guitar) { return .guitar }
        return nil
    }

    /// The stem's tab inside `window`, or nil when it has nothing to show there.
    /// `chords` (time-sorted) fill the block's chord lane: the guitar's own chords on guitar tab,
    /// the chord line on bass tab (Eric, 2026-10-07: the guitar chord in the guitar tab row, the
    /// bass chord in the bass row). `semitones` transposes the chord names; `fretOffset` moves the
    /// notes before fretting (1 for an instrument tuned down a half step).
    static func block(
        for stemID: StemID, bucketNotes: BucketNoteTimeline?, noteEvents: [NoteEventTimeline]?,
        chords: [EditableChordEvent] = [], inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0, fretOffset: Int = 0
    ) -> SoloTabBlock? {
        guard let instrument = instrument(for: stemID), let bucketNotes else { return nil }
        let clicks = bucketNotes.clickTimes
        let buckets = clicks.indices.dropLast().filter { window.contains(clicks[$0]) }
        guard let first = buckets.first, let last = buckets.last else { return nil }

        // The notes that start in each bucket: one for bass, a chord's worth for guitar.
        var starts: [Int: [Int]] = [:]
        switch instrument {
        case .bass:
            var previous: (bucket: Int, midi: Int)?
            for note in bucketNotes.notes(for: stemID) ?? [] {
                guard let midi = note.midiNote else { continue }
                defer { previous = (note.bucketIndex, midi) }
                // Like the note row: a note held into the next bucket gets no new cell.
                if let previous, previous.bucket == note.bucketIndex - 1, previous.midi == midi {
                    continue
                }
                if (first...last).contains(note.bucketIndex) {
                    starts[note.bucketIndex] = [midi + fretOffset]
                }
            }
        case .guitar:
            guard let events = noteEvents?.first(where: { $0.stemID == stemID })?.events else {
                return nil
            }
            for event in events {
                guard let bucket = bucketIndex(of: event.onset, clicks: clicks),
                    (first...last).contains(bucket)
                else { continue }
                starts[bucket, default: []].append(event.midiNote + fretOffset)
            }
        }
        // A window with nothing played still draws its empty strings (Eric, 2026-10-07: the lines
        // "should always be present").
        let frets = fretted(starts, instrument: instrument)
        let rest = SoloTabRowFormatter.rest
        let columns = (first...last).map { bucket -> SoloTabColumn in
            var cells = [String](repeating: rest, count: instrument.tuning.count)
            for placement in frets[bucket] ?? [] {
                // Cells run top string first; placements count from the low string.
                cells[instrument.tuning.count - 1 - placement.string] =
                    SoloTabRowFormatter.fretText(placement.fret)
            }
            return SoloTabColumn(time: clicks[bucket], cells: cells)
        }
        return SoloTabBlock(
            stemID: stemID, label: BucketNoteRowFormatter.label(for: stemID), columns: columns,
            stringLabels: instrument.labels,
            chords: chordLane(chords, inWindow: window, transposedBy: semitones))
    }

    /// The chords inside `window`, led by the one still sounding at its start.
    static func chordLane(
        _ chords: [EditableChordEvent], inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0
    )
        -> [SoloTabChord]
    {
        func name(_ chord: String) -> String {
            InstrumentChordRowFormatter.transposedName(chord, by: semitones)
        }
        let shown = chords.filter { !$0.hidden }
        var lane = shown.filter { window.contains($0.time) }.map {
            SoloTabChord(time: $0.time, label: name($0.chord))
        }
        if lane.first.map({ $0.time > window.lowerBound + 0.05 }) ?? true,
            let held = shown.last(where: { $0.time < window.lowerBound })
        {
            lane.insert(
                SoloTabChord(time: window.lowerBound, label: name(held.chord), isHeld: true), at: 0)
        }
        return lane
    }

    /// The bucket whose half-open span holds `time`.
    static func bucketIndex(of time: TimeInterval, clicks: [TimeInterval]) -> Int? {
        guard clicks.count >= 2, time >= clicks[0], time < clicks[clicks.count - 1] else {
            return nil
        }
        var low = 0
        var high = clicks.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if clicks[middle] <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Strings and frets for every bucket's notes. Single notes run through the hand-position
    /// DP so a line stays in one position; a chord goes on distinct strings, lowest note on the
    /// lowest free string near the current position.
    static func fretted(_ starts: [Int: [Int]], instrument: Instrument)
        -> [Int: [(string: Int, fret: Int)]]
    {
        let order = starts.keys.sorted()
        let singles = order.filter { starts[$0]?.count == 1 }
        let lines = GuitarTabAssigner.assign(
            midiNotes: singles.compactMap { starts[$0]?.first }, tuning: instrument.tuning)
        var result: [Int: [(string: Int, fret: Int)]] = [:]
        for (bucket, placement) in zip(singles, lines) { result[bucket] = [placement] }
        var position = 0
        for bucket in order {
            if let single = result[bucket]?.first {
                if single.fret > 0 { position = max(0, single.fret - 1) }
                continue
            }
            let chord = chordPlacements(
                starts[bucket] ?? [], tuning: instrument.tuning, near: position)
            result[bucket] = chord
            if let lowest = chord.map(\.fret).filter({ $0 > 0 }).min() {
                position = max(0, lowest - 1)
            }
        }
        return result
    }

    static func chordPlacements(_ midiNotes: [Int], tuning: [Int], near position: Int)
        -> [(string: Int, fret: Int)]
    {
        var used = Set<Int>()
        var placements: [(string: Int, fret: Int)] = []
        var lastString = -1
        for midi in Set(midiNotes).sorted() {
            let candidates = tuning.indices.compactMap { string -> (string: Int, fret: Int)? in
                guard !used.contains(string) else { return nil }
                let fret = midi - tuning[string]
                return (0...GuitarTabAssigner.maximumFret).contains(fret) ? (string, fret) : nil
            }
            func cost(_ option: (string: Int, fret: Int)) -> Int {
                let reach =
                    option.fret == 0
                    ? 1 : max(0, abs(option.fret - position) - GuitarTabAssigner.positionSpan)
                return reach + (option.string < lastString ? 10 : 0)
            }
            guard let best = candidates.min(by: { cost($0) < cost($1) }) else { continue }
            used.insert(best.string)
            lastString = max(lastString, best.string)
            placements.append(best)
        }
        return placements
    }
}
