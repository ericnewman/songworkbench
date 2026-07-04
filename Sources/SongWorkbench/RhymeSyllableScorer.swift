import Foundation

/// Stage 2 of `LyricPhraseGrouper` (backlog #9 Phase 2, `.scratch/PRD-phrase-structure-lyric-grouper.md`
/// §3.4): given Stage 1's bar-period boundary and a small set of nearby REAL word-gap candidates
/// (already computed by the caller — this type never touches word timing itself), picks whichever
/// candidate reads as the most musically/lyrically even phrase relative to the section's OTHER
/// already-placed phrase cells — end-rhyme match plus syllable-count similarity to their median.
///
/// Deliberately conservative: this is a *nudge*, not a re-decision. It only ever returns a
/// candidate that was already offered to it (all of which are real, existing word gaps within the
/// caller's bounded search window), and it only moves away from the nearest-in-time candidate
/// (Stage 1's own choice) when a nearby alternative scores meaningfully better — ties, marginal
/// differences, or a total absence of rhyme/syllable evidence all keep the nearest-in-time
/// candidate untouched. Pure, `Sendable`, fully unit-tested independent of `TimedLyricWord`/
/// grouping internals (candidates are plain values, not word indices).
enum RhymeSyllableScorer {
    /// One real word-gap candidate boundary could snap to. `wordIndex` is an opaque payload the
    /// caller round-trips (`LyricPhraseGrouper` uses it as an index into its own word array); this
    /// type never interprets it.
    struct Candidate: Equatable, Sendable {
        let wordIndex: Int
        /// The text of the last word in the line this candidate would produce.
        let endingWord: String
        /// Total syllables (`SyllableCounter`) across the line this candidate would produce.
        let syllableCount: Int
        /// Absolute distance from Stage 1's computed phrase boundary, in seconds.
        let distanceFromComputedBoundary: TimeInterval
    }

    struct Configuration: Equatable, Sendable {
        /// Relative weight of the end-rhyme signal in the combined score.
        var rhymeWeight: Double
        /// Relative weight of the syllable-count-similarity signal in the combined score.
        var syllableWeight: Double
        /// A candidate must beat the nearest-in-time candidate's score by at least this much to be
        /// chosen instead of it — keeps the default outcome "no change" on ties/marginal deltas.
        var minimumImprovement: Double

        init(
            rhymeWeight: Double = 0.6, syllableWeight: Double = 0.4,
            minimumImprovement: Double = 0.05
        ) {
            self.rhymeWeight = max(rhymeWeight, 0)
            self.syllableWeight = max(syllableWeight, 0)
            self.minimumImprovement = max(minimumImprovement, 0)
        }
    }

    /// Picks the best-scoring candidate, defaulting to the one nearest Stage 1's computed
    /// boundary whenever there's nothing to gain by moving: a single candidate, no sibling data to
    /// compare against (first phrase in a section, or callers that couldn't derive sibling
    /// endings), no candidate carries any rhyme/syllable signal at all, or no candidate clears
    /// `minimumImprovement` over the nearest one. Returns `nil` only when `candidates` is empty.
    static func selectBoundary(
        among candidates: [Candidate],
        siblingEndings: [String],
        siblingSyllableCounts: [Int],
        rhymeDetector: RhymeDetector,
        configuration: Configuration = .init()
    ) -> Candidate? {
        guard
            let nearest = candidates.min(by: {
                $0.distanceFromComputedBoundary < $1.distanceFromComputedBoundary
            })
        else { return nil }
        guard candidates.count > 1, !siblingEndings.isEmpty else { return nearest }

        let medianSyllables = median(siblingSyllableCounts)

        func score(_ candidate: Candidate) -> Double? {
            var total = 0.0
            var weight = 0.0
            if let rhyme = rhymeDetector.bestRhymeScore(
                for: candidate.endingWord, against: siblingEndings)
            {
                total += rhyme * configuration.rhymeWeight
                weight += configuration.rhymeWeight
            }
            if medianSyllables > 0 {
                let delta = abs(Double(candidate.syllableCount - medianSyllables))
                let similarity = max(0, 1 - delta / Double(medianSyllables))
                total += similarity * configuration.syllableWeight
                weight += configuration.syllableWeight
            }
            guard weight > 0 else { return nil }  // no usable signal for this candidate at all
            return total / weight
        }

        guard let nearestScore = score(nearest) else { return nearest }

        var best = nearest
        var bestScore = nearestScore
        for candidate in candidates where candidate != nearest {
            guard let candidateScore = score(candidate) else { continue }
            if candidateScore > bestScore {
                best = candidate
                bestScore = candidateScore
            }
        }

        guard best != nearest, bestScore - nearestScore >= configuration.minimumImprovement else {
            return nearest
        }
        return best
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
