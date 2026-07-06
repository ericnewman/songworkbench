import Foundation

/// A line from one transcription mode's pass, pending clustering into a `LyricBlendRow`.
private struct Tagged {
    let mode: TranscriptionMode
    let segment: TimedLyricSegment
}

/// Builds `LyricBlendRow`s (backlog #11, Lyric Blending) from up to 3 independent transcription
/// passes of the same song — one per `TranscriptionMode` — by clustering their lines into
/// model-agnostic time windows. Pure & deterministic.
enum LyricBlendRowBuilder {
    /// Modes are stacked in this fixed order within a row's `candidates`, so the blend UI's
    /// column order (and any "prefer accuracy" fallback) is stable regardless of which modes
    /// happened to produce a candidate for a given row.
    static let modeOrder: [TranscriptionMode] = [.accuracy, .balancedDraft, .fastDraft]

    /// - Parameters:
    ///   - fastDraft/balancedDraft/accuracy: each mode's OWN already-grouped lines (post
    ///     `TimedLyricSegmentGrouper`), or empty if that mode wasn't run/installed.
    ///   - clusterWindow: lines starting within this many seconds of a row's anchor (its
    ///     earliest-starting line) join that row rather than starting a new one. 1.5s is
    ///     generous relative to typical sung-line lengths/gaps, so genuinely different lines from
    ///     two modes describing "the same moment" cluster together even with a couple hundred
    ///     milliseconds of onset disagreement between engines, while distinct sung lines a beat
    ///     or more apart still separate.
    /// - Returns: rows sorted by start time. Empty when all 3 inputs are empty.
    static func buildRows(
        fastDraft: [TimedLyricSegment],
        balancedDraft: [TimedLyricSegment],
        accuracy: [TimedLyricSegment],
        clusterWindow: TimeInterval = 1.5
    ) -> [LyricBlendRow] {
        let tagged =
            fastDraft.map { Tagged(mode: .fastDraft, segment: $0) }
            + balancedDraft.map { Tagged(mode: .balancedDraft, segment: $0) }
            + accuracy.map { Tagged(mode: .accuracy, segment: $0) }
        guard !tagged.isEmpty else { return [] }
        let sorted = tagged.sorted { $0.segment.start < $1.segment.start }

        // Greedily cluster by proximity to each row's ANCHOR (its first/earliest line), not by
        // chaining to the last-added line — chaining a long run of lines each within
        // `clusterWindow` of the previous one could drift a row's effective span far past the
        // window with no single pair ever exceeding it. Anchoring keeps every row's start/end
        // ties bounded to `clusterWindow` of where the row began.
        var clusters: [[Tagged]] = []
        for item in sorted {
            if let anchor = clusters.last?.first?.segment.start,
                item.segment.start - anchor <= clusterWindow
            {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }

        return mergeCrossModeDuplicates(clusters)
            .map(row(from:)).sorted { $0.start < $1.start }
    }

    /// Two engines can time the SAME sung line further apart than `clusterWindow` (e.g. Whisper
    /// de-padded a line to 20.26s where Parakeet heard 24.90s), splitting it into two rows —
    /// rendered as a duplicated lyric line the playback ball only tracks once (field report).
    /// Merge adjacent clusters when their mode sets are DISJOINT and their normalized texts
    /// match: a genuinely repeated hook line comes from the SAME mode twice (each pass hears
    /// both copies), so disjointness cleanly separates engine disagreement from real repeats.
    private static func mergeCrossModeDuplicates(
        _ clusters: [[Tagged]], mergeWindow: TimeInterval = 8
    ) -> [[Tagged]] {
        guard clusters.count > 1 else { return clusters }
        var result: [[Tagged]] = []
        for cluster in clusters {
            // Search EVERY earlier cluster still inside the merge window, not just the
            // immediately previous one: a mistimed engine's copy can land past an unrelated
            // line (field case: accuracy's "Grass between my toes" at 24.90s sat two rows
            // after the real 20.26s copy, with the "Smoke curls" row between them).
            var mergedIndex: Int?
            if let anchor = cluster.first?.segment.start,
                let texts = normalizedModeTexts(cluster)
            {
                for index in result.indices.reversed() {
                    guard let earlierAnchor = result[index].first?.segment.start,
                        anchor - earlierAnchor <= mergeWindow
                    else { break }
                    guard
                        Set(result[index].map(\.mode)).isDisjoint(with: cluster.map(\.mode)),
                        normalizedModeTexts(result[index]) == texts
                    else { continue }
                    mergedIndex = index
                    break
                }
            }
            if let mergedIndex {
                result[mergedIndex] += cluster
            } else {
                result.append(cluster)
            }
        }
        return result
    }

    /// The DISTINCT normalized texts a cluster's modes would each contribute as candidates
    /// (each mode's segments joined, per `row(from:)`). Two clusters are the same line when
    /// these sets match — comparing per mode, not a flat concatenation, because a cluster
    /// holding the same line from TWO modes would otherwise read as the text doubled and
    /// never match its single-mode duplicate (field case: {balanced, fast} "Grass…" cluster
    /// vs accuracy's stray copy). `nil` when no mode has any text, so blank clusters never
    /// merge with each other.
    private static func normalizedModeTexts(_ cluster: [Tagged]) -> Set<String>? {
        var byMode: [TranscriptionMode: [Tagged]] = [:]
        for item in cluster { byMode[item.mode, default: []].append(item) }
        var texts: Set<String> = []
        for items in byMode.values {
            let joined = items.sorted { $0.segment.start < $1.segment.start }
                .map(\.segment.text).joined(separator: " ")
            let normalized = joined.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !normalized.isEmpty { texts.insert(normalized) }
        }
        return texts.isEmpty ? nil : texts
    }

    private static func row(from cluster: [Tagged]) -> LyricBlendRow {
        var byMode: [TranscriptionMode: [TimedLyricSegment]] = [:]
        for item in cluster { byMode[item.mode, default: []].append(item.segment) }

        let candidates: [LyricBlendCandidate] = modeOrder.compactMap { mode in
            guard let segments = byMode[mode]?.sorted(by: { $0.start < $1.start }) else {
                return nil
            }
            return LyricBlendCandidate(
                mode: mode,
                text: segments.map(\.text).joined(separator: " "),
                words: segments.flatMap(\.words))
        }
        let start = cluster.map(\.segment.start).min() ?? 0
        let end = cluster.map(\.segment.end).max() ?? start
        return LyricBlendRow(start: start, end: end, candidates: candidates, selectedMode: nil)
    }

    /// The "official" lyric lines implied by the CURRENT state of `rows` — each row's manual
    /// `overrideText` if set, else its `effectiveCandidate`, becomes one `TimedLyricSegment`. A
    /// candidate's own per-word timings are used so playback highlighting stays accurate to
    /// whichever mode's line won; an override has no per-word data of its own, so its segment
    /// gets no `words` (playback falls back to interpolation across the row's span, same as any
    /// other manually-typed/edited lyric line). This is what `AppModel` writes back to
    /// `document.lyrics` after every blend pick or override edit (and right after the 3 passes
    /// first complete, before the user has picked anything).
    static func effectiveLyrics(from rows: [LyricBlendRow]) -> [TimedLyricSegment] {
        rows.compactMap { row -> TimedLyricSegment? in
            if let overrideText = row.overrideText {
                let trimmed = overrideText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return TimedLyricSegment(start: row.start, end: row.end, text: trimmed)
                }
            }
            guard let candidate = row.effectiveCandidate() else { return nil }
            return TimedLyricSegment(
                start: row.start, end: row.end, text: candidate.text, words: candidate.words)
        }.sorted { $0.start < $1.start }
    }

    // MARK: - Vocal-onset corroboration (the stem waveform is ground truth for word placement)

    /// Fraction of `words` whose onset lands within `tolerance` of a vocal-stem energy onset.
    /// The vocal stem is the ground truth for WHERE words go (Eric's invariant: every sung
    /// burst ↔ a word): a candidate whose word onsets sit on real bursts is timed correctly;
    /// one whose words float in silence is padded/misplaced ASR timing.
    static func onsetCorroboration(
        words: [TimedLyricWord], vocalOnsets: [TimeInterval], tolerance: TimeInterval = 0.18
    ) -> Double {
        guard !words.isEmpty, !vocalOnsets.isEmpty else { return 0 }
        let sorted = vocalOnsets.sorted()
        var hits = 0
        for word in words {
            var low = 0
            var high = sorted.count - 1
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] < word.start { low = mid + 1 } else { high = mid }
            }
            var nearest = abs(sorted[low] - word.start)
            if low > 0 { nearest = min(nearest, abs(sorted[low - 1] - word.start)) }
            if nearest <= tolerance { hits += 1 }
        }
        return Double(hits) / Double(words.count)
    }

    /// The mode whose candidate the vocal stem corroborates CLEARLY better than the default
    /// preference-order pick, for a row the user hasn't chosen yet — or `nil` to keep the
    /// default. Deliberately conservative: only flips when the winner beats the default's
    /// score by `minimumMargin`, so ties and noise never override the accuracy-first default,
    /// and a user's explicit `selectedMode` is never touched.
    static func onsetPreferredMode(
        for row: LyricBlendRow,
        vocalOnsets: [TimeInterval],
        tolerance: TimeInterval = 0.18,
        minimumMargin: Double = 0.25
    ) -> TranscriptionMode? {
        guard row.selectedMode == nil, row.candidates.count > 1, !vocalOnsets.isEmpty,
            let defaultCandidate = row.effectiveCandidate()
        else { return nil }
        let scores = row.candidates.map { candidate in
            (
                mode: candidate.mode,
                score: onsetCorroboration(
                    words: candidate.words, vocalOnsets: vocalOnsets, tolerance: tolerance)
            )
        }
        guard let best = scores.max(by: { $0.score < $1.score }) else { return nil }
        let defaultScore = scores.first(where: { $0.mode == defaultCandidate.mode })?.score ?? 0
        guard best.mode != defaultCandidate.mode, best.score >= defaultScore + minimumMargin
        else { return nil }
        return best.mode
    }

    /// Applies `onsetPreferredMode` across `rows`: fills `selectedMode` ONLY on rows the user
    /// hasn't picked, where the stem clearly corroborates a non-default candidate. Run AFTER
    /// `reconciled` so user picks are already in place and are never overwritten.
    static func onsetCorroborated(
        _ rows: [LyricBlendRow], vocalOnsets: [TimeInterval]
    ) -> [LyricBlendRow] {
        guard !vocalOnsets.isEmpty else { return rows }
        return rows.map { row in
            guard let preferred = onsetPreferredMode(for: row, vocalOnsets: vocalOnsets) else {
                return row
            }
            var updated = row
            updated.selectedMode = preferred
            return updated
        }
    }

    /// Demotes a default candidate that RUNS TWO LINES TOGETHER: when one mode's candidate
    /// reads as a neighbouring row's line plus another candidate's line (in either order),
    /// the run-on is a timing artifact — that mode heard both phrases as one segment — and
    /// the split candidate is the real line (field cases: "Smoke curls… Laughter floats…"
    /// and "She makes me want to settle down, trading my rowdy friends…"). Matching is
    /// TOKEN-SIMILARITY based, not exact: engines legitimately disagree on wording ("wanna"
    /// vs "want to", "one horse" vs "one-horse"), and a neighbour's candidate can itself be
    /// contaminated with extra words. Only rows without a user pick change, and both halves
    /// must match strongly, so genuine long lines stay.
    static func runOnDuplicatesDemoted(
        _ rows: [LyricBlendRow], minimumSimilarity: Double = 0.7
    ) -> [LyricBlendRow] {
        guard rows.count > 1 else { return rows }
        return rows.indices.map { index in
            let row = rows[index]
            guard row.selectedMode == nil, row.candidates.count > 1,
                let defaultCandidate = row.effectiveCandidate()
            else { return row }
            let defaultTokens = tokens(defaultCandidate.text)
            guard defaultTokens.count >= 4 else { return row }
            var neighbourTokenLists: [[String]] = []
            for neighbour in [index - 1, index + 1] where rows.indices.contains(neighbour) {
                for candidate in rows[neighbour].candidates {
                    let list = tokens(candidate.text)
                    if list.count >= 2 { neighbourTokenLists.append(list) }
                }
            }
            for candidate in row.candidates where candidate.mode != defaultCandidate.mode {
                let candidateTokens = tokens(candidate.text)
                guard candidateTokens.count >= 2 else { continue }
                let isRunOn = neighbourTokenLists.contains { neighbour in
                    splitsInto(
                        defaultTokens, half: candidateTokens, otherHalf: neighbour,
                        minimumSimilarity: minimumSimilarity)
                }
                if isRunOn {
                    var updated = row
                    updated.selectedMode = candidate.mode
                    return updated
                }
            }
            return row
        }
    }

    /// True when `whole` can split at some boundary so one side matches `half` and the other
    /// matches `otherHalf` (either order), each at `minimumSimilarity` token similarity.
    private static func splitsInto(
        _ whole: [String], half: [String], otherHalf: [String], minimumSimilarity: Double
    ) -> Bool {
        for boundary in 2...(whole.count - 2) where whole.count >= 4 {
            let left = Array(whole[..<boundary])
            let right = Array(whole[boundary...])
            let straight = min(
                tokenSimilarity(left, half), tokenSimilarity(right, otherHalf))
            let crossed = min(
                tokenSimilarity(left, otherHalf), tokenSimilarity(right, half))
            if max(straight, crossed) >= minimumSimilarity { return true }
        }
        return false
    }

    /// Longest-common-subsequence ratio over token lists, in `[0, 1]`.
    private static func tokenSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] =
                    a[i - 1] == b[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return Double(table[a.count][b.count]) / Double(max(a.count, b.count))
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Carries a user's `overrideText` and `selectedMode` forward from `oldRows` onto whichever
    /// `newRows` occupies the same time window, so a manual correction (or a blend pick) survives
    /// a fresh transcription pass rebuilding the rows from scratch — without this, every
    /// re-analysis would silently discard both, since `buildRows` always starts from a clean
    /// slate. Matched by the greatest time-window OVERLAP; if a boundary shifted just enough that
    /// no row truly overlaps, falls back to the closest start time within a tight tolerance so
    /// unrelated rows never match. A new row with nothing close enough in `oldRows` (e.g. its
    /// section didn't exist before) is left exactly as freshly built.
    static func reconciled(
        newRows: [LyricBlendRow], against oldRows: [LyricBlendRow]
    ) -> [LyricBlendRow] {
        guard !oldRows.isEmpty else { return newRows }
        return newRows.map { newRow in
            guard let match = bestMatchingRow(for: newRow, in: oldRows) else { return newRow }
            var reconciledRow = newRow
            if let overrideText = match.overrideText,
                !overrideText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                reconciledRow.overrideText = overrideText
            }
            if let selectedMode = match.selectedMode {
                reconciledRow.selectedMode = selectedMode
            }
            return reconciledRow
        }
    }

    /// The old row whose `[start, end]` window overlaps `newRow`'s the most, or — if none
    /// actually overlap — the closest by start time within 0.75s (a re-transcription can nudge a
    /// line's boundaries by a fraction of a second without it being a different line). `nil` when
    /// nothing old is close enough to confidently be "the same" line.
    private static func bestMatchingRow(
        for newRow: LyricBlendRow, in oldRows: [LyricBlendRow]
    ) -> LyricBlendRow? {
        let overlapping = oldRows.compactMap {
            old -> (row: LyricBlendRow, overlap: TimeInterval)? in
            let overlapStart = max(old.start, newRow.start)
            let overlapEnd = min(old.end, newRow.end)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { return nil }
            return (old, overlap)
        }
        if let best = overlapping.max(by: { $0.overlap < $1.overlap }) { return best.row }

        guard
            let closest = oldRows.min(by: {
                abs($0.start - newRow.start) < abs($1.start - newRow.start)
            }),
            abs(closest.start - newRow.start) <= 0.75
        else { return nil }
        return closest
    }
}
