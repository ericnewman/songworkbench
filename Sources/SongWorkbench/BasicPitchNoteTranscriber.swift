import AVFoundation
import Accelerate
import Foundation
import OnnxRuntimeBindings

/// One transcribed note on one stem, in song seconds. `confidence` is the model's mean note
/// posterior over the note (0…1) — a detection certainty, NOT a loudness: separation leakage
/// scores the same as a real part, so level gating stays with the consumers.
/// `pitchBendSemitones` is the mean deviation of the pitch contour from the nominal note.
struct NoteEvent: Codable, Equatable, Sendable {
    var onset: TimeInterval
    var offset: TimeInterval
    var midiNote: Int
    var confidence: Float
    var pitchBendSemitones: Float?

    var duration: TimeInterval { offset - onset }
}

/// Every note event Basic Pitch heard on one stem, sorted by onset. Version-tagged so a change
/// in the model, the front end or the decoder recomputes stored timelines.
struct NoteEventTimeline: Codable, Equatable, Sendable {
    /// Bump when the model artifact, windowing or note decoding changes.
    static let currentVersionTag = "notes-1"

    var versionTag: String
    var stemID: StemID
    var events: [NoteEvent]

    init(stemID: StemID, events: [NoteEvent]) {
        self.versionTag = Self.currentVersionTag
        self.stemID = stemID
        self.events = events.sorted { ($0.onset, $0.midiNote) < ($1.onset, $1.midiNote) }
    }

    var isCurrent: Bool { versionTag == Self.currentVersionTag }

    /// Events sounding anywhere inside `[start, end)`.
    func events(overlapping start: TimeInterval, _ end: TimeInterval) -> [NoteEvent] {
        events.filter { $0.onset < end && $0.offset > start }
    }
}

/// The stitched per-frame posteriors of one stem: `frameCount` rows of `noteBins` note and onset
/// activations and `contourBins` pitch-contour activations, row-major, plus each row's time.
struct BasicPitchPosteriors: Sendable {
    let frameCount: Int
    let frameTimes: [TimeInterval]
    let note: [Float]
    let onset: [Float]
    let contour: [Float]
}

/// Spotify's Basic Pitch (Bittner et al., ICASSP 2022; Apache-2.0, `Resources/nmp.onnx` with its
/// LICENSE beside it) run through the app's onnxruntime. A small instrument-agnostic CNN with a
/// harmonic-CQT front end baked into the graph: 22 050 Hz mono in, per-frame note / onset /
/// pitch-contour posteriors out. Measured 2026-09-08 (tasks/spike-basic-pitch.md): 15 ms per
/// 2 s window, ≈ 1.6 s per 3.5-minute stem, and its per-beat polyphony separates strummed bars
/// from single lines on the SAME stem — which the chroma-sparsity classifier could not.
///
/// One session per instance; `run` is serialised behind a lock so a shared instance can be
/// used from the detached analysis tasks.
final class BasicPitchNoteTranscriber: @unchecked Sendable {
    // Contract (basic_pitch/constants.py + inference.py).
    static let sampleRate: Double = 22050
    static let fftHop = 256
    /// One model window: 2 s minus one hop.
    static let windowSamples = 43844
    static let framesPerWindow = 172
    static let noteBins = 88
    static let contourBins = 264
    static let contourBinsPerSemitone = 3
    static let midiOffset = 21
    /// Windows overlap by 30 frames; half of that is cut from each end of every window's output.
    static let overlapFrames = 30
    static let hopSamples = windowSamples - overlapFrames * fftHop  // 36164
    static let keptFramesPerWindow = framesPerWindow - overlapFrames  // 142
    /// `ANNOTATIONS_FPS = AUDIO_SAMPLE_RATE // FFT_HOP` — integer division in the original.
    static let annotationsPerSecond = 86

    static let inputName = "serving_default_input_2:0"
    static let contourOutput = "StatefulPartitionedCall:0"
    static let noteOutput = "StatefulPartitionedCall:1"
    static let onsetOutput = "StatefulPartitionedCall:2"

    enum Error: Swift.Error {
        case modelNotFound
        case unexpectedOutput
        case unsupportedAudio
    }

    private let session: ORTSession
    private let lock = NSLock()

    /// The bundled model: `Resources/nmp.onnx` in the app bundle, or the file named by
    /// `SW_BASIC_PITCH_MODEL` (tests and diagnostics, which run outside the app bundle).
    static func bundledModelURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["SW_BASIC_PITCH_MODEL"],
            FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.url(forResource: "nmp", withExtension: "onnx")
    }

    /// The process-wide instance over the bundled model; nil when the model is not available.
    static let shared: BasicPitchNoteTranscriber? = {
        guard let url = bundledModelURL() else { return nil }
        return try? BasicPitchNoteTranscriber(modelURL: url)
    }()

    init(modelURL: URL) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        session = try ORTSession(
            env: environment, modelPath: modelURL.path, sessionOptions: options)
    }

    // MARK: - Entry points

    /// Note events for mono `samples` at `sampleRate` (any rate; resampled to 22 050 Hz).
    func transcribe(samples: [Float], sampleRate: Double) throws -> [NoteEvent] {
        let audio = try Self.resampled(samples, from: sampleRate)
        return BasicPitchNoteDecoder.decode(try posteriors(for: audio))
    }

    /// Runs the model over `audio` (22 050 Hz mono) window by window and stitches the outputs
    /// exactly as `basic_pitch.inference.run_inference` does: 15 overlap frames dropped from each
    /// end of every window, concatenated, trimmed to the audio's own frame count.
    func posteriors(for audio: [Float]) throws -> BasicPitchPosteriors {
        guard !audio.isEmpty else {
            return BasicPitchPosteriors(
                frameCount: 0, frameTimes: [], note: [], onset: [], contour: [])
        }
        // Half the overlap of silence in front so the first real frames are not edge frames.
        let frontPad = Self.overlapFrames * Self.fftHop / 2
        let padded = [Float](repeating: 0, count: frontPad) + audio
        let windowCount = (padded.count + Self.hopSamples - 1) / Self.hopSamples
        let keep = Self.keptFramesPerWindow
        let half = Self.overlapFrames / 2
        var note: [Float] = []
        var onset: [Float] = []
        var contour: [Float] = []
        note.reserveCapacity(windowCount * keep * Self.noteBins)
        onset.reserveCapacity(windowCount * keep * Self.noteBins)
        contour.reserveCapacity(windowCount * keep * Self.contourBins)
        var window = [Float](repeating: 0, count: Self.windowSamples)
        for index in 0..<windowCount {
            try Task.checkCancellation()
            let start = index * Self.hopSamples
            let count = min(Self.windowSamples, padded.count - start)
            for offset in 0..<Self.windowSamples {
                window[offset] = offset < count ? padded[start + offset] : 0
            }
            let outputs = try run(window: window)
            Self.append(
                rows: half..<(half + keep), of: outputs.note, width: Self.noteBins, to: &note)
            Self.append(
                rows: half..<(half + keep), of: outputs.onset, width: Self.noteBins, to: &onset)
            Self.append(
                rows: half..<(half + keep), of: outputs.contour, width: Self.contourBins,
                to: &contour)
        }
        let frameCount = min(
            windowCount * keep,
            Int(floor(Double(audio.count) * Double(Self.annotationsPerSecond) / Self.sampleRate)))
        note.removeLast(note.count - frameCount * Self.noteBins)
        onset.removeLast(onset.count - frameCount * Self.noteBins)
        contour.removeLast(contour.count - frameCount * Self.contourBins)
        // Frame j of window w starts at padded sample w·hop + (j + 15)·256, i.e. audio sample
        // w·hop + j·256 — exact, where the original's `model_frames_to_time` approximates the
        // same thing with a per-window offset and a "magic" 1.8 ms.
        let frameTimes = (0..<frameCount).map { frame -> TimeInterval in
            let window = frame / keep
            let row = frame % keep
            return Double(window * Self.hopSamples + row * Self.fftHop) / Self.sampleRate
        }
        return BasicPitchPosteriors(
            frameCount: frameCount, frameTimes: frameTimes, note: note, onset: onset,
            contour: contour)
    }

    // MARK: - Model I/O

    private struct WindowOutputs {
        let note: [Float]
        let onset: [Float]
        let contour: [Float]
    }

    private func run(window: [Float]) throws -> WindowOutputs {
        precondition(window.count == Self.windowSamples)
        let inputData = NSMutableData(length: window.count * MemoryLayout<Float>.size)!
        inputData.mutableBytes.bindMemory(to: Float.self, capacity: window.count)
            .update(from: window, count: window.count)
        let input = try ORTValue(
            tensorData: inputData, elementType: .float,
            shape: [1, NSNumber(value: Self.windowSamples), 1])
        let outputs = try lock.withLock {
            try session.run(
                withInputs: [Self.inputName: input],
                outputNames: [Self.noteOutput, Self.onsetOutput, Self.contourOutput],
                runOptions: nil)
        }
        return WindowOutputs(
            note: try Self.floats(
                outputs[Self.noteOutput], count: Self.framesPerWindow * Self.noteBins),
            onset: try Self.floats(
                outputs[Self.onsetOutput], count: Self.framesPerWindow * Self.noteBins),
            contour: try Self.floats(
                outputs[Self.contourOutput], count: Self.framesPerWindow * Self.contourBins))
    }

    private static func floats(_ value: ORTValue?, count: Int) throws -> [Float] {
        guard let value else { throw Error.unexpectedOutput }
        let data = try value.tensorData()
        guard data.length == count * MemoryLayout<Float>.size else { throw Error.unexpectedOutput }
        let pointer = data.bytes.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private static func append(
        rows: Range<Int>, of matrix: [Float], width: Int, to target: inout [Float]
    ) {
        target.append(contentsOf: matrix[(rows.lowerBound * width)..<(rows.upperBound * width)])
    }

    // MARK: - Resampling

    /// `samples` at 22 050 Hz mono. Drains the converter until `.endOfStream`, since one pull is
    /// not guaranteed to flush a rate conversion (see `CoreMLStemSeparationEngine`).
    static func resampled(_ samples: [Float], from sampleRate: Double) throws -> [Float] {
        guard sampleRate > 0, !samples.isEmpty else { throw Error.unsupportedAudio }
        if sampleRate == Self.sampleRate { return samples }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
                interleaved: false),
            let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw Error.unsupportedAudio }
        input.frameLength = AVAudioFrameCount(samples.count)
        input.floatChannelData![0].update(from: samples, count: samples.count)

        let ratio = Self.sampleRate / sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 1
        let provider = SingleBufferInputProvider(buffer: input)
        var output: [Float] = []
        output.reserveCapacity(Int(capacity))
        var emptyPulls = 0
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            else { throw Error.unsupportedAudio }
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { _, flag in
                provider.next(status: flag)
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw Error.unsupportedAudio }
            let count = Int(chunk.frameLength)
            if count > 0, let channels = chunk.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
            }
            if status == .endOfStream { break }
            if status == .haveData, count == 0 {
                emptyPulls += 1
                guard emptyPulls < 8 else { throw Error.unsupportedAudio }
            } else {
                emptyPulls = 0
            }
        }
        return output
    }
}

private final class SingleBufferInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

/// Turns Basic Pitch's frame posteriors into note events. A port of
/// `basic_pitch.note_creation.output_to_notes_polyphonic` (basic-pitch 0.3.0) with its
/// `predict()` defaults — onset threshold 0.5, frame threshold 0.3, minimum note 127.7 ms
/// (11 frames), inferred onsets on, "melodia trick" on — plus the mean pitch bend of
/// `get_pitch_bends`. Pure over arrays so it is unit-tested on synthetic posteriors.
enum BasicPitchNoteDecoder {
    static let onsetThreshold: Float = 0.5
    static let frameThreshold: Float = 0.3
    static let minimumNoteFrames = 11
    /// Frames a note may dip below the frame threshold before it is considered over.
    static let energyTolerance = 11
    static let pitchBendBinTolerance = 25

    static func decode(
        _ posteriors: BasicPitchPosteriors,
        onsetThreshold: Float = onsetThreshold, frameThreshold: Float = frameThreshold,
        minimumNoteFrames: Int = minimumNoteFrames, inferOnsets: Bool = true,
        melodiaTrick: Bool = true
    ) -> [NoteEvent] {
        let bins = BasicPitchNoteTranscriber.noteBins
        let frameCount = posteriors.frameCount
        guard frameCount > 1, posteriors.note.count == frameCount * bins,
            posteriors.onset.count == frameCount * bins
        else { return [] }
        let frames = posteriors.note
        var onsets = posteriors.onset
        if inferOnsets { onsets = inferredOnsets(onsets: onsets, frames: frames, bins: bins) }

        // Onset candidates: strict local maxima along time (scipy.signal.argrelmax, order 1)
        // at or above the threshold, visited backwards in time (and, within a frame, from the
        // highest bin down — numpy's row-major `where` reversed).
        var candidates: [(frame: Int, bin: Int)] = []
        for frame in stride(from: frameCount - 2, through: 1, by: -1) {
            for bin in stride(from: bins - 1, through: 0, by: -1) {
                let value = onsets[frame * bins + bin]
                guard value >= onsetThreshold, value > onsets[(frame - 1) * bins + bin],
                    value > onsets[(frame + 1) * bins + bin]
                else { continue }
                candidates.append((frame, bin))
            }
        }

        var remaining = frames
        var found: [(start: Int, end: Int, bin: Int)] = []
        func clear(rows: Range<Int>, bin: Int) {
            for row in rows {
                remaining[row * bins + bin] = 0
                if bin + 1 < bins { remaining[row * bins + bin + 1] = 0 }
                if bin > 0 { remaining[row * bins + bin - 1] = 0 }
            }
        }
        for candidate in candidates {
            let start = candidate.frame
            let bin = candidate.bin
            guard start < frameCount - 1 else { continue }
            // Walk forward while the note posterior stays up, allowing `energyTolerance`
            // frames of dropout, then back up over the dropout.
            var index = start + 1
            var below = 0
            while index < frameCount - 1, below < energyTolerance {
                if remaining[index * bins + bin] < frameThreshold { below += 1 } else { below = 0 }
                index += 1
            }
            index -= below
            guard index - start > minimumNoteFrames else { continue }
            clear(rows: start..<index, bin: bin)
            found.append((start, index, bin))
        }

        if melodiaTrick {
            // Whatever energy no onset claimed: grow notes outward from the strongest frame
            // left, until nothing above the frame threshold remains.
            while true {
                var peak: Float = 0
                var peakIndex: vDSP_Length = 0
                vDSP_maxvi(remaining, 1, &peak, &peakIndex, vDSP_Length(remaining.count))
                guard peak > frameThreshold else { break }
                let middle = Int(peakIndex) / bins
                let bin = Int(peakIndex) % bins
                remaining[Int(peakIndex)] = 0

                var index = middle + 1
                var below = 0
                while index < frameCount - 1, below < energyTolerance {
                    if remaining[index * bins + bin] < frameThreshold {
                        below += 1
                    } else {
                        below = 0
                    }
                    clear(rows: index..<(index + 1), bin: bin)
                    index += 1
                }
                let end = index - 1 - below

                index = middle - 1
                below = 0
                while index > 0, below < energyTolerance {
                    if remaining[index * bins + bin] < frameThreshold {
                        below += 1
                    } else {
                        below = 0
                    }
                    clear(rows: index..<(index + 1), bin: bin)
                    index -= 1
                }
                let start = index + 1 + below
                guard start >= 0, end < frameCount, end - start > minimumNoteFrames else {
                    continue
                }
                found.append((start, end, bin))
            }
        }

        let hasContour =
            posteriors.contour.count == frameCount * BasicPitchNoteTranscriber.contourBins
        return found.map { note in
            var amplitude: Float = 0
            for row in note.start..<note.end { amplitude += frames[row * bins + note.bin] }
            amplitude /= Float(note.end - note.start)
            let onsetTime = posteriors.frameTimes[note.start]
            let offsetTime =
                note.end < frameCount
                ? posteriors.frameTimes[note.end]
                : posteriors.frameTimes[frameCount - 1]
                    + Double(BasicPitchNoteTranscriber.fftHop)
                    / BasicPitchNoteTranscriber.sampleRate
            return NoteEvent(
                onset: onsetTime, offset: offsetTime,
                midiNote: note.bin + BasicPitchNoteTranscriber.midiOffset,
                confidence: amplitude,
                pitchBendSemitones: hasContour
                    ? meanPitchBend(
                        contour: posteriors.contour, frames: note.start..<note.end,
                        midiNote: note.bin + BasicPitchNoteTranscriber.midiOffset)
                    : nil)
        }.sorted { ($0.onset, $0.midiNote) < ($1.onset, $1.midiNote) }
    }

    /// `get_infered_onsets`: where the note posterior jumps (the smaller of its 1- and 2-frame
    /// rises), rescaled to the onset head's own peak, and merged with it by max.
    static func inferredOnsets(onsets: [Float], frames: [Float], bins: Int) -> [Float] {
        let frameCount = frames.count / bins
        var diff = [Float](repeating: 0, count: frames.count)
        var diffMax: Float = 0
        for frame in 2..<max(frameCount, 2) {
            for bin in 0..<bins {
                let here = frames[frame * bins + bin]
                let rise = min(
                    here - frames[(frame - 1) * bins + bin], here - frames[(frame - 2) * bins + bin]
                )
                let value = max(rise, 0)
                diff[frame * bins + bin] = value
                diffMax = max(diffMax, value)
            }
        }
        guard diffMax > 0, let onsetMax = onsets.max(), onsetMax > 0 else { return onsets }
        let scale = onsetMax / diffMax
        var merged = onsets
        for index in merged.indices { merged[index] = max(merged[index], diff[index] * scale) }
        return merged
    }

    /// `get_pitch_bends`, reduced to one number: the mean over the note's frames of the
    /// Gaussian-weighted contour peak's offset from the note's own bin, in semitones.
    static func meanPitchBend(contour: [Float], frames: Range<Int>, midiNote: Int) -> Float? {
        let contourBins = BasicPitchNoteTranscriber.contourBins
        let perSemitone = BasicPitchNoteTranscriber.contourBinsPerSemitone
        let center = (midiNote - BasicPitchNoteTranscriber.midiOffset) * perSemitone
        let low = max(center - pitchBendBinTolerance, 0)
        let high = min(contourBins, center + pitchBendBinTolerance + 1)
        guard !frames.isEmpty, high > low else { return nil }
        var total: Float = 0
        for frame in frames {
            var best: Float = -1
            var bestBin = center
            for bin in low..<high {
                let distance = Float(bin - center)
                let weight = exp(-(distance * distance) / (2 * 25))  // std 5 bins
                let value = contour[frame * contourBins + bin] * weight
                if value > best {
                    best = value
                    bestBin = bin
                }
            }
            total += Float(bestBin - center)
        }
        return total / Float(frames.count) / Float(perSemitone)
    }
}

/// The pipeline/app step that runs Basic Pitch over every playable pitched stem and stores the
/// note events on the document. Runs BEFORE `BucketNotePass` and `SoloTranscriptionPass`, which
/// read it; best-effort — a missing model or an unreadable stem leaves the field as it was.
enum NoteTranscriptionPass {
    static func stemAudio(for document: SongAnalysisDocument) -> [(id: StemID, url: URL)] {
        BucketNotePass.stemAudio(for: document)
    }

    /// True when the stored timelines were made by the current decoder for exactly the stems
    /// the document plays now. Note events are in song seconds, so a grid change does not stale
    /// them — a new stem set does.
    static func isCurrent(for document: SongAnalysisDocument) -> Bool {
        guard let timelines = document.noteEvents, timelines.allSatisfy(\.isCurrent) else {
            return false
        }
        return Set(timelines.map(\.stemID)) == Set(stemAudio(for: document).map(\.id))
    }

    static func timelines(
        for document: SongAnalysisDocument,
        transcriber: BasicPitchNoteTranscriber? = BasicPitchNoteTranscriber.shared
    ) -> [NoteEventTimeline]? {
        guard let transcriber else { return nil }
        let audio = stemAudio(for: document)
        guard !audio.isEmpty else { return nil }
        var timelines: [NoteEventTimeline] = []
        for entry in audio {
            guard let (samples, rate) = try? MonoSampleLoader.load(url: entry.url),
                let events = try? transcriber.transcribe(samples: samples, sampleRate: rate)
            else { continue }
            timelines.append(NoteEventTimeline(stemID: entry.id, events: events))
        }
        return timelines.isEmpty ? nil : timelines
    }

    static func apply(to document: inout SongAnalysisDocument, force: Bool = false) {
        if !force, isCurrent(for: document) { return }
        if let fresh = timelines(for: document) { document.noteEvents = fresh }
    }
}
