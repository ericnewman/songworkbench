import Foundation

/// Re-cuts already-grouped lyric lines so each one spans a whole number of PHRASE PERIODS, using
/// only the song's measured period `P` (`SongBeatsPerLine.estimate`) and the REAL inter-word gaps
/// inside the lines themselves.
///
/// ## Why this is not the previous attempt
///
/// `LyricPhraseGrouper` tried the same goal from chord-label autocorrelation and was measured to
/// fire on ZERO real songs (confidence 0.09–0.29 against a 0.75 gate). Nothing here reads chords.
/// The only period evidence is line inter-onset periodicity, which `SongBeatsPerLine` already
/// recovers reliably (8.01/8.00 beats on the two clean songs).
///
/// ## Period only — no downbeat phase
///
/// Every cut target is `this line's OWN measured onset + k · P`, never an absolute grid time.
/// Phase was measured unrecoverable on 2026-08-01 (slot boundaries near a real inter-word gap
/// maxed at 53% against a 70% gate; on the cleanest song only 10 of 33 line starts sat within
/// 0.35 s of a slot). A target is then SNAPPED to a real measured inter-word gap and the cut is
/// abandoned outright when no genuine gap sits near it — a grid-quantised time would make every
/// later comparison circular (Eric's standing rule).
///
/// ## Derived on load, never persisted
///
/// Runs as a pure post-pass in `AppModel.applyAnalysis` over the STORED lyrics, exactly like
/// `TimedLyricSegmentGrouper.regroup` and `LyricPhraseGrouper.regroup`. It never writes back into
/// the field it reads: a load-time pass that does is a feedback loop, and that exact mistake made
/// one song's tempo walk 101.3 → 152.0 → 81.1 across reloads (tasks/lessons.md, 2026-08-05).
///
/// ## Per-song accept gate
///
/// The whole re-cut is discarded — the song's lines left byte-identical — unless it measurably
/// improves the song against the SAME yardstick (`P` and beat length from the lines as they stood
/// BEFORE the re-cut, so the metric cannot drift under the comparison).
enum PhrasePeriodLineRecutter {
    struct Configuration: Equatable, Sendable {
        /// A line whose own word span exceeds this many periods is a split candidate.
        var splitThreshold: Double
        /// A line whose onset-to-next-onset interval falls below this many periods is a merge
        /// candidate.
        var mergeThreshold: Double
        /// A merge is refused when the combined line would span more than this many periods —
        /// trading a short outlier for a long one is not an improvement.
        var maximumMergedSpan: Double
        /// How far either side of `onset + k · P` (in periods) a real gap may sit and still be
        /// accepted as that boundary's cut.
        var searchWindowInPeriods: Double
        /// Absolute floor on what counts as a gap at all, in seconds.
        var minimumGapSeconds: TimeInterval
        /// …and it must also be this many times the line's own MEDIAN inter-word gap, so
        /// "a gap" always means "wide relative to how this particular line is sung".
        var gapProminence: Double
        /// Same caps `TimedLyricGroupingConfiguration` and `LyricPhraseGrouper` use.
        var maximumLineDuration: TimeInterval
        var maximumLineTokens: Int
        /// A cut is refused when it would leave a tail shorter than this many periods — a sliver
        /// row is a worse defect than the over-long row it came from.
        var minimumPieceInPeriods: Double
        /// Bound on split recursion, so a pathological line cannot spin.
        var maximumSplitDepth: Int
        /// Allow an interior RHYME to license a cut whose gap is too narrow on its own. The
        /// metrical requirement is unchanged either way — see `cutIndex`.
        var rhymeLicenceEnabled: Bool = true
        /// Merge passes are re-run until they reach a fixpoint, at most this many times.
        var maximumMergePasses: Int
        /// A re-cut that leaves the outlier rate unchanged is still accepted when it flattens the
        /// row-width spread by at least this much (absolute drop in max/median).
        var minimumRatioImprovement: Double

        init(
            splitThreshold: Double = 1.5,
            mergeThreshold: Double = 0.75,
            maximumMergedSpan: Double = 1.5,
            searchWindowInPeriods: Double = 0.35,
            minimumGapSeconds: TimeInterval = 0.08,
            gapProminence: Double = 1.5,
            maximumLineDuration: TimeInterval = 15,
            maximumLineTokens: Int = 32,
            minimumPieceInPeriods: Double = 0.4,
            maximumSplitDepth: Int = 4,
            maximumMergePasses: Int = 4,
            minimumRatioImprovement: Double = 0.05
        ) {
            self.splitThreshold = max(splitThreshold, 1.05)
            self.mergeThreshold = min(max(mergeThreshold, 0), 0.95)
            self.maximumMergedSpan = max(maximumMergedSpan, 1.0)
            self.searchWindowInPeriods = min(max(searchWindowInPeriods, 0), 0.5)
            self.minimumGapSeconds = max(minimumGapSeconds, 0)
            self.gapProminence = max(gapProminence, 1)
            self.maximumLineDuration = max(maximumLineDuration, 0)
            self.maximumLineTokens = max(maximumLineTokens, 1)
            self.minimumPieceInPeriods = max(minimumPieceInPeriods, 0)
            self.maximumSplitDepth = max(maximumSplitDepth, 0)
            self.maximumMergePasses = max(maximumMergePasses, 1)
            self.minimumRatioImprovement = max(minimumRatioImprovement, 0)
        }
    }

    /// What the pass did to one song. Diagnostic only — nothing is persisted.
    struct Report: Equatable, Sendable {
        let beatsPerLine: Int
        let beatLength: TimeInterval
        let splits: Int
        let merges: Int
        let outlierRateBefore: Double
        let outlierRateAfter: Double
        /// Ratio of the widest to the median line WORD SPAN — the row-width spread the chart shows.
        let spanRatioBefore: Double
        let spanRatioAfter: Double
        /// Lines whose extent exceeded `splitThreshold`, and how many of those were left alone
        /// because no real gap sat near any `k · P` target. A high blocked count is the honest
        /// signal that the lines are legato through the boundary, not that the rule is too timid.
        let splitCandidates: Int
        let splitBlocked: SplitTally
        /// False when the gate rejected the re-cut and the caller got its input back verbatim.
        let accepted: Bool
    }

    /// Re-cuts `lyrics` onto the song's phrase period. Returns `lyrics` completely unchanged when
    /// there is no period to work from, when nothing needs re-cutting, or when the accept gate
    /// rejects the result.
    static func recut(
        _ lyrics: [TimedLyricSegment],
        beatTimes: [TimeInterval],
        tempo: Double?,
        configuration: Configuration = .init(),
        detector: RhymeDetector = .shared
    ) -> [TimedLyricSegment] {
        recutReporting(
            lyrics, beatTimes: beatTimes, tempo: tempo, configuration: configuration,
            detector: detector
        ).lines
    }

    /// Same as `recut`, plus the measurements behind the decision. Split out so the diagnostic
    /// harness can report before/after numbers without duplicating any of the logic it verifies.
    /// `detector` is injectable because `RhymeDetector.shared` loads an empty vocabulary under
    /// `swift test` — a test that relies on the shared instance silently exercises no rhyme at all.
    static func recutReporting(
        _ lyrics: [TimedLyricSegment],
        beatTimes: [TimeInterval],
        tempo: Double?,
        configuration: Configuration = .init(),
        detector: RhymeDetector = .shared
    ) -> (lines: [TimedLyricSegment], report: Report?) {
        guard let bpm = tempo, bpm > 0, lyrics.count >= 2 else { return (lyrics, nil) }
        let sorted = lyrics.sorted { $0.start < $1.start }
        guard
            let beatLength = MetricalLevelReconciler.medianBeatLength(
                beatTimes: beatTimes, bpm: bpm), beatLength > 0,
            let fit = SongBeatsPerLine.estimate(
                beatTimes: beatTimes, bpm: bpm, lineOnsets: sorted.map(\.start))
        else { return (lyrics, nil) }

        let period = Double(fit.beatsPerLine) * beatLength
        guard period > 0 else { return (lyrics, nil) }

        var splits = 0
        var tally = SplitTally()
        var afterSplit: [TimedLyricSegment] = []
        for (index, line) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].start : nil
            // The surrounding rhyme SCHEME: the endings of the lines either side. A word inside
            // an over-long line that rhymes with them is very likely the end of a hidden line.
            let neighbours = [index - 1, index + 1]
                .filter { $0 >= 0 && $0 < sorted.count }
                .compactMap { sorted[$0].words.last?.text }
            let parts = splitParts(
                of: line, nextOnset: next, period: period, configuration: configuration,
                tally: &tally, rhymeTargets: neighbours, detector: detector)
            splits += parts.count - 1
            afterSplit.append(contentsOf: parts)
        }

        var merges = 0
        let afterMerge = mergedToFixpoint(
            afterSplit, period: period, configuration: configuration, merges: &merges)

        let changed = (splits > 0 || merges > 0) && afterMerge != sorted

        // Same yardstick on both sides: `P` and the beat length are the ones the lines had BEFORE
        // the re-cut, so the gate cannot be satisfied by the metric moving rather than the lines
        // improving.
        let before = SongBeatsPerLine.measure(
            lineOnsets: sorted.map(\.start), beatsPerLine: fit.beatsPerLine,
            beatLength: beatLength)
        let after = SongBeatsPerLine.measure(
            lineOnsets: afterMerge.map(\.start), beatsPerLine: fit.beatsPerLine,
            beatLength: beatLength)
        let outlierBefore = SongBeatsPerLine.outlierRate(before)
        let outlierAfter = SongBeatsPerLine.outlierRate(after)
        let ratioBefore = spanRatio(sorted)
        let ratioAfter = spanRatio(afterMerge)

        let epsilon = 1e-9
        let accepted =
            changed
            && (outlierAfter < outlierBefore - epsilon
                || (outlierAfter <= outlierBefore + epsilon
                    && ratioAfter <= ratioBefore - configuration.minimumRatioImprovement))

        let report = Report(
            beatsPerLine: fit.beatsPerLine, beatLength: beatLength, splits: splits, merges: merges,
            outlierRateBefore: outlierBefore, outlierRateAfter: outlierAfter,
            spanRatioBefore: ratioBefore, spanRatioAfter: ratioAfter,
            splitCandidates: tally.candidates, splitBlocked: tally, accepted: accepted)
        return (accepted ? afterMerge : lyrics, report)
    }

    // MARK: - Off-grid accounting

    /// Whether an interval of `periods` phrase periods is an OUTLIER, using exactly the
    /// classification `SongBeatsPerLine.measure` applies — a section break is not scored at all,
    /// and any WHOLE multiple within tolerance is on-grid (a deliberate two-phrase line is
    /// correct). Sourced from `SongBeatsPerLine.Configuration` so there is one definition, not a
    /// copy that can drift away from the metric this pass is judged by.
    private static func isOutlier(
        _ periods: Double, gridding: SongBeatsPerLine.Configuration = .init()
    ) -> Bool {
        guard periods > 0, periods < gridding.sectionBreakThreshold else { return false }
        return abs(periods - max(1.0, periods.rounded())) > gridding.tolerance
    }

    private static func cost(_ periods: Double) -> Int { isOutlier(periods) ? 1 : 0 }

    // MARK: - Split

    /// Cuts one over-long line into whole-period parts, or returns it untouched.
    ///
    /// Targets are `this line's OWN measured onset + k · P` — never an absolute grid time, because
    /// downbeat phase is unrecoverable (see the type doc). `k` walks upward because a melisma can
    /// straddle the first boundary with no gap to cut at; a two-period head is still a whole
    /// number of periods, so it is a legitimate outcome rather than a compromise. The recursion
    /// re-anchors on the measured onset of the word that actually starts the tail, so a drifting
    /// tempo does not accumulate error across a long line.
    ///
    /// A candidate cut is only taken when it does not INCREASE the number of off-grid intervals it
    /// is judged by. Because a split always adds one interval to the denominator, that makes every
    /// accepted cut a strict improvement in outlier RATE — the pass cannot trade the metric for
    /// tidier-looking rows.
    private static func splitParts(
        of line: TimedLyricSegment, nextOnset: TimeInterval?, period: Double,
        configuration: Configuration, tally: inout SplitTally,
        rhymeTargets: [String] = [], detector: RhymeDetector = .shared, depth: Int = 0
    ) -> [TimedLyricSegment] {
        let words = line.words.sorted { $0.start < $1.start }
        guard depth < configuration.maximumSplitDepth, words.count >= 2 else { return [line] }
        let origin = words[0].start
        let ownEnd = words[words.count - 1].end
        // A line whose successor is a whole section away is measured by its OWN word span: that
        // interval is dominated by silence, and the row's width is what a cut can actually change.
        let gridding = SongBeatsPerLine.Configuration()
        let toNext = (nextOnset ?? ownEnd) - origin
        let extentEnd =
            toNext / period >= gridding.sectionBreakThreshold ? ownEnd : (nextOnset ?? ownEnd)
        let extent = extentEnd - origin
        // Candidacy is decided by the line's OWN word span — that is the row width the chart
        // draws, and it is the only part a cut can change. An interval inflated by the silence
        // AFTER the last word is a gap in the song, not an over-long line, and no cut fixes it.
        guard ownEnd - origin > configuration.splitThreshold * period else { return [line] }
        tally.candidates += 1

        let beforeCost = cost(extent / period)
        let maximumK = max(1, Int((extent / period).rounded()) - 1)
        var sawBoundary = false
        var sawGap = false
        for k in 1...maximumK {
            // The line's own last word first, then the neighbours' endings — a couplet inside
            // the line is the strongest tell, the surrounding scheme the next.
            let targets =
                configuration.rhymeLicenceEnabled
                ? ([words[words.count - 1].text] + rhymeTargets) : []
            let probe = cutIndex(
                in: words, target: origin + Double(k) * period, configuration: configuration,
                period: period, rhymeTargets: targets, detector: detector)
            sawBoundary = sawBoundary || probe.hadBoundaryInWindow
            sawGap = sawGap || probe.index != nil
            guard let cut = probe.index else { continue }
            let cutTime = words[cut + 1].start
            let head = (cutTime - origin) / period
            let tail = (extentEnd - cutTime) / period
            // The head must land ON a whole multiple — that is the entire point of the cut — and
            // the pair must not cost more off-grid intervals than the uncut line did.
            guard tail >= configuration.minimumPieceInPeriods, cost(head) == 0,
                cost(head) + cost(tail) <= beforeCost
            else { continue }
            let headWords = Array(words[0...cut])
            let tailWords = Array(words[(cut + 1)...])
            guard fitsCaps(headWords, configuration: configuration) else { continue }
            if probe.licensedByRhyme { tally.splitByRhyme += 1 }
            return [segment(from: headWords)]
                + splitParts(
                    of: segment(from: tailWords), nextOnset: nextOnset, period: period,
                    configuration: configuration, tally: &tally,
                    rhymeTargets: rhymeTargets, detector: detector, depth: depth + 1)
        }
        tally.blocked += 1
        if !sawBoundary {
            tally.blockedNoBoundary += 1
        } else if !sawGap {
            tally.blockedGapTooNarrow += 1
        } else {
            tally.blockedCost += 1
        }
        return [line]
    }

    /// Diagnostic-only counters for how many over-long lines were seen versus left alone, and why.
    struct SplitTally: Equatable, Sendable {
        var candidates = 0
        /// Cuts that only happened because an interior word rhymed — the gap alone was too narrow.
        var splitByRhyme = 0
        var blocked = 0
        /// No word boundary at all fell inside any `k · P` search window (a melisma or a single
        /// long token straddling the boundary).
        var blockedNoBoundary = 0
        /// Word boundaries were there, but none was a wide enough gap to cut at.
        var blockedGapTooNarrow = 0
        /// A gap was available, but cutting there would not have paid for itself.
        var blockedCost = 0
    }

    /// Index of the word to cut AFTER: the WIDEST real inter-word gap within the search window of
    /// `target`, ties broken toward the gap nearest it. Returns `nil` when no gap in the window is
    /// genuinely a gap — in which case nothing is cut at all, rather than a cut being placed at a
    /// derived time. "Genuinely a gap" is judged against the line's OWN median inter-word spacing,
    /// so it means wide for the way this particular line is sung, not wide in the abstract.
    private static func cutIndex(
        in words: [TimedLyricWord], target: TimeInterval, configuration: Configuration,
        period: Double, rhymeTargets: [String], detector: RhymeDetector
    ) -> (index: Int?, hadBoundaryInWindow: Bool, licensedByRhyme: Bool) {
        let gaps = (0..<(words.count - 1)).map { words[$0 + 1].start - words[$0].end }
        // Measured across the five live songs (2026-08-07, 1223 inter-word gaps): the MEDIAN gap
        // inside a line is 0.000 s and the upper quartile ≈0.05 s — words inside a sung phrase are
        // reported back to back — while p90 ≈ 0.12 s and the tail runs to 1.5 s. So on ordinary
        // lines the ABSOLUTE floor is what binds, and the relative term only has teeth on a line
        // whose spacing is genuinely wide throughout (a slow, spread-out delivery), where 0.08 s
        // would no longer mean anything. Making the relative term p75-based instead was tried and
        // measured WORSE (splits 7 -> 5 across the corpus, Doc Holiday's span ratio 2.32 -> 2.49):
        // it penalises exactly the slow lines that do have real gaps to cut at.
        guard let typical = median(gaps.filter { $0 >= 0 }) else { return (nil, false, false) }
        let floorGap = max(configuration.minimumGapSeconds, configuration.gapProminence * typical)
        let window = configuration.searchWindowInPeriods * period
        var best: (index: Int, gap: Double, distance: Double)?
        var hadBoundary = false
        for index in gaps.indices {
            let midpoint = (words[index].end + words[index + 1].start) / 2
            let distance = abs(midpoint - target)
            guard distance <= window else { continue }
            hadBoundary = true
            guard gaps[index] >= floorGap else { continue }
            if best == nil || gaps[index] > best!.gap
                || (gaps[index] == best!.gap && distance < best!.distance)
            {
                best = (index, gaps[index], distance)
            }
        }
        if let best { return (best.index, hadBoundary, false) }
        // RHYME LICENCE. No gap in this window is wide enough — but a line that rhymes at an
        // interior word is telling us a line ENDS there regardless of whether the singer paused.
        // This relaxes ONLY the gap floor; the caller still requires the head to land on a whole
        // multiple of the period and to not increase the outlier cost, so a rhyme can never buy a
        // metrically wrong cut. That pairing is the measured design: across the live songs an
        // internal rhyme was present in 40-50% of over-long lines, and where present it agreed
        // with a k*P boundary about 9 times in 10 — two independent signals (lexical and
        // metrical) concurring, which neither can fake alone.
        guard !rhymeTargets.isEmpty else { return (nil, hadBoundary, false) }
        var rhymed: (index: Int, distance: Double)?
        for index in gaps.indices {
            let midpoint = (words[index].end + words[index + 1].start) / 2
            let distance = abs(midpoint - target)
            guard distance <= window else { continue }
            guard
                detector.rhymes(words[index].text, rhymeTargets.first ?? "")
                    || rhymeTargets.dropFirst().contains(where: {
                        detector.rhymes(words[index].text, $0)
                    })
            else { continue }
            if rhymed == nil || distance < rhymed!.distance { rhymed = (index, distance) }
        }
        return (rhymed?.index, hadBoundary, rhymed != nil)
    }

    // MARK: - Merge

    private static func mergedToFixpoint(
        _ lines: [TimedLyricSegment], period: Double, configuration: Configuration,
        merges: inout Int
    ) -> [TimedLyricSegment] {
        var current = lines
        for _ in 0..<configuration.maximumMergePasses {
            var pass = 0
            let next = mergedOnce(
                current, period: period, configuration: configuration, merges: &pass)
            merges += pass
            if pass == 0 { break }
            current = next
        }
        return current
    }

    /// One greedy left-to-right merge pass. A too-short line is folded FORWARD into its successor,
    /// or failing that BACKWARD into the line already emitted, and only when doing so strictly
    /// reduces the off-grid interval count — a merge removes an interval from the denominator, so
    /// requiring the numerator to drop too keeps the outlier rate monotonically improving.
    ///
    /// A `.sectionBreak` interval is never crossed in either direction: that gap is silence
    /// between sections, not a mis-split line.
    private static func mergedOnce(
        _ lines: [TimedLyricSegment], period: Double, configuration: Configuration,
        merges: inout Int
    ) -> [TimedLyricSegment] {
        guard lines.count >= 2 else { return lines }
        // Periods spanned by the interval starting at each line. The last line has no successor,
        // so its own word end stands in — it is not scored by `SongBeatsPerLine.measure` either
        // way, but it still decides whether a trailing fragment should be absorbed.
        func periods(from index: Int, to endIndex: Int) -> Double {
            let end =
                endIndex < lines.count ? lines[endIndex].start : lines[lines.count - 1].end
            return (end - lines[index].start) / period
        }
        let gridding = SongBeatsPerLine.Configuration()

        var result: [TimedLyricSegment] = []
        var index = 0
        while index < lines.count {
            let own = periods(from: index, to: index + 1)
            guard index + 1 < lines.count, own < configuration.mergeThreshold,
                own < gridding.sectionBreakThreshold
            else {
                result.append(lines[index])
                index += 1
                continue
            }
            let successor = periods(from: index + 1, to: index + 2)
            let forward = own + successor
            let forwardWords = lines[index].words + lines[index + 1].words
            if forward <= configuration.maximumMergedSpan,
                cost(forward) < cost(own) + cost(successor),
                fitsCaps(forwardWords, configuration: configuration)
            {
                result.append(segment(from: forwardWords))
                merges += 1
                index += 2
                continue
            }
            // Backward fallback: the short line's own successor is too far away to absorb it, so
            // try the line already emitted instead.
            if let previous = result.last {
                let previousPeriods = (lines[index].start - previous.start) / period
                let backward = previousPeriods + own
                let backwardWords = previous.words + lines[index].words
                if previousPeriods < gridding.sectionBreakThreshold,
                    backward <= configuration.maximumMergedSpan,
                    cost(backward) < cost(previousPeriods) + cost(own),
                    fitsCaps(backwardWords, configuration: configuration)
                {
                    result[result.count - 1] = segment(from: backwardWords)
                    merges += 1
                    index += 1
                    continue
                }
            }
            result.append(lines[index])
            index += 1
        }
        return result
    }

    // MARK: - Helpers

    private static func fitsCaps(_ words: [TimedLyricWord], configuration: Configuration) -> Bool {
        guard let first = words.first, let last = words.last else { return false }
        return last.end - first.start <= configuration.maximumLineDuration
            && words.count <= configuration.maximumLineTokens
    }

    /// Widest ÷ median line WORD SPAN. This is the row-width spread the chart actually draws, and
    /// it is measured from word times rather than the segment's `start`/`end` so a line with a
    /// long trailing silence is not counted as a wide row.
    static func spanRatio(_ lines: [TimedLyricSegment]) -> Double {
        let spans = lines.compactMap { line -> Double? in
            guard let first = line.words.first, let last = line.words.last else { return nil }
            let span = last.end - first.start
            return span > 0 ? span : nil
        }
        guard spans.count >= 2, let middle = median(spans), middle > 0,
            let widest = spans.max()
        else { return 1 }
        return widest / middle
    }

    /// Same "join words with a single space, recompute character ranges" convention
    /// `LyricPhraseGrouper.segment(from:)` and `AudioFileAnalysisService.lyricSegment(from:)` use.
    private static func segment(from words: [TimedLyricWord]) -> TimedLyricSegment {
        var text = ""
        var rebuilt: [TimedLyricWord] = []
        // Sorted defensively: a merge concatenates two lines' word lists, and cached documents do
        // contain OVERLAPPING segments (the 2026-07-31 Doc Holiday defect), so concatenation alone
        // could otherwise emit a line whose words run backwards.
        for word in words.sorted(by: { $0.start < $1.start }) {
            if !text.isEmpty { text += " " }
            let lower = text.count
            text += word.text
            rebuilt.append(
                TimedLyricWord(
                    text: word.text, start: word.start, end: word.end,
                    characterRange: lower..<text.count, confidence: word.confidence))
        }
        return TimedLyricSegment(
            start: rebuilt.first?.start ?? 0, end: rebuilt.map(\.end).max() ?? 0, text: text,
            words: rebuilt)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
