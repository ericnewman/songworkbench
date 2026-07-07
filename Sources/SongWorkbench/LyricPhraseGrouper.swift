import Foundation

/// Re-segments already-grouped lyric lines using the song's REPEATING bar-period phrase structure,
/// so verse/chorus lines read as musically even, bar-aligned phrases instead of purely following
/// ASR silence/capitalization cues (`TimedLyricSegmentGrouper`'s domain). Implements both phases
/// of the design in `.scratch/PRD-phrase-structure-lyric-grouper.md`: Stage 1 places each phrase
/// boundary at the nearest real word gap to `section start + k * period`; Stage 2 (§3.4) then
/// nudges that boundary to a nearby real word gap (via `RhymeSyllableScorer`) when doing so
/// produces a better end-rhyme + syllable-count match to the section's other phrase cells.
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
        /// Stage 2 (PRD §3.4) on/off switch. When `false`, behavior is exactly Stage 1 (nearest-
        /// in-time snap only) — kept as an explicit knob for rollback/testing, not because Stage 2
        /// is unsafe: it never moves a boundary further than `nudgeWindowInBeats`, never crosses a
        /// neighboring cell's fence, and only moves at all when scored strictly better (PRD §4
        /// guards all still apply; see `RhymeSyllableScorer`).
        var refinementEnabled: Bool
        /// How far from Stage 1's computed boundary (in beats) Stage 2 is allowed to search for a
        /// better-scoring real word gap. Bounded by `maxSnapDistance` regardless of this value.
        var nudgeWindowInBeats: Double
        /// Rhyme/syllable weighting + minimum-improvement threshold passed straight through to
        /// `RhymeSyllableScorer.selectBoundary`.
        var rhymeSyllableConfiguration: RhymeSyllableScorer.Configuration

        init(
            candidatePeriodsInBars: [Int] = [4, 8, 2],
            minimumConfidence: Double = 0.75,
            minimumFullPeriods: Int = 2,
            beatsPerBar: Int = 4,
            maximumLineDuration: TimeInterval = 15,
            maximumLineTokens: Int = 32,
            refinementEnabled: Bool = true,
            nudgeWindowInBeats: Double = 1,
            rhymeSyllableConfiguration: RhymeSyllableScorer.Configuration = .init()
        ) {
            self.candidatePeriodsInBars = candidatePeriodsInBars
            self.minimumConfidence = minimumConfidence
            self.minimumFullPeriods = max(minimumFullPeriods, 1)
            self.beatsPerBar = max(beatsPerBar, 1)
            self.maximumLineDuration = max(maximumLineDuration, 0)
            self.maximumLineTokens = max(maximumLineTokens, 1)
            self.refinementEnabled = refinementEnabled
            self.nudgeWindowInBeats = max(nudgeWindowInBeats, 0)
            self.rhymeSyllableConfiguration = rhymeSyllableConfiguration
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
        configuration: Configuration = .init(),
        rhymeDetector: RhymeDetector = .shared
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

        // Pools bar-label self-similarity evidence across EVERY occurrence of a section kind,
        // rather than requiring a single occurrence prove its own period alone — a section that
        // occurs only once (a lone Verse 2, most Bridges) can still borrow the phrase period its
        // sibling occurrences establish (Eric, 2026-07-07: "prioritize the music, the beat, the
        // rhythm, and the structure" — tasks/todo.md Task #39). `totalBars` (not the number of
        // lag-`period` test pairs) is what `minimumFullPeriods` gates, matching `detectPeriod`'s
        // original per-occurrence meaning exactly when a kind has only one occurrence — so this
        // is a strict generalization, not a behavior change, for any section without siblings.
        func pooledPeriod(indices: [Int]) -> (period: Int, confidence: Double)? {
            var best: (period: Int, confidence: Double)?
            for period in configuration.candidatePeriodsInBars {
                guard period > 0 else { continue }
                var matches = 0
                var total = 0
                var totalBars = 0
                for index in indices {
                    guard let barRange = sectionBarRange[index] else { continue }
                    let labels = barLabels(startDownbeat: barRange.start, endDownbeat: barRange.end)
                    totalBars += labels.count
                    guard labels.count > period else { continue }
                    for i in 0..<(labels.count - period) {
                        total += 1
                        if labels[i] == labels[i + period] { matches += 1 }
                    }
                }
                guard totalBars >= period * configuration.minimumFullPeriods, total > 0 else {
                    continue
                }
                let confidence = Double(matches) / Double(total)
                if best == nil || confidence > best!.confidence {
                    best = (period, confidence)
                }
            }
            return best
        }

        // Chorus occurrences must share ONE period so repeats stay structurally identical (PRD §4
        // chorus-determinism guard) — `SongStructureAnalyzer`'s word-set-Jaccard chorus detection
        // would otherwise silently regress if two occurrences of the same chorus re-segmented
        // differently due to beat-grid jitter between the two sung passes. Pooling naturally
        // satisfies this for BOTH kinds (every occurrence of a kind gets the same pooled
        // decision), so verse and chorus now share one code path instead of chorus alone getting
        // cross-occurrence sharing. Falls back to this occurrence's own single-occurrence
        // evidence when the pool doesn't reach confidence.
        var decisions: [Int: (period: Int, confidence: Double)?] = [:]
        for kind: SongStructureAnalyzer.SectionKind in [.verse, .chorus] {
            let indices = sections.indices.filter { sections[$0].kind == kind }
            guard !indices.isEmpty else { continue }
            let pooled = pooledPeriod(indices: indices)
            for index in indices {
                if let pooled, pooled.confidence >= configuration.minimumConfidence {
                    decisions[index] = pooled
                } else if let barRange = sectionBarRange[index] {
                    decisions[index] = detectPeriod(
                        startDownbeat: barRange.start, endDownbeat: barRange.end)
                }
            }
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
                    configuration: configuration, rhymeDetector: rhymeDetector))
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
    /// phrase boundary (`section start + k * period`, in bars), never mid-word — Stage 1. Stage 2
    /// (PRD §3.4) then nudges each of those boundaries to a nearby real word gap when it scores
    /// better on end-rhyme + syllable-count match to the section's OTHER cells (`RhymeSyllableScorer`),
    /// bounded so it can never cross into a neighboring cell (see the fence logic below). Only ever
    /// re-cuts at REAL existing silences between words already present — it cannot resurrect
    /// material an earlier gate removed, and it cannot re-merge words across a section boundary
    /// (`lines` here is always exactly one section's own lines). Falls back to `lines` unchanged
    /// whenever no safe cut is found, a section has no per-word data, or a resulting cell would
    /// violate the existing line-length caps.
    private static func resegmented(
        lines: [TimedLyricSegment], periodInBars: Int, barRange: (start: Int, end: Int),
        grid: MeasureGrid, configuration: Configuration, rhymeDetector: RhymeDetector
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

        func gapMidpoint(_ i: Int) -> TimeInterval { (words[i].end + words[i + 1].start) / 2 }

        func cellWords(from startExclusive: Int, through endInclusive: Int) -> ArraySlice<
            TimedLyricWord
        > {
            words[(startExclusive + 1)...endInclusive]
        }

        // Stage 1: snap each computed boundary to the nearest REAL inter-word gap (the midpoint
        // between two consecutive words), so a cut never lands mid-word. A boundary with no gap
        // within half a period of it is dropped — nothing there to cut at (e.g. a long melisma
        // spanning it).
        let periodSeconds = Double(periodInBeats) * grid.beatLength
        let maxSnapDistance = periodSeconds / 2
        var baselineIndices: [Int?] = []
        for boundary in boundaryTimes {
            var bestIndex: Int?
            var bestDistance = TimeInterval.infinity
            for i in 0..<(words.count - 1) {
                let distance = abs(gapMidpoint(i) - boundary)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = i
                }
            }
            baselineIndices.append(bestDistance <= maxSnapDistance ? bestIndex : nil)
        }
        guard baselineIndices.contains(where: { $0 != nil }) else { return lines }

        // Stage 2: nudge each baseline cut toward whichever nearby real word gap reads as the more
        // even phrase, using the OTHER already-placed cells (by baseline position) as the sibling
        // reference for end-rhyme + syllable-count similarity. Candidate search for boundary N is
        // strictly fenced between boundary (N-1)'s and (N+1)'s BASELINE cuts (never the post-nudge
        // value), which guarantees cells stay strictly ordered and non-overlapping no matter how
        // any individual boundary gets nudged.
        var finalIndices = baselineIndices
        if configuration.refinementEnabled, baselineIndices.compactMap({ $0 }).count >= 2 {
            // Every baseline cell, tagged with which boundary (if any) produced its cut. The
            // TRAILING cell — the words after the last real cut, running to the end of the
            // section's words — is never "produced" by any boundary (there's no cut after it), so
            // it's tagged `nil` and therefore always counts as a sibling for every boundary's own
            // decision (it is never the cell being decided). Without this, the last phrase in the
            // section would never inform any nudge decision, even though it's as much a sibling
            // line as any other.
            func allCellsWithProducingBoundary() -> [(
                ending: String, syllables: Int, boundary: Int?
            )] {
                var cells: [(ending: String, syllables: Int, boundary: Int?)] = []
                var previous = -1
                for (index, cut) in baselineIndices.enumerated() {
                    guard let cut else { continue }
                    let cell = cellWords(from: previous, through: cut)
                    cells.append(
                        (cell.last!.text, SyllableCounter.count(inWords: cell.map(\.text)), index))
                    previous = cut
                }
                if previous < words.count - 1 {
                    let trailing = cellWords(from: previous, through: words.count - 1)
                    cells.append(
                        (
                            trailing.last!.text,
                            SyllableCounter.count(inWords: trailing.map(\.text)), nil
                        ))
                }
                return cells
            }

            func siblingEndingsExcluding(_ skipBoundary: Int) -> (
                endings: [String], syllables: [Int]
            ) {
                let others = allCellsWithProducingBoundary().filter { $0.boundary != skipBoundary }
                return (others.map(\.ending), others.map(\.syllables))
            }

            let nudgeWindow = min(
                maxSnapDistance, configuration.nudgeWindowInBeats * grid.beatLength)
            var previousFence = -1
            for (boundaryIndex, boundary) in boundaryTimes.enumerated() {
                guard let baselineCut = baselineIndices[boundaryIndex] else { continue }
                defer { previousFence = baselineCut }
                let nextFence =
                    baselineIndices[(boundaryIndex + 1)...].compactMap { $0 }.first
                    ?? (words.count - 1)
                // No room between the fences to consider any alternative to the baseline cut.
                guard nextFence > previousFence + 1 else { continue }

                func candidate(at i: Int) -> RhymeSyllableScorer.Candidate {
                    let cell = cellWords(from: previousFence, through: i)
                    return RhymeSyllableScorer.Candidate(
                        wordIndex: i, endingWord: cell.last!.text,
                        syllableCount: SyllableCounter.count(inWords: cell.map(\.text)),
                        distanceFromComputedBoundary: abs(gapMidpoint(i) - boundary))
                }

                // The baseline cut is ALWAYS included, regardless of the nudge window — it is by
                // definition the globally-nearest gap, so it is always the minimum-distance
                // candidate and the scorer's safe fallback is always available.
                var candidates = [candidate(at: baselineCut)]
                for i in (previousFence + 1)..<nextFence
                where i != baselineCut && i < words.count - 1 {
                    guard abs(gapMidpoint(i) - boundary) <= nudgeWindow else { continue }
                    candidates.append(candidate(at: i))
                }

                let (endings, syllables) = siblingEndingsExcluding(boundaryIndex)
                if let chosen = RhymeSyllableScorer.selectBoundary(
                    among: candidates, siblingEndings: endings, siblingSyllableCounts: syllables,
                    rhymeDetector: rhymeDetector,
                    configuration: configuration.rhymeSyllableConfiguration)
                {
                    finalIndices[boundaryIndex] = chosen.wordIndex
                }
            }
        }

        let finalCutValues = finalIndices.compactMap { $0 }
        // Defensive safety net: Stage 2's fencing should make this unreachable, but if two nudged
        // boundaries ever collided or inverted order, fall back to the unmodified Stage 1 cuts
        // rather than emit a corrupted cut set.
        let collided =
            Set(finalCutValues).count != finalCutValues.count
            || zip(finalCutValues, finalCutValues.dropFirst()).contains { $0 >= $1 }
        let cutAfterWordIndices =
            collided ? Set(baselineIndices.compactMap { $0 }) : Set(finalCutValues)
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
