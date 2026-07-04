import Foundation

/// Re-segments already-grouped lyric lines using the song's REPEATING bar-period phrase structure,
/// so verse/chorus lines read as musically even, bar-aligned phrases instead of purely following
/// ASR silence/capitalization cues (`TimedLyricSegmentGrouper`'s domain). This is Stage 1
/// ("bar-period re-segmentation only") of the phased design in
/// `.scratch/PRD-phrase-structure-lyric-grouper.md`; Stage 2 (rhyme/syllable refinement) is a
/// later, separate phase.
///
/// Must run as a POST-PASS, strictly AFTER both `TimedLyricSegmentGrouper.regroup` and harmony
/// analysis finish (see `AppModel.applyAnalysis`) — `TranscriptionStage` and `HarmonyStage` run as
/// concurrent sibling tasks in `SongAnalysisPipeline`, so `beatTimes`/`chords` are never available
/// inside transcription itself (PRD §2). This does not replace `TimedLyricSegmentGrouper`; it
/// consumes its output and may further re-cut it.
///
/// Pure & deterministic. No-ops (returns `lyrics` completely unchanged) whenever beat/tempo/chord
/// data is missing, or no section clears the confidence floor — this is the expected/common case
/// for songs without a clean, regular bar structure (live recordings, rubato passages, spoken-word
/// sections), per the PRD §4 guard: "no-op, loudly, on low confidence."
enum LyricPhraseGrouper {
    struct Configuration: Equatable, Sendable {
        /// Candidate phrase periods to test, in bars. The highest-autocorrelation-scoring
        /// candidate wins; ties keep whichever is listed first. 4 is listed first since most
        /// pop/rock verses are 4- or 8-bar phrases (PRD §3.3.1).
        var candidatePeriodsInBars: [Int]
        /// Minimum bar-label self-similarity (fraction of matching `(i, i + period)` pairs)
        /// required to accept a candidate period. Below this, the section is left completely
        /// alone — see the PRD §4 "no-op, loudly, on low confidence" guard.
        var minimumConfidence: Double
        /// A candidate period is only tried when the section spans at least this many whole
        /// periods worth of bars — a single repeat isn't enough evidence to judge a period.
        var minimumFullPeriods: Int
        var beatsPerBar: Int
        /// Same caps `TimedLyricGroupingConfiguration` uses for ASR-driven lines (PRD §4: "bound
        /// line length by the existing caps"). A computed phrase cell that would exceed either
        /// cap is rejected — the whole section is left unchanged rather than emitting a
        /// degenerate over-long line.
        var maximumLineDuration: TimeInterval
        var maximumLineTokens: Int

        init(
            candidatePeriodsInBars: [Int] = [4, 8, 2],
            minimumConfidence: Double = 0.75,
            minimumFullPeriods: Int = 2,
            beatsPerBar: Int = 4,
            maximumLineDuration: TimeInterval = 15,
            maximumLineTokens: Int = 32
        ) {
            self.candidatePeriodsInBars = candidatePeriodsInBars
            self.minimumConfidence = minimumConfidence
            self.minimumFullPeriods = max(minimumFullPeriods, 1)
            self.beatsPerBar = max(beatsPerBar, 1)
            self.maximumLineDuration = max(maximumLineDuration, 0)
            self.maximumLineTokens = max(maximumLineTokens, 1)
        }
    }

    /// Re-segments `lyrics` (already run through `TimedLyricSegmentGrouper.regroup`) into
    /// bar-period-aligned lines wherever a confident repeating phrase period is found within a
    /// vocal section. Returns `lyrics` unchanged when beat/tempo/chord data is missing.
    static func regroup(
        _ lyrics: [TimedLyricSegment],
        beatTimes: [TimeInterval],
        tempo: Double?,
        chords: [EditableChordEvent],
        configuration: Configuration = .init()
    ) -> [TimedLyricSegment] {
        guard let bpm = tempo, bpm > 0, !beatTimes.isEmpty, !chords.isEmpty, !lyrics.isEmpty else {
            return lyrics
        }
        let sortedChords = chords.sorted { $0.time < $1.time }
        let barPhase = DownbeatEstimator.barPhase(
            beatTimes: beatTimes, onsets: sortedChords.map(\.time),
            beatsPerBar: configuration.beatsPerBar)
        let grid = MeasureGrid(
            beatTimes: beatTimes, bpm: bpm, beatsPerBar: configuration.beatsPerBar,
            barPhase: barPhase)
        guard grid.isUsable else { return lyrics }

        let sortedLyrics = lyrics.sorted { $0.start < $1.start }
        let sections = SongStructureAnalyzer().vocalSections(for: sortedLyrics)
        guard !sections.isEmpty else { return lyrics }

        let ranges = sectionLineIndices(lyrics: sortedLyrics, sections: sections)

        func chordLabel(atBeatIndex beatIndex: Double) -> String {
            let time = grid.time(atBeatIndex: beatIndex)
            // Last chord at/before `time`; falls back to the first chord for a bar preceding the
            // very first detected chord event.
            var label = sortedChords.first?.chord ?? ""
            for event in sortedChords {
                guard event.time <= time else { break }
                label = event.chord
            }
            return label
        }

        func floorDownbeat(atTime time: TimeInterval) -> Int {
            let beatIndex = grid.beatIndex(atTime: time)
            let bars = (beatIndex - Double(grid.barPhase)) / Double(grid.beatsPerBar)
            return Int(bars.rounded(.down)) * grid.beatsPerBar + grid.barPhase
        }

        func barLabels(startDownbeat: Int, endDownbeat: Int) -> [String] {
            guard endDownbeat > startDownbeat else { return [] }
            return stride(from: startDownbeat, to: endDownbeat, by: configuration.beatsPerBar)
                .map { chordLabel(atBeatIndex: Double($0)) }
        }

        func detectPeriod(startDownbeat: Int, endDownbeat: Int) -> (
            period: Int, confidence: Double
        )? {
            let labels = barLabels(startDownbeat: startDownbeat, endDownbeat: endDownbeat)
            guard labels.count >= 2 else { return nil }
            var best: (period: Int, confidence: Double)?
            for period in configuration.candidatePeriodsInBars {
                guard period > 0, labels.count >= period * configuration.minimumFullPeriods else {
                    continue
                }
                var matches = 0
                var total = 0
                for i in 0..<(labels.count - period) {
                    total += 1
                    if labels[i] == labels[i + period] { matches += 1 }
                }
                guard total > 0 else { continue }
                let confidence = Double(matches) / Double(total)
                if best == nil || confidence > best!.confidence {
                    best = (period, confidence)
                }
            }
            return best
        }

        // Bar range covering each section — used for both period detection and re-segmentation.
        var sectionBarRange: [Int: (start: Int, end: Int)] = [:]
        for (index, lineIndices) in ranges.enumerated() {
            guard !lineIndices.isEmpty else { continue }
            let lines = lineIndices.map { sortedLyrics[$0] }
            let start = floorDownbeat(atTime: lines.map(\.start).min()!)
            var end = floorDownbeat(atTime: lines.map(\.end).max()!)
            if end <= start { end = start + configuration.beatsPerBar }
            sectionBarRange[index] = (start, end)
        }

        // Chorus occurrences must share ONE period so repeats stay structurally identical (PRD §4
        // chorus-determinism guard) — `SongStructureAnalyzer`'s word-set-Jaccard chorus detection
        // would otherwise silently regress if two occurrences of the same chorus re-segmented
        // differently due to beat-grid jitter between the two sung passes.
        var decisions: [Int: (period: Int, confidence: Double)?] = [:]
        let chorusIndices = sections.indices.filter { sections[$0].kind == .chorus }
        if !chorusIndices.isEmpty {
            var shared: (period: Int, confidence: Double)?
            for index in chorusIndices {
                guard let barRange = sectionBarRange[index] else { continue }
                if let candidate = detectPeriod(
                    startDownbeat: barRange.start, endDownbeat: barRange.end),
                    shared == nil || candidate.confidence > shared!.confidence
                {
                    shared = candidate
                }
            }
            for index in chorusIndices { decisions[index] = shared }
        }
        for index in sections.indices where sections[index].kind == .verse {
            guard let barRange = sectionBarRange[index] else { continue }
            decisions[index] = detectPeriod(
                startDownbeat: barRange.start, endDownbeat: barRange.end)
        }

        var result: [TimedLyricSegment] = []
        for (index, lineIndices) in ranges.enumerated() {
            let lines = lineIndices.map { sortedLyrics[$0] }
            guard
                let decision = decisions[index] ?? nil,
                decision.confidence >= configuration.minimumConfidence,
                let barRange = sectionBarRange[index]
            else {
                result.append(contentsOf: lines)
                continue
            }
            result.append(
                contentsOf: resegmented(
                    lines: lines, periodInBars: decision.period, barRange: barRange, grid: grid,
                    configuration: configuration))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Maps each section (by index into `sections`) to the indices (into `lyrics`) of the lines
    /// that fall inside it — every line before the next section's start, or all remaining lines
    /// for the last section. `lyrics` and `sections` must already be sorted by start time.
    private static func sectionLineIndices(
        lyrics: [TimedLyricSegment], sections: [SongStructureAnalyzer.VocalSection]
    ) -> [[Int]] {
        var indices = Array(repeating: [Int](), count: sections.count)
        var sectionIndex = 0
        for (lineIndex, line) in lyrics.enumerated() {
            while sectionIndex + 1 < sections.count, line.start >= sections[sectionIndex + 1].start
            {
                sectionIndex += 1
            }
            indices[sectionIndex].append(lineIndex)
        }
        return indices
    }

    /// Re-cuts a section's lines into one new line per phrase-period cell: takes the union of
    /// every word already in the section's lines and re-cuts at the word GAP nearest each computed
    /// phrase boundary (`section start + k * period`, in bars), never mid-word. Only ever re-cuts
    /// at REAL existing silences between words already present — it cannot resurrect material an
    /// earlier gate removed, and it cannot re-merge words across a section boundary (`lines` here
    /// is always exactly one section's own lines). Falls back to `lines` unchanged whenever no
    /// safe cut is found, a section has no per-word data, or a resulting cell would violate the
    /// existing line-length caps.
    private static func resegmented(
        lines: [TimedLyricSegment], periodInBars: Int, barRange: (start: Int, end: Int),
        grid: MeasureGrid, configuration: Configuration
    ) -> [TimedLyricSegment] {
        let words = lines.flatMap(\.words).sorted { $0.start < $1.start }
        guard !words.isEmpty, lines.allSatisfy({ !$0.words.isEmpty }) else { return lines }

        let periodInBeats = periodInBars * configuration.beatsPerBar
        var boundaryBeats = barRange.start + periodInBeats
        var boundaryTimes: [TimeInterval] = []
        while boundaryBeats < barRange.end {
            boundaryTimes.append(grid.time(atBeatIndex: Double(boundaryBeats)))
            boundaryBeats += periodInBeats
        }
        guard !boundaryTimes.isEmpty else { return lines }

        // Snap each computed boundary to the nearest REAL inter-word gap (the midpoint between two
        // consecutive words), so a cut never lands mid-word. A boundary with no gap within half a
        // period of it is dropped — nothing there to cut at (e.g. a long melisma spanning it).
        let periodSeconds = Double(periodInBeats) * grid.beatLength
        let maxSnapDistance = periodSeconds / 2
        var cutAfterWordIndices = Set<Int>()
        for boundary in boundaryTimes {
            var bestIndex: Int?
            var bestDistance = TimeInterval.infinity
            for i in 0..<(words.count - 1) {
                let gapMidpoint = (words[i].end + words[i + 1].start) / 2
                let distance = abs(gapMidpoint - boundary)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = i
                }
            }
            if let bestIndex, bestDistance <= maxSnapDistance {
                cutAfterWordIndices.insert(bestIndex)
            }
        }
        guard !cutAfterWordIndices.isEmpty else { return lines }

        var cells: [[TimedLyricWord]] = []
        var current: [TimedLyricWord] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            if cutAfterWordIndices.contains(index) {
                cells.append(current)
                current = []
            }
        }
        if !current.isEmpty { cells.append(current) }
        guard cells.count > 1 else { return lines }

        for cell in cells {
            let duration = cell.last!.end - cell.first!.start
            guard duration <= configuration.maximumLineDuration,
                cell.count <= configuration.maximumLineTokens
            else {
                return lines
            }
        }

        return cells.map(segment(from:))
    }

    /// Builds a `TimedLyricSegment` from an ordered word list — same "join words with a single
    /// space, recompute character ranges" convention `AudioFileAnalysisService.lyricSegment(from:)`
    /// uses when rebuilding a segment from a filtered word list.
    private static func segment(from words: [TimedLyricWord]) -> TimedLyricSegment {
        var text = ""
        var rebuiltWords: [TimedLyricWord] = []
        for word in words {
            if !text.isEmpty { text += " " }
            let lower = text.count
            text += word.text
            rebuiltWords.append(
                TimedLyricWord(
                    text: word.text, start: word.start, end: word.end,
                    characterRange: lower..<text.count))
        }
        return TimedLyricSegment(
            start: words.first!.start, end: words.last!.end, text: text, words: rebuiltWords)
    }
}
