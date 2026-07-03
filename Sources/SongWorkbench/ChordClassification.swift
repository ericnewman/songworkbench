import Accelerate
import Foundation

enum ChordQuality: String, Codable, Equatable, Sendable, CaseIterable {
    case major
    case minor
    case major7
    case minor7
    case dominant7
}

struct Chord: Codable, Equatable, Sendable {
    let root: PitchClass
    let quality: ChordQuality
}

struct ChordObservation: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let chord: Chord
    let confidence: Float
}

struct ChordClassifier: Sendable {
    /// Template weight given to the chord root (third and fifth are 1). Weighting the
    /// root biases classification toward the chord whose root carries the most chroma
    /// energy — the bass/root note — which disambiguates triads that share two notes
    /// (e.g. Ab major vs C minor). Tunable for trial-and-error detection comparisons.
    var rootWeight: Float = 1.6

    func classify(_ chroma: ChromaVector) -> ChordObservation {
        let triad = bestMatch(
            chroma,
            qualities: [.major, .minor]
        )
        let seventh = bestMatch(
            chroma,
            qualities: [.major7, .minor7, .dominant7]
        )
        if seventh.confidence > triad.confidence * 1.05 {
            return seventh
        }
        return triad
    }

    private func bestMatch(
        _ chroma: ChromaVector,
        qualities: [ChordQuality]
    ) -> ChordObservation {
        var bestChord = Chord(root: .c, quality: .major)
        var bestScore = Float.zero

        for root in PitchClass.allCases {
            for quality in qualities {
                guard supports(quality: quality, chroma: chroma.values, root: root) else {
                    continue
                }
                let score = cosineSimilarity(
                    chroma.values,
                    template(root: root, quality: quality)
                )
                if score > bestScore {
                    bestScore = score
                    bestChord = Chord(root: root, quality: quality)
                }
            }
        }

        return ChordObservation(
            timestamp: chroma.timestamp,
            chord: bestChord,
            confidence: bestScore
        )
    }

    private func template(root: PitchClass, quality: ChordQuality) -> [Float] {
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        values[root.rawValue] = rootWeight
        switch quality {
        case .major:
            values[(root.rawValue + 4) % values.count] = 1
            values[(root.rawValue + 7) % values.count] = 1
        case .minor:
            values[(root.rawValue + 3) % values.count] = 1
            values[(root.rawValue + 7) % values.count] = 1
        case .major7:
            values[(root.rawValue + 4) % values.count] = 1
            values[(root.rawValue + 7) % values.count] = 1
            values[(root.rawValue + 11) % values.count] = 1
        case .minor7:
            values[(root.rawValue + 3) % values.count] = 1
            values[(root.rawValue + 7) % values.count] = 1
            values[(root.rawValue + 10) % values.count] = 1
        case .dominant7:
            values[(root.rawValue + 4) % values.count] = 1
            values[(root.rawValue + 7) % values.count] = 1
            values[(root.rawValue + 10) % values.count] = 1
        }
        return values
    }

    /// Seventh qualities require their distinguishing chroma bin to carry real energy so a
    /// triad observation is not upgraded spuriously.
    private func supports(
        quality: ChordQuality,
        chroma: [Float],
        root: PitchClass
    ) -> Bool {
        switch quality {
        case .major, .minor: return true
        case .major7:
            let seventh = chroma[(root.rawValue + 11) % chroma.count]
            let fifth = chroma[(root.rawValue + 7) % chroma.count]
            return seventh >= 0.25 && seventh > fifth + 0.05
        case .minor7, .dominant7:
            let seventh = chroma[(root.rawValue + 10) % chroma.count]
            let fifth = chroma[(root.rawValue + 7) % chroma.count]
            return seventh >= 0.25 && seventh > fifth + 0.05
        }
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let denominator = sqrt(vDSP.sumOfSquares(lhs) * vDSP.sumOfSquares(rhs))
        guard denominator > 0 else { return 0 }
        return vDSP.dot(lhs, rhs) / denominator
    }
}

struct ChordAnalysisPipeline: Sendable {
    let configuration: AudioAnalysisConfiguration
    /// Root-weight passed to the classifier; tunable for trial-and-error comparisons.
    var rootWeight: Float = ChordClassifier().rootWeight

    func analyze(samples: [Float]) throws -> [ChordObservation] {
        let framer = MonoSampleFramer(configuration: configuration)
        let startIndices = framer.frameStartIndices(forSampleCount: samples.count)
        let frameCount = startIndices.count
        guard frameCount > 0 else { return [] }

        let spectrumAnalyzer = MagnitudeSpectrumAnalyzer()
        let chromaAnalyzer = ChromaAnalyzer()
        let classifier = ChordClassifier(rootWeight: rootWeight)
        let sampleRate = configuration.sampleRate

        // Partition the frame indices into N contiguous chunks. Each chunk builds exactly ONE DFT
        // transform and processes its frames serially, so a transform instance is never shared
        // across threads. Chunks run in parallel; results are written into a preallocated array so
        // the final order matches the serial order exactly.
        let chunkCount = min(
            max(ProcessInfo.processInfo.activeProcessorCount, 1),
            frameCount
        )
        let baseChunkSize = frameCount / chunkCount
        let remainder = frameCount % chunkCount

        // Preallocated result slots. Each slot is written exactly once by exactly one chunk, so the
        // concurrent writes never overlap and the final order matches the original serial order.
        let results = ResultBuffer(count: frameCount)
        // Holds the first error (cancellation or otherwise) seen by any chunk.
        let errorBox = ErrorBox()

        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            if errorBox.hasError { return }

            // Compute this chunk's contiguous [lower, upper) range over the frame list. The first
            // `remainder` chunks get one extra frame so every frame is covered exactly once.
            let lower: Int
            let count: Int
            if chunk < remainder {
                lower = chunk * (baseChunkSize + 1)
                count = baseChunkSize + 1
            } else {
                lower = remainder * (baseChunkSize + 1) + (chunk - remainder) * baseChunkSize
                count = baseChunkSize
            }
            guard count > 0 else { return }
            let upper = lower + count

            do {
                // Exactly one transform per chunk (OPT A), reused serially within the chunk.
                let transform = try MagnitudeSpectrumAnalyzer.makeTransform(
                    frameLength: configuration.frameLength
                )
                for index in lower..<upper {
                    if errorBox.hasError { return }
                    try Task.checkCancellation()
                    let frame = framer.frame(from: samples, startIndex: startIndices[index])
                    let spectrum = try spectrumAnalyzer.analyze(
                        frame,
                        sampleRate: sampleRate,
                        transform: transform
                    )
                    let observation = classifier.classify(chromaAnalyzer.analyze(spectrum))
                    results.store(observation, at: index)
                }
            } catch {
                errorBox.record(error)
            }
        }

        if let error = errorBox.error {
            throw error
        }

        return results.finished()
    }
}

/// Re-roots chord events using the detected bass line. Triads that share two notes (e.g.
/// Ab major and C minor share C+Eb) are easily confused by chroma matching; the bass note
/// is the unambiguous root. When a chord shares two notes with a triad rooted at the bass
/// (and the bass isn't already one of the chord's notes — i.e. it's not an inversion), the
/// bass-rooted chord wins. A no-op when there are no bass notes.
struct BassInformedChordRefiner: Sendable {
    private static let rootNames = [
        "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B",
    ]

    func refine(
        _ events: [EditableChordEvent],
        bassNotes: [BassNoteObservation]
    ) -> [EditableChordEvent] {
        guard !bassNotes.isEmpty else { return events }
        let sortedBass = bassNotes.sorted { $0.timestamp < $1.timestamp }
        return events.map { event in
            guard
                let parsed = parse(event.chord),
                let bass = bassPitchClass(at: event.time, in: sortedBass),
                bass != parsed.root
            else { return event }
            let detectedTones = triad(root: parsed.root, quality: parsed.quality)
            // The bass is already a chord tone: it's an inversion, keep the chord.
            if detectedTones.contains(bass) { return event }
            for quality in [ChordQuality.major, .minor]
            where triad(root: bass, quality: quality).intersection(detectedTones).count >= 2 {
                return EditableChordEvent(
                    id: event.id,
                    time: event.time,
                    chord: name(root: bass, quality: quality),
                    confidence: event.confidence
                )
            }
            return event
        }
    }

    /// Frame-level variant: re-roots raw chord observations BEFORE beat-window voting. This is
    /// where re-rooting matters most — when a chord's root is quiet in the chroma (e.g. an Ab
    /// whose C+Eb dominate), the classifier never emits the true label at all, so no amount of
    /// downstream re-weighting can recover it; the whole region then decodes as the confusion
    /// chord or is absorbed by a sustained neighbour. A no-op when there are no bass notes.
    func refineObservations(
        _ observations: [ChordObservation],
        bassNotes: [BassNoteObservation],
        minimumBassConfidence: Float = 0.35
    ) -> [ChordObservation] {
        guard !bassNotes.isEmpty else { return observations }
        // Keep ALL bass onsets for sustain boundaries but only trust confident ones for pitch:
        // a low-confidence onset still means "the bass moved here" — dropping it entirely would
        // let a stale earlier note sustain through it and re-root the real chord away (the
        // reference song's verse-opening tonic was erased exactly this way by a weak-confidence
        // tonic bass onset being filtered while the previous IV note sustained into the verse).
        let sortedBass = bassNotes.sorted { $0.timestamp < $1.timestamp }
        // Candidate qualities at the bass root, plain triads first. Sevenths matter for the
        // "upper-structure" confusion: a C# triad over an F# bass shares only ONE tone with the
        // F# triad (C#) but TWO with F#maj7 (C# + E#/F) — the sound actually being played.
        let candidates: [ChordQuality] = [.major, .minor, .major7, .dominant7]
        return observations.map { observation in
            let root = observation.chord.root.rawValue
            guard
                let sounding = bassObservation(at: observation.timestamp, in: sortedBass),
                sounding.confidence >= minimumBassConfidence
            else { return observation }
            let bass = ((sounding.midiNote % 12) + 12) % 12
            guard bass != root else { return observation }
            let detectedTones = triad(root: root, quality: observation.chord.quality)
            // The bass is already a chord tone: an inversion, keep the chord.
            if detectedTones.contains(bass) { return observation }
            for quality in candidates
            where tones(root: bass, quality: quality).intersection(detectedTones).count >= 2 {
                guard let pitchClass = PitchClass(rawValue: bass) else { return observation }
                return ChordObservation(
                    timestamp: observation.timestamp,
                    chord: Chord(root: pitchClass, quality: quality),
                    confidence: observation.confidence
                )
            }
            return observation
        }
    }

    /// All chord tones (incl. sevenths) for a root+quality, as pitch classes.
    private func tones(root: Int, quality: ChordQuality) -> Set<Int> {
        var result = triad(root: root, quality: quality)
        switch quality {
        case .major7: result.insert((root + 11) % 12)
        case .minor7, .dominant7: result.insert((root + 10) % 12)
        case .major, .minor: break
        }
        return result
    }

    /// The bass pitch class sounding at `time`: the most recent onset within a short window
    /// ending just after it. Returns `nil` when no bass note is near (e.g. a quiet intro
    /// with no detected bass), so chords there are left to the chroma classifier rather than
    /// re-rooted from a distant, unrelated bass note.
    private func bassPitchClass(at time: TimeInterval, in sortedBass: [BassNoteObservation])
        -> Int?
    {
        guard let chosen = bassObservation(at: time, in: sortedBass) else { return nil }
        return ((chosen.midiNote % 12) + 12) % 12
    }

    /// The most recent bass onset sounding at `time` (within a 4s sustain horizon), regardless
    /// of confidence — the caller decides whether its pitch is trustworthy.
    private func bassObservation(at time: TimeInterval, in sortedBass: [BassNoteObservation])
        -> BassNoteObservation?
    {
        sortedBass.last(where: { $0.timestamp >= time - 4 && $0.timestamp <= time + 0.1 })
    }

    private func parse(_ chord: String) -> (root: Int, quality: ChordQuality)? {
        var name = chord
        let quality: ChordQuality = name.hasSuffix("m") ? .minor : .major
        if quality == .minor { name.removeLast() }
        guard let root = Self.rootNames.firstIndex(of: name) else { return nil }
        return (root, quality)
    }

    private func triad(root: Int, quality: ChordQuality) -> Set<Int> {
        let third = (quality == .minor || quality == .minor7) ? 3 : 4
        return [root % 12, (root + third) % 12, (root + 7) % 12]
    }

    private func name(root: Int, quality: ChordQuality) -> String {
        Self.rootNames[root % 12] + (quality == .minor ? "m" : "")
    }
}

/// Fixed-size buffer of optional observations written from parallel chunks. Each index is written
/// exactly once by exactly one chunk, so the unsynchronized element writes do not race.
private final class ResultBuffer: @unchecked Sendable {
    private var storage: [ChordObservation?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func store(_ observation: ChordObservation, at index: Int) {
        storage[index] = observation
    }

    /// Returns the fully-populated array. Only call after all chunks have completed successfully.
    func finished() -> [ChordObservation] {
        storage.map { $0! }
    }
}

/// Thread-safe holder for the first error encountered across parallel chunks.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedError != nil
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if storedError == nil { storedError = error }
    }
}
