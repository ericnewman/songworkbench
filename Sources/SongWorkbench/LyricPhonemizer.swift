import Foundation

/// The 41-class vocabulary the lyrics-alignment acoustic model emits, and the lookup that turns
/// known lyric words into it.
///
/// The class list is not ours to choose — it is `phone_dict` from LyricsAlignment-MTL, in order:
/// 39 ARPABET phones, then a space at 39, then CTC blank at 40. Reordering it, or "tidying" the
/// space into a symbol, silently mis-maps every frame the model emits.
enum ArpabetVocabulary {
    /// Index 39 is the word separator; index 40 is CTC blank.
    static let phones: [String] = [
        "AA", "AE", "AH", "AO", "AW", "AY", "B", "CH", "D", "DH", "EH", "ER", "EY", "F", "G",
        "HH", "IH", "IY", "JH", "K", "L", "M", "N", "NG", "OW", "OY", "P", "R", "S", "SH", "T",
        "TH", "UH", "UW", "V", "W", "Y", "Z", "ZH", " ",
    ]
    static let separatorIndex = 39
    static let blankIndex = 40
    static let classCount = 41

    private static let indexByPhone: [String: Int] = {
        Dictionary(uniqueKeysWithValues: phones.enumerated().map { ($0.element, $0.offset) })
    }()

    static func index(of phone: String) -> Int? { indexByPhone[phone] }
}

/// Turns lyric words into phoneme indices, so forced alignment has a token sequence to measure.
///
/// Pronunciations come from the bundled CMUdict table. Measured over the library on 2026-09-18,
/// **0.46 % of words (23 of 5005) are absent from it**, and most of those are ordinary written
/// forms of words it does contain — `movin'`, `flipflops`, `selfcontrol`. The fallbacks below
/// recover exactly that class and nothing more; they are morphology, not a guess at spelling.
///
/// A word we still cannot pronounce is reported UNPRONOUNCEABLE and left out of the token
/// sequence. It is deliberately not given an invented pronunciation: a wrong phoneme sequence
/// would still be aligned, producing a confident and wrong time, and a fabricated time is the
/// thing this whole change exists to remove. The word's time is simply unknown, and its caller
/// says so rather than interpolating one.
struct LyricPhonemizer {
    /// One word's tokens, or the fact that we could not pronounce it.
    struct Word: Equatable, Sendable {
        let text: String
        /// Phoneme class indices; empty when `isPronounceable` is false.
        let phones: [Int]
        var isPronounceable: Bool { !phones.isEmpty }
    }

    private let pronunciations: [String: [Int]]

    init(pronunciations: [String: [Int]]) {
        self.pronunciations = pronunciations
    }

    /// Loads the bundled table. An absent or unreadable resource yields an EMPTY phonemizer, whose
    /// every word comes back unpronounceable — alignment then reports that it could not run,
    /// rather than the pipeline crashing over a missing file.
    static let shared: LyricPhonemizer = {
        guard let url = Bundle.main.url(forResource: "cmudict-arpabet", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return LyricPhonemizer(pronunciations: [:])
        }
        return LyricPhonemizer(pronunciations: parse(text))
    }()

    static func parse(_ text: String) -> [String: [Int]] {
        var table: [String: [Int]] = [:]
        table.reserveCapacity(130_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !line.hasPrefix("#") else { continue }
            var fields = line.split(separator: " ")
            guard let word = fields.first.map(String.init), fields.count > 1 else { continue }
            fields.removeFirst()
            let indices = fields.compactMap { ArpabetVocabulary.index(of: String($0)) }
            guard indices.count == fields.count else { continue }
            table[word] = indices
        }
        return table
    }

    /// Lowercased, keeping only letters and apostrophes — the table's own key convention.
    static func normalize(_ word: String) -> String {
        String(
            word.lowercased().unicodeScalars.filter {
                CharacterSet.letters.contains($0) || $0 == "'"
            })
    }

    func phones(for word: String) -> [Int]? {
        let key = Self.normalize(word)
        guard !key.isEmpty else { return nil }
        if let direct = pronunciations[key] { return direct }

        // Written forms of words the table already has. Each rule below was chosen against the
        // measured OOV list, not invented: movin' -> moving, flow's -> flow, flipflops -> flip+flops.
        if key.hasSuffix("in'"), let expanded = pronunciations[String(key.dropLast()) + "g"] {
            return expanded
        }
        if key.hasSuffix("'s") || key.hasSuffix("'d") || key.hasSuffix("'ll")
            || key.hasSuffix("'re") || key.hasSuffix("'ve")
        {
            if let stem = pronunciations[String(key.prefix(upTo: key.firstIndex(of: "'")!))] {
                return stem
            }
        }
        if key.contains("'"),
            let stripped = pronunciations[key.replacingOccurrences(of: "'", with: "")]
        {
            return stripped
        }
        // A closed compound: split at the longest prefix that is itself a word, once.
        if key.count >= 6 {
            for split in stride(from: key.count - 3, through: 3, by: -1) {
                let head = String(key.prefix(split))
                let tail = String(key.dropFirst(split))
                if let first = pronunciations[head], let second = pronunciations[tail] {
                    return first + second
                }
            }
        }
        return nil
    }

    /// Words in order, each with its phones. Callers keep the indices aligned with their own word
    /// list, so an unpronounceable word stays in place as a hole rather than shifting its
    /// neighbours.
    func words(for texts: [String]) -> [Word] {
        texts.map { Word(text: $0, phones: phones(for: $0) ?? []) }
    }

    /// The flat token sequence to align, with `ArpabetVocabulary.separatorIndex` between words,
    /// plus the token range each pronounceable word occupies.
    ///
    /// The separator is a real class the model emits, not padding: it is how the model was trained
    /// to mark word boundaries, and dropping it degrades the alignment.
    static func tokenSequence(for words: [Word]) -> (tokens: [Int], ranges: [Range<Int>?]) {
        var tokens: [Int] = []
        var ranges: [Range<Int>?] = []
        for word in words {
            guard word.isPronounceable else {
                ranges.append(nil)
                continue
            }
            if !tokens.isEmpty { tokens.append(ArpabetVocabulary.separatorIndex) }
            let lower = tokens.count
            tokens += word.phones
            ranges.append(lower..<tokens.count)
        }
        return (tokens, ranges)
    }
}
