import Foundation

/// Replaces words the transcriber itself was not confident about with a visible placeholder,
/// rather than printing a confident-looking wrong word.
///
/// WHY THE PRIMARY ENGINE'S OWN CONFIDENCE, and not a second engine's opinion: measured on the
/// cached transcriptions for "Doc Holiday" (2026-07-31), requiring a second engine to ALSO
/// disagree flagged **zero** words that low confidence alone did not already flag, and vetoed 13
/// that it should have caught — including a whole garbled line ("the devil's wants in and
/// everybody loves down for the dead", every token at confidence 0.00) that the second engine
/// mis-heard the same way. Two ASR engines fail in a CORRELATED way on genuinely unclear audio,
/// so their agreement is evidence that the audio is ambiguous, not that the reading is right.
/// A second engine is therefore strictly worse here: more machinery, less recall.
///
/// PRESENTATION ONLY — never persist the output. The document stores the transcriber's real
/// words plus `TimedLyricWord.confidence`; this derives what to SHOW from them, so the threshold
/// stays adjustable and nothing is destroyed. Applying it inside the analysis stage (as an earlier
/// revision did) corrupts `chordProSource` and the exported .cho, the persisted `lyricBlendRows`,
/// and `ChorusChordConsensus` — which groups lines by identical normalized text, so two different
/// lines both blanked to `___` would vote on each other's CHORDS. It also leaks into
/// `referenceLyrics` via "Fill from current transcription", which is unrecoverable because
/// reference-aligned words carry no confidence at all.
///
/// Callers must pass RAW segments and must not feed the result to `ChordProDraftInput`, to any
/// edit/merge/split path, or to `currentLyricsAsText`.
enum LyricConfidencePlaceholder {
    /// Word confidence below this is shown as `placeholderText`. 0.5 sits in a wide, flat valley
    /// on the field data: every threshold in 0.3...0.5 flags the same 7 cross-engine-corroborated
    /// words, and 0.5 additionally catches the fully-garbled 0.00-confidence runs.
    static let defaultMinimumConfidence: Float = 0.5

    static let placeholderText = "___"

    /// Trailing sentence punctuation is kept (`sin.` -> `___.`) so line-final punctuation, which
    /// downstream readers and the ChordPro export rely on, survives.
    private static let keptTrailingPunctuation = CharacterSet(charactersIn: ".,!?;:")

    /// - Parameter minimumConfidence: pass `nil` to disable the pass entirely.
    static func applied(
        to segments: [TimedLyricSegment],
        minimumConfidence: Float? = defaultMinimumConfidence
    ) -> [TimedLyricSegment] {
        guard let threshold = minimumConfidence else { return segments }
        return segments.map { segment in
            guard !segment.words.isEmpty,
                segment.words.contains(where: { isUncertain($0, threshold: threshold) })
            else { return segment }

            var rebuilt = segment
            var characters: [Character] = []
            var words: [TimedLyricWord] = []
            for word in segment.words {
                if !characters.isEmpty { characters.append(" ") }
                let text =
                    isUncertain(word, threshold: threshold)
                    ? placeholder(for: word.text) : word.text
                let lower = characters.count
                characters.append(contentsOf: text)
                var replaced = word
                replaced.text = text
                replaced.characterRange = lower..<characters.count
                words.append(replaced)
            }
            rebuilt.text = String(characters)
            rebuilt.words = words
            return rebuilt
        }
    }

    /// Function words are never blanked, however unsure the engine was. Measured across all five
    /// cached songs at threshold 0.5, roughly HALF of all low-confidence words were these
    /// ("I need a break `and` a Key West bar", "`The` saloon door swung open") — ASR is
    /// structurally less certain about short unstressed words and about the first token after a
    /// pause, so a low score there says little about correctness. Blanking one destroys a word
    /// that was almost certainly right and tells the reader nothing they can act on, whereas a
    /// blanked CONTENT word is exactly the signal wanted. Restricting to content words removes
    /// ~50% of the flags and none of the useful ones.
    ///
    /// Deliberately a separate list from `TimedLyricSegmentGrouper`'s `functionWords`: that one
    /// answers "can this word stand alone as a sung line?", this one answers "would a blank here
    /// be less useful than the guess?". They overlap but should be free to diverge.
    private static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "if", "as", "than", "then",
        "to", "of", "in", "on", "at", "by", "for", "with", "from", "into", "onto", "out", "up",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his", "she", "her",
        "it", "its", "they", "them", "their", "that", "this", "these", "those",
        "is", "are", "am", "be", "was", "were", "not", "no",
    ]

    private static func isFunctionWord(_ text: String) -> Bool {
        let core = String(
            text.lowercased().unicodeScalars.filter(CharacterSet.letters.contains))
        return functionWords.contains(core)
    }

    /// A `nil` confidence is NOT low confidence — it means the engine reported none (Parakeet on
    /// some paths), or the line came from reference lyrics, or a re-segmentation pass could not
    /// attribute one. Treating `nil` as uncertain would blank an entire song.
    private static func isUncertain(_ word: TimedLyricWord, threshold: Float) -> Bool {
        guard let confidence = word.confidence, confidence < threshold else { return false }
        return !isFunctionWord(word.text)
    }

    private static func placeholder(for text: String) -> String {
        let trailing = String(
            text.unicodeScalars.reversed()
                .prefix(while: keptTrailingPunctuation.contains)
                .reversed().map(Character.init))
        return placeholderText + trailing
    }
}
