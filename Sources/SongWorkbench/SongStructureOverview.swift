import Foundation

/// A whole-song structural overview that separates a song's **structure** from its
/// **content** (Eric's framing, 2026-07-06): Form (section order), Harmony (chord
/// progression as scale degrees), Meter (lyric syllable pattern), Rhyme (end-rhyme scheme),
/// and an approximate Melody phrase pattern — as distinct layers from the actual Lyrics.
/// Each repeated section kind also gets a canonical `PhraseTemplate` (the reusable
/// melodic/rhythmic/harmonic shape composers reuse across occurrences with different
/// words) — see `tasks/todo.md`'s "Plan: Structure tab" for the full design rationale.
///
/// Pure/derived, like `SongTimeline` (`ChordProDraftBuilder.buildResult`): computed on
/// demand from the same `ChordProDraftInput`-shaped data the chart builder already uses,
/// never persisted into the saved analysis JSON.
struct SongStructureOverview: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        enum Kind: String, Equatable, Hashable, Sendable {
            case intro
            case verse
            case chorus
            /// A worded, non-repeating section that doesn't match the established
            /// verse/chorus chord-pattern template — see `SongStructureOverviewBuilder`.
            case bridge
            /// A wordless instrumental gap whose chord pattern matches an established
            /// verse/chorus template (per Eric: "a word-less verse or chorus pattern is
            /// usually a solo") — distinct from a generic `.instrumental` fill/break.
            case solo
            case instrumental
            case outro
        }

        var label: String
        var kind: Kind
        var start: TimeInterval
        var end: TimeInterval
        /// Lyric lines within this section; empty for purely instrumental kinds.
        var lines: [TimedLyricSegment]
        /// Chord events sounding within this section, time-ordered.
        var chords: [EditableChordEvent]
    }

    /// The canonical shape shared by every occurrence of a repeated, worded section kind —
    /// what Eric described as a VERSE TEMPLATE / CHORUS TEMPLATE: a handful of reusable
    /// phrase shapes that recur with different lyrics on top.
    struct PhraseTemplate: Equatable, Sendable {
        var kind: Section.Kind
        var lineCount: Int
        /// Approximate melodic-phrase letter per line, e.g. `["A","A","B","A"]` — see
        /// `MelodyPhraseProxy`'s doc comment for why this is a proxy, not real melody
        /// analysis (this app has no pitch-contour/melody-transcription pipeline).
        var phrasePattern: [String]
        /// Roman-numeral chord symbols relative to the song's key, in order, with
        /// consecutive sustains collapsed to one entry — a flat sequence, not yet
        /// bar-grouped (a v1 simplification; see the builder's doc comment).
        var chordPattern: [String]
        /// Syllable count per line.
        var meterPattern: [Int]
        /// End-rhyme letter per line, e.g. `["A","B","C","B"]`; `"-"` when a line's last
        /// word has no entry in the bundled rhyme dictionary.
        var rhymeScheme: [String]
    }

    var title: String
    /// Every section in the song, in time order.
    var form: [Section]
    /// One template per section kind that has at least one worded occurrence.
    var templates: [PhraseTemplate]
}

/// Chord-label-to-scale-degree (Roman numeral) mapping relative to a `MusicalKey`. A small,
/// deliberately separate parser from `MusicalKeyEstimator.parseChord` (private to that
/// type, tuned for key-estimation scoring, not display) — duplicating the ~10-line root
/// lookup here is safer than reaching into an already-tested internal for a different job.
enum RomanNumeralMapper {
    /// Degree name per semitone interval above a MAJOR key's tonic (0...11).
    private static let majorDegreeNames = [
        "I", "bII", "II", "bIII", "III", "IV", "bV", "V", "bVI", "VI", "bVII", "VII",
    ]
    /// Degree name per semitone interval above a MINOR key's tonic (0...11), natural-minor
    /// baseline with the common raised alternatives for the non-diatonic slots.
    private static let minorDegreeNames = [
        "i", "bII", "ii", "III", "#III", "iv", "bV", "v", "VI", "#VI", "VII", "#VII",
    ]
    private static let roots: [String: PitchClass] = [
        "C": .c, "B#": .c,
        "C#": .cSharp, "Db": .cSharp,
        "D": .d,
        "D#": .dSharp, "Eb": .dSharp,
        "E": .e, "Fb": .e,
        "F": .f, "E#": .f,
        "F#": .fSharp, "Gb": .fSharp,
        "G": .g,
        "G#": .gSharp, "Ab": .gSharp,
        "A": .a,
        "A#": .aSharp, "Bb": .aSharp,
        "B": .b, "Cb": .b,
    ]

    /// A chord label's root pitch class plus a simplified quality reading, or `nil` if the
    /// label doesn't start with a recognizable note name.
    static func parse(_ label: String) -> (root: PitchClass, isMinor: Bool, isSeventh: Bool)? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let accidental = trimmed.dropFirst().first.flatMap { $0 == "#" || $0 == "b" ? $0 : nil }
        let rootName = String(first).uppercased() + (accidental.map(String.init) ?? "")
        guard let root = roots[rootName] else { return nil }
        let suffix = trimmed.dropFirst(rootName.count).lowercased()
        let isMinor = suffix.hasPrefix("m") && !suffix.hasPrefix("maj")
        let isSeventh = suffix.contains("7")
        return (root, isMinor, isSeventh)
    }

    /// The chord's scale degree relative to `key`, e.g. `"V7"`, `"vi"`, `"bVII"` — falls
    /// back to the bare chord label when it can't be parsed (an exotic symbol outside this
    /// app's chord vocabulary).
    static func numeral(for chordLabel: String, in key: MusicalKey) -> String {
        guard let parsed = parse(chordLabel) else { return chordLabel }
        let interval = (parsed.root.rawValue - key.root.rawValue + 12) % 12
        let table = key.quality == .minor ? minorDegreeNames : majorDegreeNames
        let raw = table[interval]
        let accidentalPrefix = raw.hasPrefix("b") ? "b" : (raw.hasPrefix("#") ? "#" : "")
        let romanLetters = String(raw.dropFirst(accidentalPrefix.count))
        let cased = parsed.isMinor ? romanLetters.lowercased() : romanLetters.uppercased()
        let numeral = accidentalPrefix + cased
        return parsed.isSeventh ? numeral + "7" : numeral
    }
}

/// Approximate melodic-phrase-letter assignment (e.g. `["A","A","B","A"]`) for a run of
/// lines. This is a PROXY, not real melody analysis: the app has no pitch-contour/melody-
/// transcription pipeline (only ASR lyrics + chord/beat timing), so genuine melodic-phrase
/// identity can't be computed honestly. Instead, two lines are treated as "the same
/// melodic phrase" when they share an identical chord-pattern signature AND a similar
/// syllable count — usually true in verse/chorus pop/country form, where the tune repeats
/// under different words (that's exactly what makes an AABA verse over an ABCB rhyme
/// scheme possible), but a stand-in. Callers should label output as approximate.
enum MelodyPhraseProxy {
    static func phraseLetters(
        chordSignatures: [[String]], syllableCounts: [Int], syllableTolerance: Int = 1
    ) -> [String] {
        guard chordSignatures.count == syllableCounts.count else { return [] }
        var clusters: [(signature: [String], syllables: Int, letter: String)] = []
        var letters: [String] = []
        var nextLetter: UInt8 = 65  // "A"
        for index in chordSignatures.indices {
            let signature = chordSignatures[index]
            let syllables = syllableCounts[index]
            if let match = clusters.first(where: {
                $0.signature == signature && abs($0.syllables - syllables) <= syllableTolerance
            }) {
                letters.append(match.letter)
            } else {
                let letter = String(UnicodeScalar(nextLetter))
                clusters.append((signature, syllables, letter))
                letters.append(letter)
                nextLetter += 1
            }
        }
        return letters
    }
}

/// Builds a `SongStructureOverview` from the same input shape `ChordProDraftBuilder` uses,
/// reusing its existing structure-detection building blocks (`LyricSectionDeriver`,
/// `SongStructureAnalyzer`, `TrailingLyricTailPruner`) rather than re-deriving Form from
/// scratch, plus new Harmony/Meter/Rhyme/Melody-proxy layers on top.
struct SongStructureOverviewBuilder: Sendable {
    func build(_ input: ChordProDraftInput) -> SongStructureOverview? {
        let lyrics = input.lyrics.sorted { $0.start < $1.start }
        guard !lyrics.isEmpty else { return nil }

        // Same tail-hallucination exclusion `ChordProDraftBuilder` applies before inferring
        // structure — a Structure tab should never treat an ASR blip as a real section.
        let tailCutoff = TrailingLyricTailPruner.lyricBodyEndBeforeInstrumentalTail(
            lyrics, sourceDuration: input.sourceDuration)
        let bodyLyrics = lyrics.filter { line in
            guard let cutoff = tailCutoff else { return true }
            return TrailingLyricTailPruner.substantiveLineStart(line) < cutoff - 0.02
        }
        guard !bodyLyrics.isEmpty else { return nil }

        let markers = LyricSectionDeriver().sections(
            lyrics: bodyLyrics, beatTimes: input.beatTimes, tempo: input.tempo,
            sourceDuration: input.sourceDuration)
        guard !markers.isEmpty else { return nil }

        let lastKnownEnd = max(
            bodyLyrics.map(\.end).max() ?? 0,
            (input.chords.map(\.time).max() ?? 0) + 1)
        let songEnd = resolvedDuration(input: input, lastKnownEnd: lastKnownEnd)

        var sections: [SongStructureOverview.Section] = []
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].start : songEnd
            let kind: SongStructureOverview.Section.Kind
            let label: String
            switch marker.kind {
            case .intro:
                kind = .intro
                label = "Intro"
            case .instrumental:
                kind = .instrumental
                label = "Instrumental"
            case .outro:
                kind = .outro
                label = "Outro"
            case .vocal(let sectionLabel):
                kind = sectionLabel == "Chorus" ? .chorus : .verse
                label = sectionLabel
            }
            let lines = bodyLyrics.filter { $0.start >= marker.start && $0.start < end }
            let chords =
                input.chords
                .filter { $0.time >= marker.start && $0.time < end }
                .sorted { $0.time < $1.time }
            sections.append(
                .init(
                    label: label, kind: kind, start: marker.start, end: end, lines: lines,
                    chords: chords))
        }

        let reclassified = reclassifyBridgeAndSolo(sections, key: input.estimatedKey)
        let templates = buildTemplates(reclassified, key: input.estimatedKey)
        return SongStructureOverview(title: input.title, form: reclassified, templates: templates)
    }

    /// Reclassifies sections using chord-pattern comparison against each kind's majority
    /// template: a verse-kind section whose chords don't match the majority verse pattern
    /// becomes a **Bridge**; a wordless `.instrumental` section whose chords DO match an
    /// established verse/chorus pattern becomes a **Solo** (per Eric: "a word-less verse or
    /// chorus pattern is usually a solo"). Both reuse the same `chordSignature`/
    /// `signaturesMatch` comparators the Phrase Template step below also uses.
    private func reclassifyBridgeAndSolo(
        _ input: [SongStructureOverview.Section], key: MusicalKey?
    ) -> [SongStructureOverview.Section] {
        var sections = input
        let verseIndices = sections.indices.filter { sections[$0].kind == .verse }
        let verseSignatures = verseIndices.map { chordSignature(sections[$0].chords, key: key) }
        let verseTemplate = mostCommon(verseSignatures)

        let chorusIndices = sections.indices.filter { sections[$0].kind == .chorus }
        let chorusSignatures = chorusIndices.map { chordSignature(sections[$0].chords, key: key) }
        let chorusTemplate = mostCommon(chorusSignatures)

        // Only reclassify against a majority template shared by >= 2 occurrences — a single
        // verse has nothing to compare against, so nothing gets relabeled Bridge.
        if let verseTemplate, verseSignatures.filter({ $0 == verseTemplate }).count >= 2 {
            for index in verseIndices {
                let signature = chordSignature(sections[index].chords, key: key)
                if !signature.isEmpty, !signaturesMatch(signature, verseTemplate) {
                    sections[index].kind = .bridge
                    sections[index].label = "Bridge"
                }
            }
        }

        for index in sections.indices where sections[index].kind == .instrumental {
            let signature = chordSignature(sections[index].chords, key: key)
            guard !signature.isEmpty else { continue }
            if let verseTemplate, signaturesMatch(signature, verseTemplate) {
                sections[index].kind = .solo
                sections[index].label = "Solo"
            } else if let chorusTemplate, signaturesMatch(signature, chorusTemplate) {
                sections[index].kind = .solo
                sections[index].label = "Solo"
            }
        }
        return sections
    }

    private func buildTemplates(
        _ sections: [SongStructureOverview.Section], key: MusicalKey?
    ) -> [SongStructureOverview.PhraseTemplate] {
        var templates: [SongStructureOverview.PhraseTemplate] = []
        for kind in [SongStructureOverview.Section.Kind.verse, .chorus, .bridge] {
            let occurrences = sections.filter { $0.kind == kind && !$0.lines.isEmpty }
            guard !occurrences.isEmpty else { continue }
            let lineCounts = occurrences.map(\.lines.count)
            let canonicalLineCount = mostCommonInt(lineCounts) ?? occurrences[0].lines.count
            let representative =
                occurrences.first { $0.lines.count == canonicalLineCount } ?? occurrences[0]

            let rhyme = rhymeScheme(for: representative.lines)
            let meter = representative.lines.map(syllableCount)
            let perLineChordSignatures = representative.lines.map { line in
                chordSignature(
                    representative.chords.filter { $0.time >= line.start && $0.time < line.end },
                    key: key)
            }
            let phrase = MelodyPhraseProxy.phraseLetters(
                chordSignatures: perLineChordSignatures, syllableCounts: meter)
            let chordPattern = chordSignature(representative.chords, key: key)

            templates.append(
                .init(
                    kind: kind, lineCount: representative.lines.count, phrasePattern: phrase,
                    chordPattern: chordPattern, meterPattern: meter, rhymeScheme: rhyme))
        }
        return templates
    }

    /// Ordered chord-pattern signature for a span of chords: each event mapped to its Roman
    /// numeral (or the bare label when no key is known), with consecutive sustains
    /// collapsed to one entry.
    private func chordSignature(_ chords: [EditableChordEvent], key: MusicalKey?) -> [String] {
        let sorted = chords.sorted { $0.time < $1.time }
        var out: [String] = []
        for chord in sorted {
            let numeral =
                key.map { RomanNumeralMapper.numeral(for: chord.chord, in: $0) } ?? chord.chord
            if out.last != numeral { out.append(numeral) }
        }
        return out
    }

    /// Two chord signatures "match" when identical, or — to tolerate a single passing/
    /// embellishing chord — when their SET overlap (Jaccard) is at least 0.75.
    private func signaturesMatch(_ a: [String], _ b: [String]) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let setA = Set(a)
        let setB = Set(b)
        let union = setA.union(setB).count
        guard union > 0 else { return false }
        return Double(setA.intersection(setB).count) / Double(union) >= 0.75
    }

    private func mostCommon(_ signatures: [[String]]) -> [String]? {
        var counts: [[String]: Int] = [:]
        for signature in signatures where !signature.isEmpty {
            counts[signature, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func mostCommonInt(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func syllableCount(for line: TimedLyricSegment) -> Int {
        let words =
            line.words.isEmpty
            ? line.text.split { $0.isWhitespace }.map(String.init)
            : line.words.map(\.text)
        return SyllableCounter.count(inWords: words)
    }

    /// End-rhyme letter per line (e.g. `["A","B","C","B"]`) via the bundled CMU-derived
    /// rhyme dictionary; `"-"` when a line's last word has no entry.
    private func rhymeScheme(for lines: [TimedLyricSegment]) -> [String] {
        let detector = RhymeDetector.shared
        var partToLetter: [String: String] = [:]
        var nextLetter: UInt8 = 65  // "A"
        var letters: [String] = []
        for line in lines {
            guard let word = lastWord(of: line), let part = detector.rhymePart(for: word),
                !part.isEmpty
            else {
                letters.append("-")
                continue
            }
            if let existing = partToLetter[part] {
                letters.append(existing)
            } else {
                let letter = String(UnicodeScalar(nextLetter))
                partToLetter[part] = letter
                letters.append(letter)
                nextLetter += 1
            }
        }
        return letters
    }

    private func lastWord(of line: TimedLyricSegment) -> String? {
        line.text.split { !$0.isLetter && $0 != "'" }.last.map(String.init)
    }

    private func resolvedDuration(input: ChordProDraftInput, lastKnownEnd: TimeInterval)
        -> TimeInterval
    {
        if let source = input.sourceDuration, source > 0 { return source }
        if let lastBeat = input.beatTimes.max(), lastBeat > lastKnownEnd { return lastBeat }
        return lastKnownEnd
    }
}
