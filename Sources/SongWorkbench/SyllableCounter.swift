import Foundation

/// Heuristic English syllable counter (vowel-cluster counting + silent-trailing-"e" adjustment).
/// This is NOT a dictionary lookup — it is the standard vowel-group heuristic used by most
/// readability tools, roughly 85-90% accurate on common English words (known miss: a word like
/// "smile" counts as 2, since the heuristic can't detect that a lone consonant separates two
/// vowel letters that together form ONE syllable's nucleus+silent-e). That accuracy is sufficient
/// for Stage 2 of `LyricPhraseGrouper` (backlog #9 Phase 2): it only needs *relative* similarity
/// between a candidate line and its siblings' median syllable count, never an exact count
/// reported to the user — see `.scratch/PRD-phrase-structure-lyric-grouper.md` §5, which flags
/// this exact heuristic-vs-dictionary trade-off and recommends the heuristic for that reason
/// (zero new bundled data, adequate for a relative-similarity signal).
///
/// Pure, deterministic, no bundled data, no locale dependency beyond ASCII vowel letters.
enum SyllableCounter {
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// Syllable count for a single word. Non-letter characters (punctuation, digits, apostrophes)
    /// are stripped entirely before scanning — they neither start nor break a vowel run. Empty or
    /// fully non-alphabetic input returns 0, which callers should treat as "no data," not as "one
    /// syllable" (use `max(count, 1)` at the call site only once real letters are known present).
    static func count(in word: String) -> Int {
        let letters = word.lowercased().filter { $0.isLetter }
        guard !letters.isEmpty else { return 0 }

        var groups = 0
        var previousWasVowel = false
        for character in letters {
            let isVowel = vowels.contains(character)
            if isVowel, !previousWasVowel { groups += 1 }
            previousWasVowel = isVowel
        }

        // Silent trailing "e" (e.g. "bike" -> 1): drop one group, UNLESS the word ends "le" after
        // a consonant (e.g. "table", "little"), where the "e" carries its own syllable rather than
        // being silent. Never drop below 1 group this way.
        if groups > 1, letters.hasSuffix("e"), !letters.hasSuffix("le") {
            groups -= 1
        }
        return max(groups, 1)
    }

    /// Total syllables across `words` (e.g. every word text in a candidate lyric line). Callers
    /// control tokenization by passing an already-split word list rather than raw line text.
    static func count(inWords words: [String]) -> Int {
        words.reduce(0) { $0 + count(in: $1) }
    }
}
