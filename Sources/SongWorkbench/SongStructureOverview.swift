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
        /// Collapsed (consecutive-sustains-merged) chord-event count per line — the per-line
        /// counterpart to `chordPattern`'s whole-section flat sequence. Used by
        /// `StructureAlignmentDiagnostics` as a corroborating (not required) third signal
        /// alongside meter/rhyme deviation.
        var chordCountPattern: [Int] = []
    }

    /// Roll-up for a wordless section kind (Intro/Instrumental/Solo/Outro) — there's no lyric
    /// content to build a `PhraseTemplate` from, but the chord pattern and how much of the
    /// song these sections take up is still structural information worth surfacing (Eric,
    /// 2026-07-06: "include a section for the instrumental sections").
    struct InstrumentalSummary: Equatable, Sendable {
        var kind: Section.Kind
        var occurrenceCount: Int
        var totalDuration: TimeInterval
        /// Chord pattern of the LONGEST occurrence (most representative), same Roman-numeral
        /// signature format as `PhraseTemplate.chordPattern`.
        var chordPattern: [String]
    }

    var title: String
    /// Every section in the song, in time order.
    var form: [Section]
    /// One template per section kind that has at least one worded occurrence.
    var templates: [PhraseTemplate]
    /// One summary per wordless section kind (Intro/Instrumental/Solo/Outro) present in the
    /// song — see `InstrumentalSummary`.
    var instrumentalSummaries: [InstrumentalSummary] = []
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
/// melodic phrase" when they share a MATCHING chord-pattern signature AND a similar
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
                chordSignaturesMatch($0.signature, signature)
                    && abs($0.syllables - syllables) <= syllableTolerance
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

    /// Two per-line chord signatures cluster as the same melodic phrase when identical, or — to
    /// tolerate real per-line chord-window timing jitter/an embellishing passing chord some
    /// occurrences don't have — when their SET overlap (Jaccard) is at least 0.75. Mirrors
    /// `SongStructureOverviewBuilder.signaturesMatch`'s existing section-level tolerance; without
    /// it, real per-line chord data (`chords.filter { $0.time >= line.start && $0.time < line.end
    /// }`) almost never produces byte-identical arrays across two melodically-identical lines, so
    /// EVERY line ends up in its own cluster (Eric, live review, 2026-07-07: a 9-line chorus
    /// showed phrase pattern "A B C D E F G H" — essentially zero detected repetition — where a
    /// real chorus melody normally reuses just a handful of phrase shapes, e.g. AABA/ABAB).
    private static func chordSignaturesMatch(_ a: [String], _ b: [String]) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let setA = Set(a)
        let setB = Set(b)
        let union = setA.union(setB).count
        guard union > 0 else { return false }
        return Double(setA.intersection(setB).count) / Double(union) >= 0.75
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
        let instrumentalSummaries = buildInstrumentalSummaries(
            reclassified, key: input.estimatedKey)
        return SongStructureOverview(
            title: input.title, form: reclassified, templates: templates,
            instrumentalSummaries: instrumentalSummaries)
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
            let representative = representativeOccurrence(occurrences, key: key)

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
                    chordPattern: chordPattern, meterPattern: meter, rhymeScheme: rhyme,
                    chordCountPattern: perLineChordSignatures.map(\.count)))
        }
        return templates
    }

    /// Builds one `InstrumentalSummary` per wordless kind (Intro/Instrumental/Solo/Outro)
    /// that occurs at least once — the counterpart to `buildTemplates` for sections that have
    /// no lyric lines to derive a phrase/meter/rhyme template from.
    private func buildInstrumentalSummaries(
        _ sections: [SongStructureOverview.Section], key: MusicalKey?
    ) -> [SongStructureOverview.InstrumentalSummary] {
        var summaries: [SongStructureOverview.InstrumentalSummary] = []
        for kind in [
            SongStructureOverview.Section.Kind.intro, .instrumental, .solo, .outro,
        ] {
            let occurrences = sections.filter { $0.kind == kind }
            guard !occurrences.isEmpty else { continue }
            let totalDuration = occurrences.reduce(0) { $0 + ($1.end - $1.start) }
            // The longest occurrence is the most representative one to pull a chord pattern
            // from — a short pickup/tag instrumental can otherwise win by list order alone.
            let representative =
                occurrences.max { ($0.end - $0.start) < ($1.end - $1.start) } ?? occurrences[0]
            let chordPattern = chordSignature(representative.chords, key: key)
            summaries.append(
                .init(
                    kind: kind, occurrenceCount: occurrences.count, totalDuration: totalDuration,
                    chordPattern: chordPattern))
        }
        return summaries
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

    /// Picks the occurrence that best represents this kind's canonical shape. Prefers a musical
    /// signal — the occurrence whose chord pattern matches the kind's OWN majority chord
    /// signature, reusing the same `chordSignature`/`signaturesMatch`/`mostCommon` comparators
    /// `reclassifyBridgeAndSolo` already uses — over a lyric-derived one (line count). A text-
    /// segmentation glitch producing one anomalously-short occurrence must never corrupt the
    /// displayed template just because it happened to win an unstable line-count tie (Eric, live
    /// review, 2026-07-07: "This seems like another place with too much dependence on lyrics" —
    /// live-observed on Settle Down: a 4-way line-count tie [6,4,2,3] with no majority picked the
    /// 2-line fragment as "representative" via Dictionary iteration order). Falls back to the
    /// LONGEST-DURATION occurrence — still a musical measure, never line count — when no chord-
    /// pattern majority exists (a lone occurrence, or no two chord signatures match).
    private func representativeOccurrence(
        _ occurrences: [SongStructureOverview.Section], key: MusicalKey?
    ) -> SongStructureOverview.Section {
        let signatures = occurrences.map { chordSignature($0.chords, key: key) }
        if let majority = mostCommon(signatures),
            let match = occurrences.first(where: {
                signaturesMatch(chordSignature($0.chords, key: key), majority)
            })
        {
            return match
        }
        return occurrences.max { ($0.end - $0.start) < ($1.end - $1.start) } ?? occurrences[0]
    }

    /// Not `private`: reused directly by `StructureAlignmentDiagnostics` to compute a section
    /// occurrence's ACTUAL per-line syllable counts for comparison against a `PhraseTemplate`.
    func syllableCount(for line: TimedLyricSegment) -> Int {
        let words =
            line.words.isEmpty
            ? line.text.split { $0.isWhitespace }.map(String.init)
            : line.words.map(\.text)
        return SyllableCounter.count(inWords: words)
    }

    /// End-rhyme letter per line (e.g. `["A","B","C","B"]`) via the bundled CMU-derived
    /// rhyme dictionary; `"-"` when a line's last word has no entry. Not `private`: reused
    /// directly by `StructureAlignmentDiagnostics` — see `syllableCount(for:)`'s doc comment.
    /// Letters are assigned positionally (first line to introduce a rhyme part gets the next
    /// letter), so calling this fresh on a DIFFERENT set of lines than the template was built
    /// from still produces a comparable letter-sequence SHAPE, not just comparable identity.
    ///
    /// `detector` defaults to `.shared` (the real bundled dictionary) but is injectable so tests
    /// can supply a small hand-built table — the SPM test bundle doesn't host the app target's
    /// `Resources/`, so `.shared` resolves every word to "no entry" there (see
    /// `RhymeDetectorTests`'s own hand-built-table pattern).
    func rhymeScheme(
        for lines: [TimedLyricSegment], detector: RhymeDetector = .shared
    ) -> [String] {
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

/// Flags lyric lines whose syllable count AND end-rhyme both deviate from their section's
/// established `PhraseTemplate` — a structural/linguistic anomaly signal, distinct from (and
/// complementary to) `ReviewConfidenceTier`'s per-word ASR-confidence tint and
/// `LyricLineDiagnostics`'s acoustic beat-grid heuristic. Eric, 2026-07-06: "It seems like
/// enforcing some level of alignment would have caught these bugs sooner," and "When we have
/// rhyming sentences, it seems like they would be separate lines, and not concatenated" — a
/// word-doubling/run-on grouping bug breaks the established verse/chorus shape, and a rhyme
/// scheme is one of the strongest tells that a transcription over- or under-split a line.
///
/// Requiring BOTH meter and rhyme to disagree (not either alone) is deliberate: a single new
/// internal rhyme or a slightly longer line is ordinary songwriting variation, but a line that
/// is simultaneously off-meter AND breaks the established rhyme is a much stronger sign that
/// something got merged, split, or mis-transcribed. A per-line chord-event-count mismatch is
/// folded in as a third, corroborating (not required) vote when it's also present.
enum StructureAlignmentDiagnostics {
    /// Minimum syllable-count difference (vs. the template's line) treated as a real deviation,
    /// not ordinary phrasing variation.
    private static let syllableDeviationThreshold = 2

    /// Reason strings keyed by segment id, matching `LyricLineDiagnostics.suspectReasons`'s
    /// shape so a caller can merge the two into one review-flag pass. `detector` defaults to
    /// `.shared` (the real bundled dictionary); see `SongStructureOverviewBuilder.rhymeScheme`'s
    /// doc comment for why tests inject a hand-built table instead.
    static func anomalies(
        in overview: SongStructureOverview, detector: RhymeDetector = .shared
    ) -> [TimedLyricSegment.ID: String] {
        var result: [TimedLyricSegment.ID: String] = [:]
        let templatesByKind = Dictionary(
            uniqueKeysWithValues: overview.templates.map { ($0.kind, $0) })
        let builder = SongStructureOverviewBuilder()

        for section in overview.form {
            guard let template = templatesByKind[section.kind], !section.lines.isEmpty else {
                continue
            }

            // A line-count mismatch means position-by-position comparison isn't meaningful —
            // the established shape has N lines, this occurrence has a different count, which
            // is itself a strong sign one line was merged or split incorrectly. Flag it as a
            // whole (on the first line) rather than guess which specific line is at fault.
            guard section.lines.count == template.lineCount else {
                if let first = section.lines.first {
                    result[first.id] =
                        "Line count (\(section.lines.count)) differs from the established "
                        + "\(section.label) shape (\(template.lineCount) lines) — a line may "
                        + "have been merged or split incorrectly."
                }
                continue
            }

            let actualMeter = section.lines.map(builder.syllableCount(for:))

            for (index, line) in section.lines.enumerated() {
                guard index < template.meterPattern.count, index < template.rhymeScheme.count
                else { continue }

                let expectedSyllables = template.meterPattern[index]
                let actualSyllables = actualMeter[index]
                let meterDeviates =
                    expectedSyllables > 0
                    && abs(actualSyllables - expectedSyllables) >= syllableDeviationThreshold

                let rhymeDeviates = breaksEstablishedRhyme(
                    at: index, in: section.lines, template: template, detector: detector)

                guard meterDeviates, rhymeDeviates else { continue }

                var reason =
                    "Off the \(section.label) pattern — \(actualSyllables) syllables "
                    + "(expected ~\(expectedSyllables)) and breaks the established rhyme."
                if index < template.chordCountPattern.count {
                    let expectedChords = template.chordCountPattern[index]
                    let actualChords = collapsedChordCount(
                        section.chords.filter { $0.time >= line.start && $0.time < line.end })
                    if expectedChords > 0, actualChords != expectedChords {
                        reason +=
                            " Chord count also differs (\(actualChords) vs \(expectedChords))."
                    }
                }
                result[line.id] = reason
            }
        }
        return result
    }

    /// Chord-event count with consecutive same-label sustains collapsed to one — mirrors the
    /// dedup rule in `SongStructureOverviewBuilder.chordSignature` without needing that
    /// function's `MusicalKey`-relative numeral mapping (irrelevant to a plain count).
    private static func collapsedChordCount(_ chords: [EditableChordEvent]) -> Int {
        let sorted = chords.sorted { $0.time < $1.time }
        var count = 0
        var lastLabel: String?
        for chord in sorted where chord.chord != lastLabel {
            count += 1
            lastLabel = chord.chord
        }
        return count
    }

    /// Whether the ACTUAL line at `index` breaks a rhyme partnership the template establishes:
    /// the template pairs this line's position with another position under the same rhyme
    /// letter, but the CURRENT words at those two positions no longer actually rhyme.
    ///
    /// Deliberately compares real words directly via `RhymeDetector.rhymes`, not the letter
    /// LABELS `PhraseTemplate.rhymeScheme`/`SongStructureOverviewBuilder.rhymeScheme(for:)`
    /// produce — those letters are assigned positionally, fresh, on every call (first line to
    /// introduce a rhyme part in THAT call gets the next letter). Two independently-computed
    /// schemes can coincidentally land on the same letter at the same index without meaning the
    /// same phonetic class (e.g. a template's index-2 "B" from a dog/frog pair and an unrelated
    /// occurrence's index-2 "B" from an entirely different word, simply because both happened to
    /// be the second unique rhyme part introduced in their own line sequence) — comparing letter
    /// strings directly would silently miss real rhyme breaks like that.
    private static func breaksEstablishedRhyme(
        at index: Int, in lines: [TimedLyricSegment],
        template: SongStructureOverview.PhraseTemplate, detector: RhymeDetector
    ) -> Bool {
        let letter = template.rhymeScheme[index]
        guard letter != "-" else { return false }
        guard
            let partnerIndex = template.rhymeScheme.indices.first(where: {
                $0 != index && template.rhymeScheme[$0] == letter
            }), partnerIndex < lines.count
        else { return false }
        guard let wordA = lastWord(of: lines[index]), let wordB = lastWord(of: lines[partnerIndex])
        else { return false }
        return !detector.rhymes(wordA, wordB)
    }

    /// Same extraction rule as `SongStructureOverviewBuilder.lastWord(of:)` (private to that
    /// type) — duplicated rather than exposed, since it's a one-line rule and this keeps the
    /// builder's internals from growing a wider public surface just for this.
    private static func lastWord(of line: TimedLyricSegment) -> String? {
        line.text.split { !$0.isLetter && $0 != "'" }.last.map(String.init)
    }
}
