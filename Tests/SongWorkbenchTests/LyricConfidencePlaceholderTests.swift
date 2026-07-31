import XCTest

@testable import SongWorkbench

final class LyricConfidencePlaceholderTests: XCTestCase {
    private func word(
        _ text: String, _ start: TimeInterval, _ end: TimeInterval, _ lower: Int,
        confidence: Float?
    ) -> TimedLyricWord {
        TimedLyricWord(
            text: text, start: start, end: end, characterRange: lower..<(lower + text.count),
            confidence: confidence)
    }

    /// Every consumer indexes into `text` with `characterRange`, so a replacement that changes a
    /// word's length must rebuild every following range or the whole line silently mis-slices.
    private func assertRangesMatchText(
        _ segment: TimedLyricSegment, file: StaticString = #filePath, line: UInt = #line
    ) {
        let characters = Array(segment.text)
        XCTAssertEqual(
            segment.words.map(\.text).joined(separator: " "), segment.text,
            "text must stay the words joined by single spaces", file: file, line: line)
        for word in segment.words {
            XCTAssertTrue(
                word.characterRange.upperBound <= characters.count, "range out of bounds",
                file: file, line: line)
            XCTAssertEqual(
                String(characters[word.characterRange]), word.text,
                "characterRange must slice its own word", file: file, line: line)
        }
    }

    func testLowConfidenceWordBecomesPlaceholderAndRangesAreRebuilt() {
        let segment = TimedLyricSegment(
            start: 89.69, end: 92.48, text: "The skirts settle",
            words: [
                word("The", 89.69, 89.9, 0, confidence: 0.95),
                word("skirts", 90.0, 90.5, 4, confidence: 0.13),
                word("settle", 90.6, 91.2, 11, confidence: 0.88),
            ])
        let out = LyricConfidencePlaceholder.applied(to: [segment])[0]
        XCTAssertEqual(out.text, "The ___ settle")
        XCTAssertEqual(out.words.map(\.text), ["The", "___", "settle"])
        assertRangesMatchText(out)
        // Timings are untouched — the ball and the chord strip stay anchored.
        XCTAssertEqual(out.words.map(\.start), segment.words.map(\.start))
        XCTAssertEqual(out.words.map(\.end), segment.words.map(\.end))
        XCTAssertEqual(out.start, segment.start)
        XCTAssertEqual(out.end, segment.end)
    }

    /// The safety property. `nil` means the engine reported NO confidence, not zero confidence —
    /// Parakeet does this on some paths, and reference-lyric-aligned words never carry one.
    /// Treating `nil` as uncertain would replace an entire song with placeholders.
    func testNilConfidenceIsNeverTreatedAsLowConfidence() {
        let segment = TimedLyricSegment(
            start: 0, end: 3, text: "one two three",
            words: [
                word("one", 0, 1, 0, confidence: nil),
                word("two", 1, 2, 4, confidence: nil),
                word("three", 2, 3, 8, confidence: nil),
            ])
        XCTAssertEqual(LyricConfidencePlaceholder.applied(to: [segment]), [segment])
    }

    func testTrailingSentencePunctuationSurvivesThePlaceholder() {
        let segment = TimedLyricSegment(
            start: 34.8, end: 36.86, text: "every father's sin.",
            words: [
                word("every", 34.8, 35.0, 0, confidence: 0.99),
                word("father's", 35.1, 35.4, 6, confidence: 0.72),
                word("sin.", 35.5, 36.0, 15, confidence: 0.0),
            ])
        let out = LyricConfidencePlaceholder.applied(to: [segment])[0]
        XCTAssertEqual(out.text, "every father's ___.")
        assertRangesMatchText(out)
    }

    func testConfidentLineIsReturnedUnchanged() {
        let segment = TimedLyricSegment(
            start: 0, end: 2, text: "clear as day",
            words: [
                word("clear", 0, 0.5, 0, confidence: 0.9),
                word("as", 0.6, 0.8, 6, confidence: 0.85),
                word("day", 0.9, 1.4, 9, confidence: 0.99),
            ])
        XCTAssertEqual(LyricConfidencePlaceholder.applied(to: [segment]), [segment])
    }

    func testPassCanBeDisabled() {
        let segment = TimedLyricSegment(
            start: 0, end: 1, text: "mud",
            words: [word("mud", 0, 1, 0, confidence: 0.01)])
        XCTAssertEqual(
            LyricConfidencePlaceholder.applied(to: [segment], minimumConfidence: nil), [segment])
    }

    /// Function words are left alone however low the score. ASR is structurally unsure about short
    /// unstressed words; blanking "and" destroys a word that was almost certainly right.
    func testFunctionWordsAreNeverBlanked() {
        let segment = TimedLyricSegment(
            start: 0, end: 3, text: "break and a bar",
            words: [
                word("break", 0, 0.5, 0, confidence: 0.9),
                word("and", 0.6, 0.8, 6, confidence: 0.34),
                word("a", 0.9, 1.0, 10, confidence: 0.08),
                word("bar", 1.1, 1.6, 12, confidence: 0.92),
            ])
        XCTAssertEqual(LyricConfidencePlaceholder.applied(to: [segment]), [segment])
    }

    /// The discriminator: same low score, but a content word IS blanked.
    func testLowConfidenceContentWordIsBlankedAlongsideAFunctionWord() {
        let segment = TimedLyricSegment(
            start: 0, end: 3, text: "a salty breach",
            words: [
                word("a", 0, 0.2, 0, confidence: 0.08),
                word("salty", 0.3, 0.7, 2, confidence: 0.91),
                word("breach", 0.8, 1.4, 8, confidence: 0.22),
            ])
        let out = LyricConfidencePlaceholder.applied(to: [segment])[0]
        XCTAssertEqual(out.text, "a salty ___")
        assertRangesMatchText(out)
    }

    /// A rendered word can span several tokens ("father" + "'s"). It is only as trustworthy as its
    /// least certain token, so the word carries the MINIMUM.
    func testGrouperCarriesMinimumTokenConfidenceOntoEachWord() {
        let grouped = TimedLyricSegmentGrouper.group(tokens: [
            TimedTranscriptionToken(text: "father", startTime: 0.0, endTime: 0.4, confidence: 0.2),
            TimedTranscriptionToken(text: "'s", startTime: 0.4, endTime: 0.5, confidence: 0.9),
            TimedTranscriptionToken(text: "sin", startTime: 0.6, endTime: 1.0, confidence: 0.8),
        ])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].words.map(\.text), ["father's", "sin"])
        XCTAssertEqual(try XCTUnwrap(grouped[0].words[0].confidence), 0.2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(grouped[0].words[1].confidence), 0.8, accuracy: 1e-6)
    }

    /// Ordering contract with `RepeatedLyricCorrector`: the placeholder pass runs LAST so a shaky
    /// word can first be repaired from the song's own repeats. That only works if the repair
    /// clears the stale token confidence — otherwise the corrected word is blanked anyway.
    func testCorrectedWordIsNotBlankedOnStaleConfidence() {
        func line(_ text: String, _ base: TimeInterval, garble: String?) -> TimedLyricSegment {
            var lower = 0
            var words: [TimedLyricWord] = []
            for (i, raw) in text.split(separator: " ").enumerated() {
                let w = (i == 2 && garble != nil) ? garble! : String(raw)
                words.append(
                    word(
                        w, base + Double(i) * 0.4, base + Double(i) * 0.4 + 0.3, lower,
                        confidence: (i == 2 && garble != nil) ? 0.05 : 0.95))
                lower += w.count + 1
            }
            return TimedLyricSegment(
                start: base, end: base + 3,
                text: words.map(\.text).joined(separator: " "), words: words)
        }
        let clean = "ain't no runnin from the debt"
        let segments = [
            line(clean, 0, garble: nil),
            line(clean, 10, garble: nil),
            line(clean, 20, garble: "walkin"),
        ]
        let corrected = RepeatedLyricCorrector().corrected(segments)
        XCTAssertEqual(corrected[2].words[2].text, "runnin", "precondition: the repeat fixed it")
        XCTAssertNil(corrected[2].words[2].confidence, "stale confidence must be cleared")
        let final = LyricConfidencePlaceholder.applied(to: corrected)
        XCTAssertEqual(final[2].text, clean, "a repaired word must not then be blanked")
    }

    /// A user's own correction outranks the transcriber. A Review-chart override lives BESIDE
    /// `text`, so the line still carries its original low-confidence words — blanking them would
    /// visibly corrupt the correction wherever words are drawn individually.
    func testLineWithAUserOverrideIsNeverBlanked() {
        var segment = TimedLyricSegment(
            start: 0, end: 2, text: "the skirts settle",
            words: [
                word("the", 0, 0.3, 0, confidence: 0.9),
                word("skirts", 0.4, 0.8, 4, confidence: 0.05),
                word("settle", 0.9, 1.4, 11, confidence: 0.9),
            ])
        XCTAssertNotEqual(
            LyricConfidencePlaceholder.applied(to: [segment]), [segment],
            "precondition: without an override this line IS blanked")

        segment.overrideText = "a score to settle"
        XCTAssertEqual(LyricConfidencePlaceholder.applied(to: [segment]), [segment])
    }

    func testBlankWhitespaceOverrideDoesNotCountAsACorrection() {
        var segment = TimedLyricSegment(
            start: 0, end: 1, text: "mud",
            words: [word("mud", 0, 1, 0, confidence: 0.01)])
        segment.overrideText = "   "
        XCTAssertEqual(LyricConfidencePlaceholder.applied(to: [segment])[0].text, "___")
    }

    /// Additive schema field: a document written before it existed must still decode.
    func testWordConfidenceDecodesAsNilWhenAbsent() throws {
        let json = Data(
            #"{"text":"He","start":1.0,"end":1.5,"characterRange":[0,2]}"#.utf8)
        let decoded = try JSONDecoder().decode(TimedLyricWord.self, from: json)
        XCTAssertNil(decoded.confidence)
        XCTAssertEqual(decoded.text, "He")
    }
}
