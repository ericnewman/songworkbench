import XCTest

@testable import SongWorkbench

final class LyricPhonemizerTests: XCTestCase {

    private func phonemizer(_ entries: [String: [String]]) -> LyricPhonemizer {
        LyricPhonemizer(
            pronunciations: entries.mapValues { $0.compactMap(ArpabetVocabulary.index(of:)) })
    }

    // MARK: - Vocabulary

    /// The class list is the model's, not ours. If this drifts, every emitted frame is mis-mapped.
    func testVocabularyMatchesTheModelsClassList() {
        XCTAssertEqual(ArpabetVocabulary.classCount, 41)
        XCTAssertEqual(ArpabetVocabulary.phones.count, 40, "39 phones plus the space")
        XCTAssertEqual(ArpabetVocabulary.phones.first, "AA")
        XCTAssertEqual(ArpabetVocabulary.phones[38], "ZH")
        XCTAssertEqual(ArpabetVocabulary.phones[ArpabetVocabulary.separatorIndex], " ")
        XCTAssertEqual(ArpabetVocabulary.separatorIndex, 39)
        XCTAssertEqual(ArpabetVocabulary.blankIndex, 40)
        XCTAssertEqual(ArpabetVocabulary.index(of: "AA"), 0)
        XCTAssertEqual(ArpabetVocabulary.index(of: "ZH"), 38)
        XCTAssertNil(ArpabetVocabulary.index(of: "AA1"), "stress digits are stripped before lookup")
    }

    // MARK: - Lookup and the measured fallbacks

    func testLooksUpAKnownWord() {
        let p = phonemizer(["love": ["L", "AH", "V"]])
        XCTAssertEqual(
            p.phones(for: "love"),
            ["L", "AH", "V"].compactMap(ArpabetVocabulary.index(of:)))
    }

    func testNormalisesCaseAndPunctuation() {
        let p = phonemizer(["love": ["L", "AH", "V"]])
        XCTAssertEqual(p.phones(for: "Love,"), p.phones(for: "love"))
        XCTAssertEqual(p.phones(for: "  LOVE!  "), p.phones(for: "love"))
    }

    /// Each fallback below exists for a form measured in the library's own OOV list on
    /// 2026-09-18 — they are morphology, not guesswork about spelling.
    func testRecoversDroppedGSpellings() {
        let p = phonemizer(["moving": ["M", "UW", "V", "IH", "NG"]])
        XCTAssertEqual(p.phones(for: "movin'"), p.phones(for: "moving"), "movin' -> moving")
    }

    func testRecoversPossessivesAndContractions() {
        let p = phonemizer(["flow": ["F", "L", "OW"]])
        XCTAssertEqual(p.phones(for: "flow's"), p.phones(for: "flow"))
    }

    func testRecoversClosedCompounds() {
        let p = phonemizer([
            "flip": ["F", "L", "IH", "P"], "flops": ["F", "L", "AA", "P", "S"],
        ])
        XCTAssertEqual(
            p.phones(for: "flipflops"),
            (p.phones(for: "flip") ?? []) + (p.phones(for: "flops") ?? []))
    }

    /// The point of the whole change: we do not invent. An invented pronunciation would still be
    /// aligned, producing a confident wrong time — a fabricated time by a longer route.
    func testUnknownWordIsReportedRatherThanGuessed() {
        let p = phonemizer(["love": ["L", "AH", "V"]])
        XCTAssertNil(p.phones(for: "biccuyecle"))

        let words = p.words(for: ["love", "biccuyecle", "love"])
        XCTAssertTrue(words[0].isPronounceable)
        XCTAssertFalse(words[1].isPronounceable)
        XCTAssertTrue(words[2].isPronounceable)
    }

    // MARK: - Token sequence

    func testTokenSequenceSeparatesWordsWithTheSpaceClass() {
        let p = phonemizer(["a": ["AH"], "b": ["B", "IY"]])
        let (tokens, ranges) = LyricPhonemizer.tokenSequence(for: p.words(for: ["a", "b"]))

        XCTAssertEqual(
            tokens,
            [
                ArpabetVocabulary.index(of: "AH")!,
                ArpabetVocabulary.separatorIndex,
                ArpabetVocabulary.index(of: "B")!,
                ArpabetVocabulary.index(of: "IY")!,
            ])
        XCTAssertEqual(ranges[0], 0..<1)
        XCTAssertEqual(ranges[1], 2..<4)
    }

    /// An unpronounceable word leaves a hole at its own index; it must not shift its neighbours,
    /// or every later word's time would be attributed to the wrong word.
    func testUnpronounceableWordKeepsItsPlaceAsAHole() {
        let p = phonemizer(["a": ["AH"], "b": ["B", "IY"]])
        let (tokens, ranges) = LyricPhonemizer.tokenSequence(
            for: p.words(for: ["a", "zzzz", "b"]))

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0], 0..<1)
        XCTAssertNil(ranges[1])
        XCTAssertEqual(ranges[2], 2..<4)
        XCTAssertFalse(tokens.contains { $0 < 0 })
    }

    func testNoLeadingSeparator() {
        let p = phonemizer(["a": ["AH"]])
        let (tokens, _) = LyricPhonemizer.tokenSequence(for: p.words(for: ["a"]))
        XCTAssertEqual(tokens, [ArpabetVocabulary.index(of: "AH")!])
    }

    // MARK: - Bundled table

    func testParsesTheBundledTableFormat() {
        let table = LyricPhonemizer.parse(
            """
            # a comment line
            love L AH V
            'bout B AW T
            bogus QQ ZZ
            """)
        XCTAssertEqual(table["love"], ["L", "AH", "V"].compactMap(ArpabetVocabulary.index(of:)))
        XCTAssertEqual(table["'bout"], ["B", "AW", "T"].compactMap(ArpabetVocabulary.index(of:)))
        XCTAssertNil(table["bogus"], "a line with an unknown phone is dropped, not half-parsed")
    }

    /// A missing resource must degrade to "cannot pronounce anything", not crash analysis.
    func testEmptyTableReportsEverythingUnpronounceable() {
        let p = LyricPhonemizer(pronunciations: [:])
        XCTAssertNil(p.phones(for: "love"))
        XCTAssertFalse(p.words(for: ["love"])[0].isPronounceable)
    }
}
