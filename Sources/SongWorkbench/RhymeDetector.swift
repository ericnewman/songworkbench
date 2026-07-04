import Foundation

/// Looks up a word's end-rhyme "rhyme part" — the phoneme sequence from its last PRIMARY-stressed
/// vowel to the end of the word, with stress digits stripped — and compares words for a true
/// end-rhyme match. Backing data is a filtered, bundled derivative of the public CMU Pronouncing
/// Dictionary (`Resources/cmudict_rhyme.tsv`; Carnegie Mellon University, BSD-style license
/// retained in the file's header, per the confirmed Phase 2 design decision in
/// `.scratch/PRD-phrase-structure-lyric-grouper.md` §5 to use a bundled phonetic table rather than
/// an orthographic-suffix heuristic).
///
/// Safe on unknown (out-of-vocabulary) words by construction: every comparison that can't find
/// real phonetic evidence for BOTH words returns `nil`/`false`/no-match rather than guessing —
/// matches this codebase's "no-op, loudly, on missing data" convention (see
/// `LyricPhraseGrouper`'s own guards). A word missing from the table (proper nouns, slang,
/// misspellings the ASR produced) simply contributes no rhyme signal; it never counts as *not*
/// rhyming, since that would be asserting evidence that doesn't exist.
struct RhymeDetector: Sendable {
    private let table: [String: String]

    /// Direct injection for tests (and any future non-bundle-backed use) — bypasses the singleton
    /// bundle loader entirely.
    init(table: [String: String]) {
        self.table = table
    }

    /// Parses the bundled `word<TAB>rhyme-key` TSV format: one entry per line, blank lines and
    /// `#`-prefixed comment/header lines ignored. Pure; this is the SAME parser both the
    /// production bundle loader and unit tests exercise, so tests can't silently drift from the
    /// real file's format by asserting against a hand-rolled dictionary literal instead.
    static func parseTable(_ text: String) -> [String: String] {
        // `split(whereSeparator: \.isNewline)` — NOT `split(separator: "\n")` — because Swift's
        // `Character` is an extended grapheme cluster: a "\r\n" line ending is ONE Character, not
        // two, so splitting on a bare "\n" Character silently fails to split CRLF-terminated text
        // at all (the whole file becomes a single "line"). `isNewline` correctly recognizes LF,
        // CR, and CRLF alike, so this is correct regardless of which line ending the bundled
        // resource (or any future edit to it) uses.
        var table: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { continue }
            table[String(fields[0])] = String(fields[1])
        }
        return table
    }

    /// Lazily loads and parses the bundled resource exactly once per process. Falls back to an
    /// EMPTY table (every lookup `nil`, so any rhyme-dependent caller silently no-ops) if the
    /// resource can't be found or read — never crashes the analysis pipeline over a missing/
    /// corrupt bundled file.
    static let shared: RhymeDetector = {
        guard
            let url = Bundle.main.url(forResource: "cmudict_rhyme", withExtension: "tsv"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return RhymeDetector(table: [:])
        }
        return RhymeDetector(table: parseTable(text))
    }()

    /// Normalizes a word the same way the bundled table's keys are normalized: lowercased, and
    /// stripped of every character that isn't a letter or an apostrophe (keeps contractions like
    /// "don't" intact — CMUdict's own word column uses the same convention).
    static func normalize(_ word: String) -> String {
        String(
            word.lowercased().unicodeScalars.filter {
                CharacterSet.letters.contains($0) || $0 == "'"
            })
    }

    /// The word's rhyme part, or `nil` if it isn't in the table.
    func rhymePart(for word: String) -> String? {
        table[Self.normalize(word)]
    }

    /// True only when BOTH words are known and share an identical, non-empty rhyme part. Returns
    /// `false` (not `nil`) for convenience at simple call sites — callers that need to distinguish
    /// "confirmed non-rhyme" from "no evidence either way" should use `bestRhymeScore` instead.
    func rhymes(_ a: String, _ b: String) -> Bool {
        guard let partA = rhymePart(for: a), let partB = rhymePart(for: b), !partA.isEmpty else {
            return false
        }
        return partA == partB
    }

    /// Best rhyme match of `word` against any entry in `others`: `1.0` if `word` shares a rhyme
    /// part with at least one known word in `others`, `0.0` if `word` is known and at least one
    /// of `others` is known but none match, or `nil` when there is no usable evidence at all
    /// (`word` itself is out-of-vocabulary, or every candidate in `others` is). `nil` must never be
    /// treated as `0.0` by callers — it means "no signal," not "confirmed non-rhyme."
    func bestRhymeScore(for word: String, against others: [String]) -> Double? {
        guard let part = rhymePart(for: word), !part.isEmpty else { return nil }
        var sawKnownOther = false
        for other in others {
            guard let otherPart = rhymePart(for: other) else { continue }
            sawKnownOther = true
            if otherPart == part { return 1.0 }
        }
        return sawKnownOther ? 0.0 : nil
    }
}
