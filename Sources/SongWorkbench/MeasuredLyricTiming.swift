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
/// Degrades to a no-op — keeping the transcriber's times — whenever the model is absent, the audio
/// cannot be decoded, or alignment throws. A missing bundled model must never fail an analysis.
enum MeasuredLyricTiming {

    /// What happened, for the stage record and for logging.
    struct Outcome: Equatable, Sendable {
        var measured = 0
        var filledFromOnsets = 0
        var keptTranscriberTime = 0
        var ran = false
    }

    /// - Parameters:
    ///   - lyrics: lines whose WORDS are trusted but whose TIMES are not.
    ///   - stemURL: the isolated vocals stem, or nil to skip.
    ///   - onsets: measured vocal-stem onsets, used to place words the aligner could not.
    static func applied(
        to lyrics: [TimedLyricSegment],
        stemURL: URL?,
        onsets: [TimeInterval],
        model: LyricsAcousticModel? = CoreMLLyricsAcousticModel.load(),
        phonemizer: LyricPhonemizer = .shared
    ) -> (lyrics: [TimedLyricSegment], outcome: Outcome) {
        var outcome = Outcome()
        guard let stemURL, let model, !lyrics.isEmpty else { return (lyrics, outcome) }

        let words = lyrics.flatMap(\.words)
        guard !words.isEmpty else { return (lyrics, outcome) }

        guard let samples = try? monoSamples(at: stemURL), !samples.isEmpty else {
            return (lyrics, outcome)
        }
        guard
            let aligned = try? ForcedLyricAligner.align(
                samples: samples, words: words.map(\.text), model: model, phonemizer: phonemizer)
        else { return (lyrics, outcome) }

        let beforeFill = aligned.filter { $0.start != nil }.count
        let filled = ForcedLyricAligner.filledFromOnsets(aligned, onsets: onsets)
        outcome.ran = true
        outcome.measured = beforeFill
        outcome.filledFromOnsets = filled.filter { $0.start != nil }.count - beforeFill
        outcome.keptTranscriberTime = filled.filter { $0.start == nil }.count

        // Write the measured times back, keeping every word and its text exactly as it was.
        var cursor = 0
        let rewritten = lyrics.map { line -> TimedLyricSegment in
            var updated = line
            updated.words = line.words.map { word in
                defer { cursor += 1 }
                guard cursor < filled.count, let start = filled[cursor].start,
                    let end = filled[cursor].end
                else {
                    // Unmeasured: the transcriber's time stands. It is a poor estimate, but it is
                    // the ASR's own output — we do not invent a replacement for it here.
                    return word
                }
                var copy = word
                copy.start = start
                copy.end = max(start, end)
                return copy
            }
            updated.start = updated.words.first?.start ?? line.start
            updated.end = max(updated.words.last?.end ?? line.end, updated.start)
            return updated
        }
        return (rewritten, outcome)
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
