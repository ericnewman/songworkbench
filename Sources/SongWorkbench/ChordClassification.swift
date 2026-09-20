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

    /// Per-frame chord labels together with the chroma vectors they were classified from.
    /// The chroma is the raw pitch-content evidence: `ChromaChangePointDetector` reads it to find
    /// where the harmony genuinely CHANGES, which a sequence of labels can only approximate.
    struct FrameAnalysis: Sendable {
        let observations: [ChordObservation]
        let chroma: [ChromaVector]
    }

    func analyze(samples: [Float]) throws -> [ChordObservation] {
        try analyzeFrames(samples: samples).observations
    }

    /// - Parameter gatesRestingFrames: strip chord evidence from frames where THESE samples are
    ///   not sounding (`SoundingFrameGate`). Right when the samples are one instrument's stem —
    ///   its chord track must be empty where it rests. Wrong for the song's main chord line,
    ///   whose source mix can rest while another chordal stem carries the harmony; that line is
    ///   gated on all chordal stems together by `ChordalRestGate`.
    func analyzeFrames(samples: [Float], gatesRestingFrames: Bool = false) throws -> FrameAnalysis {
        let framer = MonoSampleFramer(configuration: configuration)
        let startIndices = framer.frameStartIndices(forSampleCount: samples.count)
        let frameCount = startIndices.count
        guard frameCount > 0 else { return FrameAnalysis(observations: [], chroma: []) }

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
                    let chroma = chromaAnalyzer.analyze(spectrum)
                    results.store(classifier.classify(chroma), chroma: chroma, at: index)
                }
            } catch {
                errorBox.record(error)
            }
        }

        if let error = errorBox.error {
            throw error
        }

        let finished = results.finished()
        let observations = PedalAwareChordRelabeler.observations(
            from: finished.chroma, classifier: classifier)
        guard gatesRestingFrames else {
            return FrameAnalysis(observations: observations, chroma: finished.chroma)
        }
        let sounding = SoundingFrameGate.sounding(
            frameLevels: startIndices.map { start in
                SoundingFrameGate.level(
                    of: samples, from: start, count: configuration.frameLength)
            })
        return FrameAnalysis(
            // A gated frame keeps its slot (the arrays stay parallel) at confidence 0, below
            // every consumer's `minimumConfidence`, so it is evidence for nothing.
            observations: observations.indices.map { index in
                sounding[index]
                    ? observations[index]
                    : ChordObservation(
                        timestamp: observations[index].timestamp,
                        chord: observations[index].chord, confidence: 0)
            },
            chroma: finished.chroma
        )
    }
}

/// Decides whether the analysed source is actually SOUNDING in a frame.
///
/// Chord scoring is cosine similarity between a chroma vector and a template, which is blind to
/// level: a frame at -88 dB scores exactly like one at -25 dB. A separated instrument stem is
/// never truly empty where the instrument rests — it holds a faint residue of whatever else is
/// playing — so every silent stretch yielded confident chords. On Seven Bridges Road (Live),
/// 2026-09-20, the guitar and piano stems sat at -88 dB through the a cappella stretches and the
/// residue was the five-part vocal harmony: 26 of the song's 132 chords were placed there.
///
/// The existing `HarmonyStemMix.leakageFloorDecibels` gate compares WHOLE-SONG levels, so a stem
/// that really plays for half the song passes it and was then trusted in the half where it rests.
/// This gate is per frame, relative to the source's own loud level. On that song the split is
/// bimodal — 101 chords within 10 dB of the loud level, 26 more than 40 dB below it, 5 between —
/// so the floor sits in a wide empty band rather than on a judgement call.
///
/// A part nobody played is worse than a missing one: a musician would learn it.
enum SoundingFrameGate {
    /// A frame this far below the source's loud level is residue, not playing.
    static let floorDecibels: Float = -40

    /// RMS of `count` samples from `start`, clipped to the buffer.
    static func level(of samples: [Float], from start: Int, count: Int) -> Float {
        let end = min(start + count, samples.count)
        guard start >= 0, end > start else { return 0 }
        var rms: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            vDSP_rmsqv(buffer.baseAddress! + start, 1, &rms, vDSP_Length(end - start))
        }
        return rms
    }

    /// One flag per frame. The loud level is the 99th-percentile frame, not the peak (one click
    /// must not set it) and not a lower percentile (an instrument that plays a tenth of the song
    /// must still be measured against its own playing, not against its rests).
    static func sounding(frameLevels: [Float]) -> [Bool] {
        guard !frameLevels.isEmpty else { return [] }
        let sorted = frameLevels.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.99))]
        guard loud > 0 else { return frameLevels.map { _ in false } }
        let floor = loud * pow(10, floorDecibels / 20)
        return frameLevels.map { $0 >= floor }
    }
}

/// Re-classifies chroma frames that sit on a sustained pedal/drone so the moving upper structure
/// can win instead of the drone's pitch class.
///
/// A 12-string intro that walks F#m and G over an open-E pedal is the motivating case: every
/// frame's strongest bin is E, `ChordClassifier.rootWeight` (1.6) locks onto E major, and the
/// decoder then emits one long E for bars at a time. The riff's real changes never appear as
/// labels, so no amount of downstream Viterbi tuning can recover them.
///
/// When a pitch class dominates a local window, that bin is zeroed and the residual is
/// classified. The residual label is kept only when it is a *different* complete triad — an E5
/// (E+B, no third) must not become B just because the drone was turned down.
enum PedalAwareChordRelabeler {
    /// Share of window-mean chroma a single pitch class must hold to count as a pedal.
    static let pedalShare: Float = 0.22
    /// Zero the pedal bin before re-classifying. Down-weighting left enough E that G/E
    /// classified as Em and F#m/E as F#m7; removing the drone lets the upper triad win.
    static let pedalDownweight: Float = 0
    /// Seconds of chroma on either side of the frame used to estimate the pedal.
    static let windowSeconds: TimeInterval = 2.0
    /// Minimum energy a residual triad's root, third, and fifth must each carry.
    static let completeToneFloor: Float = 0.08

    static func observations(
        from chroma: [ChromaVector],
        classifier: ChordClassifier
    ) -> [ChordObservation] {
        guard !chroma.isEmpty else { return [] }
        return chroma.indices.map { index in
            relabel(chroma[index], at: index, in: chroma, classifier: classifier)
        }
    }

    private static func relabel(
        _ frame: ChromaVector,
        at index: Int,
        in chroma: [ChromaVector],
        classifier: ChordClassifier
    ) -> ChordObservation {
        let full = classifier.classify(frame)
        guard let pedal = pedalPitchClass(around: index, in: chroma) else { return full }

        var residualValues = frame.values
        residualValues[pedal.rawValue] *= pedalDownweight
        let total = residualValues.reduce(Float.zero, +)
        guard total > 0 else { return full }
        residualValues = residualValues.map { $0 / total }
        let residual = classifier.classify(
            ChromaVector(timestamp: frame.timestamp, values: residualValues))
        guard residual.chord.root != pedal,
            isCompleteTriad(residual.chord, in: residualValues)
        else { return full }
        return residual
    }

    private static func pedalPitchClass(around index: Int, in chroma: [ChromaVector]) -> PitchClass?
    {
        let center = chroma[index].timestamp
        let window = chroma.filter {
            abs($0.timestamp - center) <= windowSeconds
        }
        guard !window.isEmpty else { return nil }
        var sums = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        for vector in window {
            for bin in vector.values.indices {
                sums[bin] += vector.values[bin]
            }
        }
        let count = Float(window.count)
        let means = sums.map { $0 / count }
        let total = means.reduce(Float.zero, +)
        guard total > 0,
            let maxBin = means.indices.max(by: { means[$0] < means[$1] })
        else { return nil }
        guard means[maxBin] / total >= pedalShare else { return nil }
        return PitchClass(rawValue: maxBin)
    }

    private static func isCompleteTriad(_ chord: Chord, in chroma: [Float]) -> Bool {
        let root = chord.root.rawValue
        let thirdInterval = (chord.quality == .minor || chord.quality == .minor7) ? 3 : 4
        let third = (root + thirdInterval) % chroma.count
        let fifth = (root + 7) % chroma.count
        return chroma[root] >= completeToneFloor
            && chroma[third] >= completeToneFloor
            && chroma[fifth] >= completeToneFloor
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
            guard
                let quality = bestQuality(bass: bass, detectedTones: detectedTones),
                let pitchClass = PitchClass(rawValue: bass)
            else { return observation }
            return ChordObservation(
                timestamp: observation.timestamp,
                chord: Chord(root: pitchClass, quality: quality),
                confidence: observation.confidence
            )
        }
    }

    /// The bass-rooted quality that best explains `detectedTones`, or `nil` when none explains
    /// them well enough to overrule the chroma classifier.
    ///
    /// Sevenths matter here because of the "upper-structure" confusion: a C# triad heard over an
    /// F# bass shares only ONE tone with the F# triad (C#) but TWO with F#maj7 (C# + E#/F) — the
    /// sound actually being played. But the previous rule — first match over
    /// `[.major, .minor, .major7, .dominant7]` at a flat "shares >= 2 tones" bar — got two things
    /// wrong, both measured on four songs' cached frames:
    ///
    /// 1. **First match, not argmax.** `.minor` returned as soon as it shared two tones, so a
    ///    seventh sharing all three was never even considered, and `.minor7` was absent from the
    ///    list entirely so it could never be produced at all. A Cm7 (C-Eb-G-Bb) is note-identical
    ///    to Eb6, so the chroma classifier hears Eb major; under a C bass the old scan emitted a
    ///    bare Cm and the seventh was gone. `m7` was emitted 0.0 % of the time against 2.8 % in
    ///    the reference charts.
    /// 2. **An un-normalised threshold.** A flat two-tone bar is easier for a four-note seventh
    ///    to clear than for a three-note triad, purely because it has more tones to clear it
    ///    with. That asymmetry manufactured sevenths out of two-tone coincidences: B major under
    ///    a G bass shares only B and F# with Gmaj7, and the old rule promoted it regardless.
    ///    This one stage turned 5-17 `maj7` frames per song into 248-441 — a 30-90x inflation,
    ///    and the whole source of the 6.8 % `maj7` emission against 0 % in the charts.
    ///
    /// So the bar is normalised to the CANDIDATE's own size — a triad must match 2 of its 3
    /// tones, a seventh 3 of its 4, two-thirds either way — the best match wins rather than the
    /// first, and ties go to the plain triad, so a seventh has to earn the extra tone.
    private func bestQuality(bass: Int, detectedTones: Set<Int>) -> ChordQuality? {
        var best: (quality: ChordQuality, shared: Int)?
        for quality in ChordQuality.allCases {
            let candidateTones = tones(root: bass, quality: quality)
            let shared = candidateTones.intersection(detectedTones).count
            guard shared >= (candidateTones.count >= 4 ? 3 : 2) else { continue }
            guard let current = best else {
                best = (quality, shared)
                continue
            }
            let winsOutright = shared > current.shared
            let winsTieAsTriad =
                shared == current.shared && isTriad(quality) && !isTriad(current.quality)
            if winsOutright || winsTieAsTriad { best = (quality, shared) }
        }
        return best?.quality
    }

    private func isTriad(_ quality: ChordQuality) -> Bool {
        quality == .major || quality == .minor
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
    private var chromaStorage: [ChromaVector?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
        chromaStorage = Array(repeating: nil, count: count)
    }

    func store(_ observation: ChordObservation, chroma: ChromaVector, at index: Int) {
        storage[index] = observation
        chromaStorage[index] = chroma
    }

    /// Returns the fully-populated arrays. Only call after all chunks have completed successfully.
    func finished() -> ChordAnalysisPipeline.FrameAnalysis {
        ChordAnalysisPipeline.FrameAnalysis(
            observations: storage.map { $0! },
            chroma: chromaStorage.map { $0! }
        )
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

/// Strips chord evidence from the song's main chord line wherever NO chordal stem is sounding.
///
/// The main line's chroma comes from guitar + piano, but those can rest while the separator's
/// `other` stem carries the harmony (keys, pads, a guitar it did not recognise): on 7 of 35 library
/// songs that is 18-43 % of the song, and gating on guitar + piano alone deleted real chords
/// there. So on a song where `other` is a significant driver (`ChordSourceFallback`) the rest test
/// sums guitar, piano AND other; on every other song `other` is left out entirely. A frame is a
/// rest only when the SUM is more than `SoundingFrameGate.floorDecibels` below its loud level.
/// Library-wide (2026-09-20) 68 of 5,993 chords sit below that floor and the band around it is
/// nearly empty (76 chords between -50 and -30 dB); on Seven Bridges Road it clears 23 of the
/// chords placed under a cappella singing.
///
/// Known limit: where `other` holds vocal bleed at a level a quiet keyboard could also have, the
/// frame still counts as sounding. Level cannot separate those, and neither did the two content
/// tests tried (rest-shadowing; envelope correlation with the vocal, which is NEGATIVE for bleed
/// and instrument alike). A few a cappella chords can survive on such songs.
enum ChordalRestGate {
    /// - Parameters:
    ///   - stemURLs: every chordal stem that exists (guitar, piano, other). Summed one at a time,
    ///     so peak memory is one stem plus the sum.
    ///   - frameLength: samples per chroma frame, at the stems' sample rate.
    static func applied(
        to observations: [ChordObservation], stemURLs: [URL], frameLength: Int = 8_192
    ) -> [ChordObservation] {
        var sum: [Float] = []
        var sampleRate = 0.0
        for url in stemURLs {
            guard let audio = try? MonoAudioFile.samples(url: url), !audio.samples.isEmpty else {
                continue
            }
            if sum.isEmpty {
                sum = audio.samples
                sampleRate = audio.sampleRate
            } else {
                let length = min(sum.count, audio.samples.count)
                vDSP_vadd(sum, 1, audio.samples, 1, &sum, 1, vDSP_Length(length))
            }
        }
        // No readable stem is not evidence of a rest.
        guard !sum.isEmpty, sampleRate > 0 else { return observations }
        return applied(
            to: observations,
            frameLevels: observations.map {
                SoundingFrameGate.level(
                    of: sum, from: Int(($0.timestamp * sampleRate).rounded()), count: frameLength)
            })
    }

    static func applied(to observations: [ChordObservation], frameLevels: [Float])
        -> [ChordObservation]
    {
        let sounding = SoundingFrameGate.sounding(frameLevels: frameLevels)
        return observations.indices.map { index in
            sounding[index]
                ? observations[index]
                : ChordObservation(
                    timestamp: observations[index].timestamp,
                    chord: observations[index].chord, confidence: 0)
        }
    }
}

/// Reads the chord from `other` in the frames where the main chord source is resting.
///
/// The main chord line listens to guitar + piano. On 7 of 35 library songs those stems rest for
/// 18-43 % of the song while the separator's `other` stem — keys, pads, a guitar it did not
/// recognise — carries the harmony at full level, and the chords there were being read off the
/// faint residue in the guitar stem. The part should come from the stem that is sounding.
///
/// Conditional, not a mix weight: adding `other` to the mix everywhere was measured against the
/// ground-truth charts on 2026-09-20 and made every guitar-led song worse (root F1 43.9 -> 39.3,
/// 65.3 -> 63.5, 44.0 -> 42.0 at weight 0.6) through over-segmentation. Here a frame changes hands
/// only when the primary source is more than `SoundingFrameGate.floorDecibels` below its own loud
/// level AND `other` is sounding by the same test, so guitar-led passages are untouched.
///
/// Measured on the library (38 songs): guitar-led regions 6,043 -> 6,080 chords; across 686 s of
/// `other`-led music, chord roots matching the bass note being played rose 47 % -> 63 % and chords
/// inside the song's own guitar-led vocabulary 84 % -> 91 %. The two readings name the same chord
/// only 14-45 % of the time, so this is a different answer, not a louder copy of the old one.
///
/// `other` is in or out PER SONG (Eric, 2026-09-20: "if Other is not a significant driver of
/// content we should just exclude it completely"). It is significant when it carries the music
/// ALONE — guitar + piano resting, `other` within 20 dB of its own loud level — for at least a
/// tenth of the song. Library: nine songs at 10-35 %; everything else at 8 % or below, including
/// Seven Bridges Road at 7.9 %, where the "playing" is vocal bleed at the same relative level
/// (-11 dB) as a genuinely played `other` (-5...-13) and reading it put chords under the a
/// cappella singing (4 -> 7). The boundary is not an empty band (10.4 / 8.2 / 7.9 %), so the
/// caller also withholds `other` from any song whose bass stem is a vocal shadow. A song where
/// `other` is not significant leaves it out of the rest test too (`ChordalRestGate`).
enum ChordSourceFallback {
    /// `other` must carry the music alone for this share of the song to count as a driver.
    static let minimumCarriedShare = 0.10
    /// ...while sounding this close to its own loud level (bleed and residue sit lower).
    static let carryingDecibels: Float = -20

    /// Share of frames where the primary source rests and the fallback is clearly playing.
    static func carriedShare(primaryLevels: [Float], fallbackLevels: [Float]) -> Double {
        let count = min(primaryLevels.count, fallbackLevels.count)
        guard count > 0 else { return 0 }
        let primarySounding = SoundingFrameGate.sounding(
            frameLevels: Array(primaryLevels.prefix(count)))
        let sorted = fallbackLevels.prefix(count).sorted()
        let loud = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.99))]
        guard loud > 0 else { return 0 }
        let carrying = loud * pow(10, carryingDecibels / 20)
        let carried = (0..<count).filter { !primarySounding[$0] && fallbackLevels[$0] >= carrying }
        return Double(carried.count) / Double(count)
    }

    /// - Parameters:
    ///   - primaryLevels / fallbackLevels: per-frame RMS of each source, one per observation.
    ///   - fallback: the fallback stem's own frame observations, on the same frame clock.
    static func applied(
        primary: [ChordObservation], primaryLevels: [Float],
        fallback: [ChordObservation], fallbackLevels: [Float]
    ) -> [ChordObservation] {
        guard primary.count == primaryLevels.count, fallback.count == fallbackLevels.count else {
            return primary
        }
        let primarySounding = SoundingFrameGate.sounding(frameLevels: primaryLevels)
        let fallbackSounding = SoundingFrameGate.sounding(frameLevels: fallbackLevels)
        return primary.indices.map { index in
            guard !primarySounding[index], index < fallback.count, fallbackSounding[index],
                // Same frame, or the two analyses are not on one clock and nothing is swapped.
                abs(fallback[index].timestamp - primary[index].timestamp) < 0.001
            else { return primary[index] }
            return fallback[index]
        }
    }

    /// Best-effort: an unreadable, residue-only or insignificant `other` leaves the primary
    /// evidence as it was and reports `otherIsSignificant == false`.
    static func applied(
        to primary: [ChordObservation], primaryURLs: [URL], fallbackURL: URL,
        frameLength: Int = 8_192, hopLength: Int = 4_096
    ) -> (observations: [ChordObservation], otherIsSignificant: Bool) {
        var primarySum: [Float] = []
        for url in primaryURLs {
            guard let audio = try? MonoAudioFile.samples(url: url), !audio.samples.isEmpty else {
                continue
            }
            if primarySum.isEmpty {
                primarySum = audio.samples
            } else {
                let length = min(primarySum.count, audio.samples.count)
                vDSP_vadd(primarySum, 1, audio.samples, 1, &primarySum, 1, vDSP_Length(length))
            }
        }
        guard !primarySum.isEmpty,
            let other = try? MonoAudioFile.samples(url: fallbackURL), !other.samples.isEmpty,
            // Residue-only `other` is no source at all (the whole-song leakage gate).
            HarmonyStemMix.keptAfterLeakageGate([
                HarmonyStemMix.rootMeanSquare(primarySum),
                HarmonyStemMix.rootMeanSquare(other.samples),
            ]).contains(1),
            let configuration = try? AudioAnalysisConfiguration(
                sampleRate: other.sampleRate, frameLength: frameLength, hopLength: hopLength),
            let fallback = try? ChordAnalysisPipeline(configuration: configuration)
                .analyze(samples: other.samples)
        else { return (primary, false) }
        func levels(_ samples: [Float], _ observations: [ChordObservation]) -> [Float] {
            observations.map {
                SoundingFrameGate.level(
                    of: samples, from: Int(($0.timestamp * other.sampleRate).rounded()),
                    count: frameLength)
            }
        }
        let primaryLevels = levels(primarySum, primary)
        let fallbackLevels = levels(other.samples, fallback)
        guard
            carriedShare(primaryLevels: primaryLevels, fallbackLevels: fallbackLevels)
                >= minimumCarriedShare
        else { return (primary, false) }
        return (
            applied(
                primary: primary, primaryLevels: primaryLevels,
                fallback: fallback, fallbackLevels: fallbackLevels),
            true
        )
    }
}

/// Decides whether a separated instrument stem is only a SHADOW of the singing.
///
/// A separator splits a low voice: the fundamentals land in the `bass` stem and the rest stays in
/// `vocals`. The pitch tracker then reports confident bass notes for a song that has no bass
/// instrument — 56 of them on Seven Bridges Road (Live), which is five voices and one guitar.
///
/// A level floor cannot tell the two apart (-35 dB is an ordinary quiet bass guitar). What can:
/// a real bass keeps playing when the singer stops — through intros, turnarounds, the gaps between
/// lines — and a shadow cannot, because it IS the singer. Measured across the 35-song library on
/// 2026-09-20, the stem's level while the vocals rest, relative to its own loud level:
///
///     every song with a bass instrument    -0.5 ... -6.5 dB
///     It Is Well With My Soul (quartet)    -22 dB      a cappella
///     Seven Bridges Road (Live)            -57 dB      a cappella + guitar
///
/// The floor sits in the 15 dB of empty space between them. With too little vocal rest to judge
/// (under 10 s) there is no verdict and the stem is trusted as before.
enum VocalShadowGate {
    static let windowSeconds = 0.5
    static let hopSeconds = 0.1
    /// Vocals this far below their loud level are resting.
    static let vocalRestDecibels: Float = -40
    /// Rest needed before a verdict (in hops: 10 s).
    static let minimumRestHops = 100
    /// A stem that falls this far below its own loud level whenever the vocals rest is a shadow.
    static let shadowDecibels: Float = -15

    /// - Parameters: per-hop RMS of the stem and of the vocals, on the same clock.
    static func isShadow(stemLevels: [Float], vocalLevels: [Float]) -> Bool {
        let count = min(stemLevels.count, vocalLevels.count)
        guard count > 0 else { return false }
        let stemLoud = percentile(Array(stemLevels.prefix(count)), 0.99)
        let vocalLoud = percentile(Array(vocalLevels.prefix(count)), 0.99)
        guard stemLoud > 0, vocalLoud > 0 else { return false }
        let restCeiling = vocalLoud * pow(10, vocalRestDecibels / 20)
        let duringRest = (0..<count).filter { vocalLevels[$0] < restCeiling }.map {
            stemLevels[$0]
        }
        guard duringRest.count >= minimumRestHops else { return false }
        // The 90th percentile, not the mean: a bass that plays through even a tenth of the rests
        // is an instrument.
        return percentile(duringRest, 0.9) < stemLoud * pow(10, shadowDecibels / 20)
    }

    /// Best-effort: an unreadable file is not evidence of anything, so the stem stays trusted.
    static func isShadow(stemURL: URL, vocalsURL: URL) -> Bool {
        guard let stem = try? MonoAudioFile.samples(url: stemURL),
            let vocals = try? MonoAudioFile.samples(url: vocalsURL)
        else { return false }
        return isShadow(
            stemLevels: VocalRMSEnvelope.compute(
                samples: stem.samples, sampleRate: stem.sampleRate,
                windowSeconds: windowSeconds, hopSeconds: hopSeconds),
            vocalLevels: VocalRMSEnvelope.compute(
                samples: vocals.samples, sampleRate: vocals.sampleRate,
                windowSeconds: windowSeconds, hopSeconds: hopSeconds))
    }

    private static func percentile(_ values: [Float], _ fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Float(sorted.count) * fraction))]
    }
}
