import Foundation

/// One generated lyric line set against its best-matching reference line.
struct ReferenceLineDiff: Equatable, Sendable, Identifiable {
    var id: Int { generatedLineIndex }
    let generatedLineIndex: Int
    let lyric: String
    /// Chord names as the reference chart writes them, in line order.
    let referenceChords: [String]
    /// Chord names as the generated chart writes them, in line order.
    let generatedChords: [String]
    /// Aligned chord pairs whose roots agree (after global transposition compensation).
    let rootMatches: Int
    /// Aligned pairs (min of the two counts, via longest-common-subsequence on roots).
    let alignedCount: Int
}

/// What a reference chart says about the generated one — per-line diffs plus the systemic
/// patterns a single bad chord can't show: a constant transposition offset, a density mismatch
/// (over/under-segmentation), and quality collapse (right root, wrong suffix, consistently).
struct ReferenceChartComparison: Equatable, Sendable {
    let lineDiffs: [ReferenceLineDiff]
    /// Reference lyric lines that matched no generated line (usually segmentation issues).
    let unmatchedReferenceLines: [String]
    /// Fraction of aligned chords with the same root, AFTER compensating any detected
    /// transposition. 1.0 = every aligned chord agrees on root.
    let rootAgreement: Double
    /// Constant semitone offset from reference to generated when one dominates (≥ 60% of
    /// aligned pairs and non-zero) — the classic "charted in a different key" signal.
    let detectedTransposition: Int?
    /// Generated chord count ÷ reference chord count over matched lines. ≫1 means the detector
    /// splits changes the chart doesn't have; ≪1 means it misses changes the chart shows.
    let densityRatio: Double
    /// Same-root, different-suffix pairs, counted by (reference suffix → generated suffix).
    let qualityMismatches: [QualityMismatch]

    struct QualityMismatch: Equatable, Sendable {
        let referenceSuffix: String
        let generatedSuffix: String
        let count: Int
    }

    /// Human-readable systemic flags, ordered by importance. Empty = nothing systemic.
    var systemicFindings: [String] {
        var findings: [String] = []
        if let semitones = detectedTransposition {
            findings.append(
                "Generated chart is transposed \(semitones > 0 ? "+" : "")\(semitones) "
                    + "semitones relative to the reference — likely a key/capo difference, "
                    + "not a detection error."
            )
        }
        if densityRatio > 1.4 {
            findings.append(
                "Detector emits \(String(format: "%.1f", densityRatio))× the reference's chord "
                    + "density — it is splitting changes the chart treats as one."
            )
        } else if densityRatio > 0, densityRatio < 0.7 {
            findings.append(
                "Detector emits only \(String(format: "%.1f", densityRatio))× the reference's "
                    + "chord density — it is missing changes the chart shows."
            )
        }
        if rootAgreement < 0.6, !lineDiffs.isEmpty {
            findings.append(
                "Root agreement is \(Int((rootAgreement * 100).rounded()))% — the detected "
                    + "harmony disagrees with the reference beyond chart-granularity noise."
            )
        }
        for mismatch in qualityMismatches.prefix(3) where mismatch.count >= 3 {
            let from = mismatch.referenceSuffix.isEmpty ? "major" : mismatch.referenceSuffix
            let to = mismatch.generatedSuffix.isEmpty ? "major" : mismatch.generatedSuffix
            findings.append(
                "Systematic quality shift: reference \(from) detected as \(to) "
                    + "(\(mismatch.count)×)."
            )
        }
        if !unmatchedReferenceLines.isEmpty {
            findings.append(
                "\(unmatchedReferenceLines.count) reference lines matched no generated line — "
                    + "check lyric segmentation."
            )
        }
        return findings
    }
}

/// Compares the generated ChordPro chart against a user-supplied reference chart.
///
/// The reference is UNTIMED (chords typeset over lyrics), so alignment is textual: generated
/// lyric lines match reference lyric lines by normalized token overlap (monotonic greedy —
/// verses stay in order), and each matched pair's chord sequences align by
/// longest-common-subsequence on transposition-compensated roots.
enum ReferenceChartComparator {
    static func compare(generated: String, reference: String) throws
        -> ReferenceChartComparison
    {
        let generatedLines = try lyricLines(from: generated)
        let referenceLines = try lyricLines(from: reference)

        // Monotonic greedy line matching on token overlap.
        var pairs: [(generated: Int, reference: Int)] = []
        var cursor = 0
        for (generatedIndex, generatedLine) in generatedLines.enumerated() {
            guard cursor < referenceLines.count else { break }
            var best: (index: Int, score: Double)?
            for referenceIndex in cursor..<min(cursor + 6, referenceLines.count) {
                let score = similarity(
                    generatedLine.tokens, referenceLines[referenceIndex].tokens)
                if score >= 0.5, score > (best?.score ?? 0) {
                    best = (referenceIndex, score)
                }
            }
            if let best {
                pairs.append((generatedIndex, best.index))
                cursor = best.index + 1
            }
        }

        // Global transposition: histogram of root deltas over positionally-aligned chords.
        var deltaHistogram: [Int: Int] = [:]
        for pair in pairs {
            let generatedRoots = generatedLines[pair.generated].chords.compactMap(rootPitchClass)
            let referenceRoots = referenceLines[pair.reference].chords.compactMap(rootPitchClass)
            for (g, r) in zip(generatedRoots, referenceRoots) {
                deltaHistogram[((g - r) % 12 + 12) % 12, default: 0] += 1
            }
        }
        let totalDeltas = deltaHistogram.values.reduce(0, +)
        let dominant = deltaHistogram.max { $0.value < $1.value }
        let transposition: Int? = {
            guard let dominant, totalDeltas > 0, dominant.key != 0,
                Double(dominant.value) / Double(totalDeltas) >= 0.6
            else { return nil }
            // Report as signed semitones in -5...6.
            return dominant.key > 6 ? dominant.key - 12 : dominant.key
        }()
        let offset = ((transposition ?? 0) % 12 + 12) % 12

        var lineDiffs: [ReferenceLineDiff] = []
        var qualityCounts: [String: Int] = [:]
        var alignedTotal = 0
        var rootMatchTotal = 0
        var generatedChordTotal = 0
        var referenceChordTotal = 0
        for pair in pairs {
            let generatedLine = generatedLines[pair.generated]
            let referenceLine = referenceLines[pair.reference]
            generatedChordTotal += generatedLine.chords.count
            referenceChordTotal += referenceLine.chords.count
            let alignment = longestCommonSubsequence(
                generatedLine.chords, referenceLine.chords, offset: offset)
            alignedTotal += min(generatedLine.chords.count, referenceLine.chords.count)
            rootMatchTotal += alignment.count
            for (g, r) in alignment {
                let generatedSuffix = suffix(of: g)
                let referenceSuffix = suffix(of: r)
                if generatedSuffix != referenceSuffix {
                    qualityCounts["\(referenceSuffix)→\(generatedSuffix)", default: 0] += 1
                }
            }
            lineDiffs.append(
                ReferenceLineDiff(
                    generatedLineIndex: pair.generated,
                    lyric: generatedLine.lyric,
                    referenceChords: referenceLine.chords,
                    generatedChords: generatedLine.chords,
                    rootMatches: alignment.count,
                    alignedCount: min(generatedLine.chords.count, referenceLine.chords.count)))
        }
        let matchedReference = Set(pairs.map(\.reference))
        let unmatched = referenceLines.enumerated()
            .filter { !matchedReference.contains($0.offset) && !$0.element.chords.isEmpty }
            .map(\.element.lyric)

        let qualityMismatches =
            qualityCounts
            .map { key, count -> ReferenceChartComparison.QualityMismatch in
                let parts = key.split(separator: "→", omittingEmptySubsequences: false)
                return .init(
                    referenceSuffix: String(parts.first ?? ""),
                    generatedSuffix: parts.count > 1 ? String(parts[1]) : "",
                    count: count)
            }
            .sorted { $0.count > $1.count }

        return ReferenceChartComparison(
            lineDiffs: lineDiffs,
            unmatchedReferenceLines: unmatched,
            rootAgreement: alignedTotal > 0
                ? Double(rootMatchTotal) / Double(alignedTotal) : 0,
            detectedTransposition: transposition,
            densityRatio: referenceChordTotal > 0
                ? Double(generatedChordTotal) / Double(referenceChordTotal) : 0,
            qualityMismatches: qualityMismatches)
    }

    // MARK: - Parsing helpers

    private struct ParsedLine {
        let lyric: String
        let tokens: Set<String>
        let chords: [String]
    }

    private static func lyricLines(from source: String) throws -> [ParsedLine] {
        let document = try ChordProPreviewDocument(parsing: source)
        return document.blocks.compactMap { block -> ParsedLine? in
            guard case .lyric(let line) = block, line.hasSungText else { return nil }
            let lyric = line.lyric.trimmingCharacters(in: .whitespaces)
            return ParsedLine(
                lyric: lyric,
                tokens: Set(
                    lyric.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .filter { $0.count > 1 }),
                chords: line.chords.map(\.name))
        }
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Pitch class 0–11 of a chord name's root, or nil for unparseable labels.
    static func rootPitchClass(_ name: String) -> Int? {
        guard let letter = name.first else { return nil }
        let base: [Character: Int] = [
            "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
        ]
        guard var pitch = base[Character(letter.uppercased())] else { return nil }
        if name.dropFirst().first == "#" { pitch += 1 }
        if name.dropFirst().first == "b" { pitch -= 1 }
        return ((pitch % 12) + 12) % 12
    }

    /// Everything after the root letter and accidental, before any slash bass.
    static func suffix(of name: String) -> String {
        var rest = name.dropFirst()
        if rest.first == "#" || rest.first == "b" { rest = rest.dropFirst() }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        return String(rest)
    }

    /// LCS over root pitch classes, with the generated side shifted by -offset semitones so a
    /// globally transposed chart still aligns. Returns matched (generated, reference) pairs.
    private static func longestCommonSubsequence(
        _ generated: [String], _ reference: [String], offset: Int
    ) -> [(String, String)] {
        let g = generated.map { rootPitchClass($0).map { ($0 - offset + 12) % 12 } }
        let r = reference.map(rootPitchClass)
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: r.count + 1), count: g.count + 1)
        for i in stride(from: g.count - 1, through: 0, by: -1) {
            for j in stride(from: r.count - 1, through: 0, by: -1) {
                if let gi = g[i], let rj = r[j], gi == rj {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var result: [(String, String)] = []
        var i = 0
        var j = 0
        while i < g.count, j < r.count {
            if let gi = g[i], let rj = r[j], gi == rj {
                result.append((generated[i], reference[j]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
