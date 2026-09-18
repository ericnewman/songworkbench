import Foundation

/// Emits a CTC phoneme posteriorgram for a mel spectrogram.
///
/// A protocol so the windowing and word-mapping around it can be tested without the model file,
/// and so the acoustic model can be swapped (LyricsAlignment-MTL today; Parakeet-CTC via
/// FluidAudio is the documented fallback) without touching anything that consumes it.
protocol LyricsAcousticModel: Sendable {
    /// Mel frames a single evaluation consumes. The converted model has a fixed input length.
    var melFramesPerWindow: Int { get }
    /// `[outputFrame][class]` log-probabilities for exactly `melFramesPerWindow` mel frames.
    func logProbabilities(melWindow: [[Float]]) throws -> [[Float]]
}

/// Measures when each known lyric word is sung, by aligning its phonemes to the vocal stem.
///
/// The whole point: word times come out of the audio, never out of arithmetic on other word times.
/// A word this cannot measure — one we cannot pronounce, or one the Viterbi path never visits —
/// is returned with a `nil` time rather than a plausible-looking interpolation.
enum ForcedLyricAligner {

    /// One word's measured time, or the fact that it has none.
    struct AlignedWord: Equatable, Sendable {
        let text: String
        /// Seconds into the audio, or nil when the word could not be measured.
        let start: TimeInterval?
        let end: TimeInterval?
        let reason: Unmeasured?

        enum Unmeasured: String, Equatable, Sendable {
            /// No pronunciation, so it was never in the token sequence.
            case unpronounceable
            /// Pronounceable, but the alignment path never visited its phonemes.
            case notOnThePath
        }
    }

    enum Failure: Error, Equatable {
        case noAudio
        case noPronounceableWords
        case audioTooShort(frames: Int, minimumRequired: Int)
    }

    /// The model pools time by 3, so one output frame spans three mel hops.
    static let outputFrameDuration: TimeInterval =
        3 * Double(LyricsAlignmentMel.hop) / LyricsAlignmentMel.sampleRate  // ≈ 0.034830 s

    /// - Parameters:
    ///   - samples: mono vocal-stem samples at `LyricsAlignmentMel.sampleRate`.
    ///   - words: the words known to be sung, in order.
    static func align(
        samples: [Float],
        words: [String],
        model: LyricsAcousticModel,
        phonemizer: LyricPhonemizer = .shared
    ) throws -> [AlignedWord] {
        guard !samples.isEmpty else { throw Failure.noAudio }

        let pronounced = phonemizer.words(for: words)
        let (tokens, ranges) = LyricPhonemizer.tokenSequence(for: pronounced)
        guard !tokens.isEmpty else { throw Failure.noPronounceableWords }

        let mel = LyricsAlignmentMel.spectrogram(samples: samples)
        let logProbs = try posteriorgram(mel: mel, model: model)

        let spans: [CTCForcedAlignment.TokenSpan]
        do {
            spans = try CTCForcedAlignment.align(
                logProbs: logProbs, tokens: tokens, blank: ArpabetVocabulary.blankIndex)
        } catch CTCForcedAlignment.Failure.audioTooShort(let frames, let minimum) {
            throw Failure.audioTooShort(frames: frames, minimumRequired: minimum)
        }

        return pronounced.enumerated().map { index, word in
            guard let range = ranges[index], !range.isEmpty else {
                return AlignedWord(
                    text: word.text, start: nil, end: nil, reason: .unpronounceable)
            }
            let owned = spans[range.lowerBound..<range.upperBound]
            let firstFrame = owned.map(\.startFrame).filter { $0 >= 0 }.min()
            let lastFrame = owned.map(\.endFrame).filter { $0 >= 0 }.max()
            guard let firstFrame, let lastFrame else {
                return AlignedWord(text: word.text, start: nil, end: nil, reason: .notOnThePath)
            }
            return AlignedWord(
                text: word.text,
                start: Double(firstFrame) * outputFrameDuration,
                // A frame spans its own duration, so the word ends at the END of its last frame.
                end: Double(lastFrame + 1) * outputFrameDuration,
                reason: nil)
        }
    }

    /// Gives an unmeasured word a time when the vocal stem says, unambiguously, where it is sung.
    ///
    /// A word we cannot pronounce is never in the token sequence, so the aligner has nothing to
    /// measure it with — but the audio still does. Between its measured neighbours the stem has
    /// onsets, and an onset is a measured fact about when singing started.
    ///
    /// The whole discipline is in refusing the ambiguous case. A run of `n` unmeasured words is
    /// filled ONLY when the gap holds exactly `n` onsets: then the assignment is forced by the
    /// audio and nothing is chosen. With more or fewer onsets than words we would be picking among
    /// candidates, which is a guess wearing a measurement's clothes, so those words stay
    /// unmeasured. Nothing here interpolates, spreads, or derives a time from another word's time.
    ///
    /// - Parameter onsets: measured vocal-stem onsets, ascending — the same ones the final onset
    ///   snap uses.
    static func filledFromOnsets(_ words: [AlignedWord], onsets: [TimeInterval]) -> [AlignedWord] {
        guard !onsets.isEmpty, words.contains(where: { $0.start == nil }) else { return words }
        var result = words

        var index = 0
        while index < result.count {
            guard result[index].start == nil else {
                index += 1
                continue
            }
            // The maximal run of unmeasured words, and the measured times bracketing it.
            var end = index
            while end + 1 < result.count, result[end + 1].start == nil { end += 1 }
            let lowerBound = index > 0 ? result[index - 1].end : 0
            let upperBound =
                end + 1 < result.count
                ? result[end + 1].start : TimeInterval.greatestFiniteMagnitude

            if let lowerBound, let upperBound, upperBound > lowerBound {
                let inside = onsets.filter { $0 >= lowerBound && $0 < upperBound }
                let runLength = end - index + 1
                if inside.count == runLength {
                    for offset in 0..<runLength {
                        let start = inside[offset]
                        // The word lasts until the next measured event — the following onset, or
                        // the next measured word. That boundary is measured too, not assumed.
                        let next =
                            offset + 1 < inside.count ? inside[offset + 1] : upperBound
                        result[index + offset] = AlignedWord(
                            text: result[index + offset].text,
                            start: start,
                            end: max(start, next),
                            reason: nil)
                    }
                }
            }
            index = end + 1
        }
        return result
    }

    /// Runs the fixed-length model across the whole song and splices the result.
    ///
    /// The model sees a bounded window, but its three bidirectional LSTMs use the whole window for
    /// context, so frames near a window edge are informed by less audio than frames in the middle.
    /// Windows therefore OVERLAP and only each window's interior is kept: every output frame comes
    /// from a window that saw context on both sides of it, except at the song's own ends where no
    /// such context exists.
    static func posteriorgram(mel: [[Float]], model: LyricsAcousticModel) throws -> [[Float]] {
        let windowFrames = model.melFramesPerWindow
        guard windowFrames > 0 else { return [] }
        guard mel.count > windowFrames else {
            // One window covers it; pad the tail with silence-shaped frames and trim the output.
            let usable = mel.count / 3
            var padded = mel
            let bands = mel.first?.count ?? LyricsAlignmentMel.melBands
            padded += Array(
                repeating: [Float](repeating: 0, count: bands),
                count: max(0, windowFrames - mel.count))
            return Array(try model.logProbabilities(melWindow: padded).prefix(usable))
        }

        // Discard a quarter-window at each internal edge; the step is what remains.
        let margin = (windowFrames / 4) - ((windowFrames / 4) % 3)
        let step = windowFrames - 2 * margin
        var output: [[Float]] = []
        var start = 0
        while start < mel.count {
            let isFirst = start == 0
            let end = min(start + windowFrames, mel.count)
            var window = Array(mel[start..<end])
            let bands = mel.first?.count ?? LyricsAlignmentMel.melBands
            if window.count < windowFrames {
                window += Array(
                    repeating: [Float](repeating: 0, count: bands),
                    count: windowFrames - window.count)
            }
            let frames = try model.logProbabilities(melWindow: window)
            let isLast = end >= mel.count

            let dropLeading = isFirst ? 0 : margin / 3
            // The tail window is padded with silence; keep only frames backed by real audio.
            let realFrames = isLast ? (end - start) / 3 : frames.count
            let dropTrailing = isLast ? max(0, frames.count - realFrames) : margin / 3
            let upper = max(dropLeading, frames.count - dropTrailing)
            output += frames[dropLeading..<upper]

            if isLast { break }
            start += step
        }
        return Array(output.prefix(mel.count / 3))
    }
}
