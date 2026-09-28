import AVFoundation
import Foundation

/// Replaces the transcriber's guessed word times with times MEASURED off the vocal stem.
///
/// This is where the analysis pipeline stops trusting the ASR's timestamps. Whisper and Parakeet
/// produce word times as a by-product of decoding, not as a measurement, and every heuristic that
/// used to repair them has been removed. Forced alignment measures instead: the words are already
/// known, so the only question is where in the audio each one is sung, and Viterbi over the
/// acoustic model's posteriorgram answers it from the signal.
///
/// Applied only with an isolated vocals stem. On a full mix the acoustic model is out of its
/// training domain (it was trained on separated vocals), and the measured evidence on our own
/// library is that a domain mismatch makes alignment WORSE, not merely noisier.
///
/// Never degrades to the transcriber's times (Eric, 2026-09-26: lyric starts are anchored to
/// onsets in the audio ONLY): a missing model, undecodable audio or a failed alignment throws, and
/// the transcription stage fails with it.
/// Measures word times for `lyrics` on the vocals stem at `vocalsURL`; `onsets` are that stem's
/// measured onsets, used to place words the aligner could not.
typealias WordTimeMeasurer =
    @Sendable (_ lyrics: [TimedLyricSegment], _ vocalsURL: URL, _ onsets: [TimeInterval]) throws
    -> (lyrics: [TimedLyricSegment], outcome: MeasuredLyricTiming.Outcome)

/// The alignment model's posteriorgram of the vocals stem at a URL.
typealias VocalPosteriorgram = @Sendable (_ vocalsURL: URL) throws -> [[Float]]

enum MeasuredLyricTiming {
    /// `ForcedLyricAligner.posteriorgram` of the vocals stem, with the bundled model.
    @Sendable
    static func posteriorgramWithBundledModel(_ vocalsURL: URL) throws -> [[Float]] {
        guard let model = CoreMLLyricsAcousticModel.load() else {
            throw SongAnalysisPipelineError.missingBundledModel("LyricsAlignmentMTL")
        }
        let samples = try monoSamples(at: vocalsURL)
        guard !samples.isEmpty else { throw Failure.emptyVocalsStem }
        return try ForcedLyricAligner.posteriorgram(
            mel: LyricsAlignmentMel.spectrogram(samples: samples), model: model)
    }

    enum Failure: Error, Equatable {
        case emptyVocalsStem
        /// Alignment ran but placed no word at all: nothing anchors any line.
        case nothingMeasured
    }

    /// The pipeline's measuring step: the bundled alignment model over the vocals stem.
    @Sendable
    static func measuredWithBundledModel(
        _ lyrics: [TimedLyricSegment], vocalsURL: URL, onsets: [TimeInterval]
    ) throws -> (lyrics: [TimedLyricSegment], outcome: Outcome) {
        guard let model = CoreMLLyricsAcousticModel.load() else {
            throw SongAnalysisPipelineError.missingBundledModel("LyricsAlignmentMTL")
        }
        return try applied(to: lyrics, stemURL: vocalsURL, onsets: onsets, model: model)
    }

    /// What happened, for the stage record and for logging.
    struct Outcome: Equatable, Sendable {
        var measured = 0
        var filledFromOnsets = 0
        /// Words neither alignment nor an onset placed: they are stored with no time.
        var unmeasured = 0
        var ran = false
    }

    /// - Parameters:
    ///   - lyrics: lines whose WORDS are trusted but whose TIMES are not.
    ///   - stemURL: the isolated vocals stem.
    ///   - onsets: measured vocal-stem onsets, used to place words the aligner could not.
    static func applied(
        to lyrics: [TimedLyricSegment],
        stemURL: URL,
        onsets: [TimeInterval],
        model: LyricsAcousticModel,
        phonemizer: LyricPhonemizer = .shared
    ) throws -> (lyrics: [TimedLyricSegment], outcome: Outcome) {
        var outcome = Outcome()
        let words = lyrics.flatMap(\.words)
        guard !words.isEmpty else { return (lyrics, outcome) }

        let samples = try monoSamples(at: stemURL)
        guard !samples.isEmpty else { throw Failure.emptyVocalsStem }
        let aligned = try ForcedLyricAligner.align(
            samples: samples, words: words.map(\.text), model: model, phonemizer: phonemizer)

        let beforeFill = aligned.filter { $0.start != nil }.count
        let filled = ForcedLyricAligner.filledFromOnsets(aligned, onsets: onsets)
        outcome.ran = true
        outcome.measured = beforeFill
        outcome.filledFromOnsets = filled.filter { $0.start != nil }.count - beforeFill
        outcome.unmeasured = filled.filter { $0.start == nil }.count
        guard outcome.unmeasured < filled.count else { throw Failure.nothingMeasured }

        // Write the measured times back, keeping every word and its text exactly as it was.
        var cursor = 0
        let rewritten = lyrics.map { line -> TimedLyricSegment in
            var updated = line
            updated.words = line.words.map { word in
                defer { cursor += 1 }
                var copy = word
                guard cursor < filled.count, let start = filled[cursor].start,
                    let end = filled[cursor].end
                else {
                    // Unmeasured: the word has NO time (Eric, 2026-09-27). The transcriber's time
                    // is a by-product of decoding, not a measurement, and is never kept.
                    copy.start = nil
                    copy.end = nil
                    return copy
                }
                copy.start = start
                copy.end = max(start, end)
                return copy
            }
            if let start = updated.words.firstStart, let end = updated.words.lastEnd {
                updated.start = start
                updated.end = max(end, start)
            }
            return updated
        }
        return (withUnplacedLinesJoined(rewritten), outcome)
    }

    /// A line needs a start, and one whose words were ALL unmeasured has none that was measured.
    /// Its words (text intact, no times) join the line before it — or the line after it when it
    /// comes first — whose measured bounds stand. `lines` must hold at least one measured word.
    static func withUnplacedLinesJoined(_ lines: [TimedLyricSegment]) -> [TimedLyricSegment] {
        func isPlaced(_ line: TimedLyricSegment) -> Bool { line.words.firstStart != nil }
        var result: [TimedLyricSegment] = []
        var leading: [TimedLyricSegment] = []
        for line in lines {
            if isPlaced(line) {
                var anchored = line
                for unplaced in leading.reversed() { anchored = joined(unplaced, before: anchored) }
                leading = []
                result.append(anchored)
            } else if let last = result.popLast() {
                result.append(joined(line, after: last))
            } else {
                leading.append(line)
            }
        }
        return result
    }

    /// `anchor` with `extra`'s words appended; `anchor`'s id, flags and bounds are kept.
    private static func joined(_ extra: TimedLyricSegment, after anchor: TimedLyricSegment)
        -> TimedLyricSegment
    {
        var result = anchor
        let offset = anchor.text.count + 1
        result.text = anchor.text + " " + extra.text
        result.words = anchor.words + extra.words.map { shifted($0, by: offset) }
        return result
    }

    /// `anchor` with `extra`'s words prepended; `anchor`'s id, flags and bounds are kept.
    private static func joined(_ extra: TimedLyricSegment, before anchor: TimedLyricSegment)
        -> TimedLyricSegment
    {
        var result = anchor
        let offset = extra.text.count + 1
        result.text = extra.text + " " + anchor.text
        result.words = extra.words + anchor.words.map { shifted($0, by: offset) }
        return result
    }

    private static func shifted(_ word: TimedLyricWord, by offset: Int) -> TimedLyricWord {
        var copy = word
        copy.characterRange =
            (word.characterRange.lowerBound + offset)..<(word.characterRange.upperBound + offset)
        return copy
    }

    /// Mono samples at the rate the acoustic model expects.
    ///
    /// Channels are averaged BEFORE resampling, which is what the reference implementation does;
    /// letting a converter do both at once produced a measurably different signal and moved a
    /// minority of word onsets. Rate conversion reuses `BasicPitchNoteTranscriber.resampled`,
    /// which drains the converter properly — a single pull can silently truncate.
    static func monoSamples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            mono[frame] = sum / Float(channelCount)
        }

        guard format.sampleRate != LyricsAlignmentMel.sampleRate else { return mono }
        return try BasicPitchNoteTranscriber.resampled(mono, from: format.sampleRate)
    }
}
