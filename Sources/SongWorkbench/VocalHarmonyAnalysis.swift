import AVFoundation
import Accelerate
import Foundation

struct VocalHarmonyObservation: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let duration: TimeInterval
    let midiNote: Int
    let confidence: Float
    let sourceID: StemID?
    let voiceIndex: Int?
    let intervalSemitones: Int?
    /// Harmonic envelope of the note, normalized so it tracks the singer rather than the pitch or
    /// the loudness. Optional because documents saved before this existed decode without it.
    let timbre: [Float]?

    init(
        timestamp: TimeInterval,
        duration: TimeInterval,
        midiNote: Int,
        confidence: Float,
        sourceID: StemID? = nil,
        voiceIndex: Int? = nil,
        intervalSemitones: Int? = nil,
        timbre: [Float]? = nil
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.midiNote = midiNote
        self.confidence = confidence
        self.sourceID = sourceID
        self.voiceIndex = voiceIndex
        self.intervalSemitones = intervalSemitones
        self.timbre = timbre
    }
}

struct TimedVocalHarmonyLabel: Equatable, Sendable {
    let time: TimeInterval
    let name: String
}

struct TimedVocalHarmonyPart: Equatable, Sendable {
    let voiceIndex: Int
    let labels: [TimedVocalHarmonyLabel]

    var displayName: String {
        "Voice \(voiceIndex + 1)"
    }
}

enum VocalHarmonyNoteNaming {
    private static let names = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    static func name(forMidiNote midiNote: Int) -> String {
        let pitchClass = ((midiNote % 12) + 12) % 12
        let octave = midiNote / 12 - 1
        return "\(names[pitchClass])\(octave)"
    }

    static func intervalName(forSemitones semitones: Int?) -> String? {
        guard let semitones, semitones != 0 else { return nil }
        let sign = semitones > 0 ? "+" : "-"
        switch abs(semitones) % 12 {
        case 0: return "\(sign)8ve"
        case 1: return "\(sign)m2"
        case 2: return "\(sign)M2"
        case 3: return "\(sign)m3"
        case 4: return "\(sign)M3"
        case 5: return "\(sign)P4"
        case 6: return "\(sign)TT"
        case 7: return "\(sign)P5"
        case 8: return "\(sign)m6"
        case 9: return "\(sign)M6"
        case 10: return "\(sign)m7"
        case 11: return "\(sign)M7"
        default: return nil
        }
    }
}

enum VocalHarmonyRowFormatter {
    static let minimumDisplayConfidence: Float = 0.12

    static func timedLabels(
        for observations: [VocalHarmonyObservation],
        inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0,
        maximumVoices: Int = VocalHarmonyPreferences.defaultMaximumVoices
    ) -> [TimedVocalHarmonyLabel] {
        limited(
            observations.filter {
                $0.confidence >= minimumDisplayConfidence
                    && $0.timestamp <= window.upperBound
                    && $0.timestamp + max($0.duration, 0) >= window.lowerBound
            },
            maximumVoices: maximumVoices
        )
        .sorted {
            if abs($0.timestamp - $1.timestamp) > 0.001 { return $0.timestamp < $1.timestamp }
            return $0.midiNote < $1.midiNote
        }
        .map { observation in
            let noteName = VocalHarmonyNoteNaming.name(
                forMidiNote: observation.midiNote + semitones)
            let intervalName = VocalHarmonyNoteNaming.intervalName(
                forSemitones: observation.intervalSemitones)
            return TimedVocalHarmonyLabel(
                time: observation.timestamp,
                name: [noteName, intervalName].compactMap { $0 }.joined(separator: " ")
            )
        }
    }

    static func timedParts(
        for observations: [VocalHarmonyObservation],
        inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0,
        maximumVoices: Int = VocalHarmonyPreferences.defaultMaximumVoices
    ) -> [TimedVocalHarmonyPart] {
        let selected = limited(
            observations.filter {
                $0.confidence >= minimumDisplayConfidence
                    && $0.timestamp <= window.upperBound
                    && $0.timestamp + max($0.duration, 0) >= window.lowerBound
            },
            maximumVoices: maximumVoices
        )
        let maximumVoices = VocalHarmonyPreferences.clampedMaximumVoices(maximumVoices)
        let assigned = assignVoiceRows(selected, maximumRows: maximumVoices)
        return
            assigned
            .map { voiceIndex, observations in
                let labels =
                    observations
                    .sorted {
                        if abs($0.timestamp - $1.timestamp) > 0.001 {
                            return $0.timestamp < $1.timestamp
                        }
                        return $0.midiNote < $1.midiNote
                    }
                    .map { observation in
                        let noteName = VocalHarmonyNoteNaming.name(
                            forMidiNote: observation.midiNote + semitones)
                        let intervalName = VocalHarmonyNoteNaming.intervalName(
                            forSemitones: observation.intervalSemitones)
                        return TimedVocalHarmonyLabel(
                            time: observation.timestamp,
                            name: [noteName, intervalName].compactMap { $0 }.joined(separator: " ")
                        )
                    }
                return TimedVocalHarmonyPart(voiceIndex: voiceIndex, labels: labels)
            }
            .filter { !$0.labels.isEmpty }
            .sorted { $0.voiceIndex < $1.voiceIndex }
    }

    static func label(
        for observations: [VocalHarmonyObservation],
        inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0,
        maximumVoices: Int = VocalHarmonyPreferences.defaultMaximumVoices
    ) -> String? {
        let labels = timedLabels(
            for: observations,
            inWindow: window,
            transposedBy: semitones,
            maximumVoices: maximumVoices)
        guard !labels.isEmpty else { return nil }
        return labels.map(\.name).joined(separator: " · ")
    }

    static func partLabels(
        for observations: [VocalHarmonyObservation],
        inWindow window: ClosedRange<TimeInterval>,
        transposedBy semitones: Int = 0,
        maximumVoices: Int = VocalHarmonyPreferences.defaultMaximumVoices
    ) -> [String] {
        timedParts(
            for: observations,
            inWindow: window,
            transposedBy: semitones,
            maximumVoices: maximumVoices
        ).map { part in
            ([part.displayName] + part.labels.map(\.name)).joined(separator: "  ")
        }
    }

    private static func limited(
        _ observations: [VocalHarmonyObservation],
        maximumVoices: Int
    ) -> [VocalHarmonyObservation] {
        let maximumVoices = VocalHarmonyPreferences.clampedMaximumVoices(maximumVoices)
        var kept: [VocalHarmonyObservation] = []
        for observation in observations.sorted(by: strongestFirst) {
            let midpoint = observation.timestamp + observation.duration / 2
            let alreadySounding = kept.filter {
                $0.timestamp <= midpoint && $0.timestamp + $0.duration >= midpoint
            }
            guard alreadySounding.count < maximumVoices else { continue }
            kept.append(observation)
        }
        return kept
    }

    /// Voice rows come from `VocalTimbreClustering`: notes are grouped by their harmonic-envelope
    /// fingerprint so one singer keeps one row even when the two lines cross in pitch, and the
    /// groups are then numbered by median pitch so Voice 1 stays the lowest part. Notes with no
    /// fingerprint fall back to pitch rank within the same call.
    ///
    /// Two earlier schemes both alternated singers between rows: onset-order assignment swapped
    /// them on every melodic leap, and plain pitch rank swapped them at every voice crossing.
    private static func assignVoiceRows(
        _ observations: [VocalHarmonyObservation],
        maximumRows: Int
    ) -> [Int: [VocalHarmonyObservation]] {
        let ordered = observations.sorted(by: timeThenPitch)
        let rowIndices = VocalTimbreClustering.rows(
            for: ordered.map {
                VocalTimbreClustering.Note(
                    start: $0.timestamp,
                    end: $0.timestamp + max($0.duration, 0),
                    pitch: $0.midiNote,
                    timbre: $0.timbre,
                    source: $0.sourceID?.rawValue
                )
            },
            maximumRows: maximumRows,
            // Song-level identity assigned once during analysis. Clustering HERE would re-derive
            // centroids from just this window's notes and re-rank them, so the same singer could
            // be Voice 1 on one lyric line and Voice 2 on the next.
            preassigned: ordered.map(\.voiceIndex)
        )
        var rows: [Int: [VocalHarmonyObservation]] = [:]
        for (observation, row) in zip(ordered, rowIndices) {
            rows[row, default: []].append(observation)
        }
        return rows
    }

    private static func strongestFirst(
        lhs: VocalHarmonyObservation,
        rhs: VocalHarmonyObservation
    ) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if abs(lhs.timestamp - rhs.timestamp) > 0.001 { return lhs.timestamp < rhs.timestamp }
        return lhs.midiNote < rhs.midiNote
    }

    private static func timeThenPitch(
        lhs: VocalHarmonyObservation,
        rhs: VocalHarmonyObservation
    ) -> Bool {
        if abs(lhs.timestamp - rhs.timestamp) > 0.001 { return lhs.timestamp < rhs.timestamp }
        return lhs.midiNote < rhs.midiNote
    }
}

enum VocalHarmonyPreferences {
    static let maximumVoicesUserDefaultsKey = "reviewHarmonyMaxVoices"
    static let defaultMaximumVoices = 4

    static func clampedMaximumVoices(_ value: Int) -> Int {
        min(max(value, 2), 4)
    }
}

/// Fixed-frequency timbre feature: a mel-frequency cepstrum of the frame's power spectrum.
///
/// This describes the shape of the vocal tract, not the note being sung. That distinction is the
/// whole point. The feature this replaced sampled the spectrum at integer multiples of the note's
/// OWN fundamental, so the same singer measured through a different pitch got a different comb and
/// therefore a different vector: measured on source-filter synthesis, two different singers on the
/// same vowel came out 0.004-0.12 apart while one singer moving from "ah" to "ee" came out
/// 0.24-0.51 apart. It was ranking vowels and pitches, not people.
///
/// Here the filterbank is pinned to absolute Hz, so a formant at 2.6 kHz lands in the same band no
/// matter which F0 carries it. The range reaches past F1/F2 (which encode the vowel) into F3-F5
/// and the singer's-formant cluster near 3 kHz, which is where individual voice identity sits.
/// Below `lowerFrequency` the spectrum is mostly F0 and its first harmonic, i.e. pitch.
///
/// `minimumBandwidth` is the part that is not textbook MFCC, and it is what actually buys pitch
/// invariance. Mel bands at the bottom of this range are ~70 Hz wide, far narrower than the gap
/// between the harmonics of a sung note, so each band ends up measuring whether a harmonic happens
/// to land in it — the same pitch-dependent comb, re-imported through the back door. Widening
/// every band to at least 800 Hz (above the F0 of anything up to roughly D5) makes each band span
/// two or more harmonics at any sung pitch, so it measures the ENVELOPE. Measured across A3/E4/A4
/// this drops the same-singer-different-pitch distance from 0.83 to 0.020.
struct MelTimbreExtractor: Sendable {
    static let lowerFrequency: Double = 300
    static let upperFrequency: Double = 5_000
    static let bandCount = 26
    static let coefficientCount = 12
    /// Every band is widened to at least this many Hz; see the note above.
    static let minimumBandwidth: Double = 800
    /// Band energies more than 60 dB below the loudest band are window leakage, not voice.
    private static let floorRatio: Float = 1e-6

    private struct Band {
        let firstBin: Int
        let weights: [Float]
    }

    private let bands: [Band]
    /// Row `k` is the DCT-II basis for cepstral coefficient `k + 1`; coefficient 0 is never built
    /// because it is only the frame's loudness.
    private let basis: [[Float]]

    init(
        binWidth: Double,
        binCount: Int,
        lowerFrequency: Double = MelTimbreExtractor.lowerFrequency,
        upperFrequency: Double = MelTimbreExtractor.upperFrequency,
        bandCount: Int = MelTimbreExtractor.bandCount,
        coefficientCount: Int = MelTimbreExtractor.coefficientCount,
        minimumBandwidth: Double = MelTimbreExtractor.minimumBandwidth
    ) {
        let bandCount = max(bandCount, 2)
        let coefficientCount = max(min(coefficientCount, bandCount - 1), 1)
        let lowMel = Self.mel(lowerFrequency)
        let highMel = Self.mel(max(upperFrequency, lowerFrequency + 1))
        let step = (highMel - lowMel) / Double(bandCount + 1)
        let edges = (0...(bandCount + 1)).map { Self.hertz(lowMel + Double($0) * step) }

        var bands: [Band] = []
        bands.reserveCapacity(bandCount)
        for index in 0..<bandCount {
            let center = edges[index + 1]
            var lower = edges[index]
            var upper = edges[index + 2]
            if upper - lower < minimumBandwidth {
                lower = min(lower, center - minimumBandwidth / 2)
                upper = max(upper, center + minimumBandwidth / 2)
            }
            let firstBin = max(Int((lower / binWidth).rounded(.up)), 0)
            let lastBin = min(Int((upper / binWidth).rounded(.down)), binCount - 1)
            guard binWidth > 0, firstBin <= lastBin else {
                bands.append(Band(firstBin: 0, weights: []))
                continue
            }
            let weights = (firstBin...lastBin).map { bin -> Float in
                let frequency = Double(bin) * binWidth
                let ramp =
                    frequency <= center
                    ? (frequency - lower) / max(center - lower, .ulpOfOne)
                    : (upper - frequency) / max(upper - center, .ulpOfOne)
                return Float(max(ramp, 0))
            }
            bands.append(Band(firstBin: firstBin, weights: weights))
        }
        self.bands = bands
        self.basis = (1...coefficientCount).map { coefficient in
            (0..<bandCount).map { band in
                Float(
                    cos(
                        Double.pi * Double(coefficient) * (Double(band) + 0.5)
                            / Double(bandCount)))
            }
        }
    }

    /// Nil when the frame carries no energy in the band at all, so a silent frame contributes no
    /// fingerprint instead of a vector of zeros or NaNs.
    func vector(for spectrum: MagnitudeSpectrum) -> [Float]? {
        var energies = [Float](repeating: 0, count: bands.count)
        for (index, band) in bands.enumerated() {
            var total: Float = 0
            for (offset, weight) in band.weights.enumerated() {
                let bin = band.firstBin + offset
                guard bin < spectrum.magnitudes.count else { break }
                let magnitude = spectrum.magnitudes[bin]
                total += weight * magnitude * magnitude
            }
            energies[index] = total
        }
        guard let loudest = energies.max(), loudest > 0, loudest.isFinite else { return nil }
        let floorValue = loudest * Self.floorRatio
        let logs = energies.map { log10(max($0, floorValue)) }
        let coefficients = basis.map { row in
            zip(row, logs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        }
        return VocalHarmonyAnalyzer.unitVector(coefficients)
    }

    private static func mel(_ hertz: Double) -> Double {
        2_595 * log10(1 + max(hertz, 0) / 700)
    }

    private static func hertz(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2_595) - 1)
    }
}

struct VocalHarmonyAnalyzer: Sendable {
    private struct ActiveFrame {
        let time: TimeInterval
        let confidence: Float
        let timbre: [Float]?
    }

    private let frameLength = 4_096
    private let hopLength = 2_048
    private let minimumMidiNote = 48
    private let maximumMidiNote = 84
    private let maximumNotesPerFrame: Int
    private let minimumFrameConfidence: Float = 0.08
    private let minimumSegmentDuration: TimeInterval = 0.16
    private let detectionTargetPeak: Float = 0.7

    init(maximumNotesPerFrame: Int = VocalHarmonyPreferences.defaultMaximumVoices) {
        self.maximumNotesPerFrame = VocalHarmonyPreferences.clampedMaximumVoices(
            maximumNotesPerFrame)
    }

    func analyze(url: URL, sourceID: StemID? = nil, voiceIndex: Int? = nil) throws
        -> [VocalHarmonyObservation]
    {
        let (samples, sampleRate) = try loadMonoSamples(url: url)
        try Task.checkCancellation()
        return analyze(
            samples: samples,
            sampleRate: sampleRate,
            sourceID: sourceID,
            voiceIndex: voiceIndex)
    }

    func analyze(
        samples: [Float],
        sampleRate: Double,
        sourceID: StemID? = nil,
        voiceIndex: Int? = nil
    ) -> [VocalHarmonyObservation] {
        guard sampleRate > 0, samples.count >= frameLength else { return [] }
        let leveled = peakNormalized(samples)
        guard
            let framer = try? MonoSampleFramer(
                frameLength: frameLength,
                hopLength: hopLength,
                sampleRate: sampleRate
            ),
            let transform = try? MagnitudeSpectrumAnalyzer.makeTransform(
                frameLength: frameLength)
        else { return [] }
        let spectrumAnalyzer = MagnitudeSpectrumAnalyzer()
        let timbreExtractor = MelTimbreExtractor(
            binWidth: sampleRate / Double(frameLength),
            binCount: frameLength / 2 + 1
        )
        var activeFramesByNote: [Int: [ActiveFrame]] = [:]

        for frameStart in framer.frameStartIndices(forSampleCount: leveled.count) {
            let frame = framer.frame(from: leveled, startIndex: frameStart)
            guard
                let spectrum = try? spectrumAnalyzer.analyze(
                    frame,
                    sampleRate: sampleRate,
                    transform: transform
                )
            else { continue }
            let rms = vDSP.rootMeanSquare(frame.samples)
            let frameCandidates = candidates(in: spectrum, rms: rms)
            guard !frameCandidates.isEmpty else { continue }
            // One fingerprint per FRAME, not per note: the feature describes the vocal tract that
            // produced this spectrum, and every note detected in the frame came out of the same
            // spectrum. Notes are told apart by which frames they span, plus their stem.
            let timbre = timbreExtractor.vector(for: spectrum)
            for candidate in frameCandidates {
                activeFramesByNote[candidate.midiNote, default: []].append(
                    ActiveFrame(
                        time: frame.timestamp,
                        confidence: candidate.confidence,
                        timbre: timbre
                    ))
            }
        }

        return Self.addIntervals(
            segments(
                activeFramesByNote: activeFramesByNote,
                sourceID: sourceID,
                voiceIndex: voiceIndex,
                hopDuration: Double(hopLength) / sampleRate
            )
        )
    }

    /// Assigns each observation its song-level voice, once, over every note in the song. Called at
    /// the end of the harmony stage so the display never has to cluster a window of notes.
    static func assigningVoices(
        _ observations: [VocalHarmonyObservation],
        maximumVoices: Int
    ) -> [VocalHarmonyObservation] {
        guard !observations.isEmpty else { return observations }
        let voices = VocalTimbreClustering.voices(
            for: observations.map {
                VocalTimbreClustering.Note(
                    start: $0.timestamp,
                    end: $0.timestamp + max($0.duration, 0),
                    pitch: $0.midiNote,
                    timbre: $0.timbre,
                    source: $0.sourceID?.rawValue
                )
            },
            maximumVoices: maximumVoices
        )
        return zip(observations, voices).map { observation, voice in
            VocalHarmonyObservation(
                timestamp: observation.timestamp,
                duration: observation.duration,
                midiNote: observation.midiNote,
                confidence: observation.confidence,
                sourceID: observation.sourceID,
                voiceIndex: voice,
                intervalSemitones: observation.intervalSemitones,
                timbre: observation.timbre
            )
        }
    }

    static func addIntervals(_ observations: [VocalHarmonyObservation])
        -> [VocalHarmonyObservation]
    {
        guard !observations.isEmpty else { return [] }
        return observations.map { observation in
            let start = observation.timestamp
            let end = observation.timestamp + observation.duration
            let sounding = observations.filter {
                min(end, $0.timestamp + $0.duration) >= max(start, $0.timestamp)
            }
            guard let lowest = sounding.map(\.midiNote).min(), sounding.count > 1 else {
                return VocalHarmonyObservation(
                    timestamp: observation.timestamp,
                    duration: observation.duration,
                    midiNote: observation.midiNote,
                    confidence: observation.confidence,
                    sourceID: observation.sourceID,
                    voiceIndex: observation.voiceIndex,
                    intervalSemitones: nil,
                    timbre: observation.timbre
                )
            }
            return VocalHarmonyObservation(
                timestamp: observation.timestamp,
                duration: observation.duration,
                midiNote: observation.midiNote,
                confidence: observation.confidence,
                sourceID: observation.sourceID,
                voiceIndex: observation.voiceIndex,
                intervalSemitones: observation.midiNote - lowest,
                timbre: observation.timbre
            )
        }
    }

    private func candidates(in spectrum: MagnitudeSpectrum, rms: Float)
        -> [(midiNote: Int, confidence: Float)]
    {
        guard rms > 0.003 else { return [] }
        let maxMagnitude = peakMagnitude(in: spectrum)
        guard maxMagnitude > 0 else { return [] }
        var scored: [(midiNote: Int, confidence: Float)] = []
        scored.reserveCapacity(maximumMidiNote - minimumMidiNote + 1)
        for midiNote in minimumMidiNote...maximumMidiNote {
            let frequency = 440 * pow(2, Double(midiNote - 69) / 12)
            let harmonic = harmonicEnergy(spectrum: spectrum, frequency: frequency)
            guard harmonic.fundamental >= maxMagnitude * 0.12 else { continue }
            let score = harmonic.total / max(maxMagnitude, 0.0001)
            if score >= minimumFrameConfidence {
                scored.append((midiNote: midiNote, confidence: min(score, 1)))
            }
        }
        let sorted = scored.sorted { $0.confidence > $1.confidence }
        var selected: [(midiNote: Int, confidence: Float)] = []
        for candidate in sorted {
            guard selected.allSatisfy({ abs($0.midiNote - candidate.midiNote) >= 2 }) else {
                continue
            }
            selected.append(candidate)
            if selected.count == maximumNotesPerFrame { break }
        }
        return selected
    }

    private func harmonicEnergy(spectrum: MagnitudeSpectrum, frequency: Double)
        -> (fundamental: Float, total: Float)
    {
        let fundamental = localMagnitude(spectrum: spectrum, frequency: frequency)
        var score = fundamental
        for (multiple, weight) in [(1.0, 1.0), (2.0, 0.5), (3.0, 0.25)] {
            guard multiple > 1 else { continue }
            let harmonic = frequency * multiple
            guard harmonic < spectrum.binWidth * Double(spectrum.magnitudes.count - 1) else {
                continue
            }
            score +=
                Float(weight)
                * localMagnitude(spectrum: spectrum, frequency: harmonic)
        }
        return (fundamental, score)
    }

    /// Confidence-weighted so the frames where the note really sounded set the fingerprint, then
    /// re-normalized because averaging unit vectors shortens them.
    private static func averageTimbre(_ frames: ArraySlice<ActiveFrame>) -> [Float]? {
        guard let length = frames.lazy.compactMap({ $0.timbre?.count }).first(where: { $0 > 0 })
        else { return nil }
        var sum = [Float](repeating: 0, count: length)
        var weight: Float = 0
        for frame in frames {
            guard let timbre = frame.timbre, timbre.count == sum.count else { continue }
            let confidence = max(frame.confidence, 0)
            for index in sum.indices { sum[index] += confidence * timbre[index] }
            weight += confidence
        }
        guard weight > 0 else { return nil }
        return unitVector(sum)
    }

    static func unitVector(_ values: [Float]) -> [Float]? {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return values.map { $0 / norm }
    }

    private func peakMagnitude(in spectrum: MagnitudeSpectrum) -> Float {
        let lowerBin = max(Int((midiFrequency(minimumMidiNote) / spectrum.binWidth).rounded()), 0)
        let upperBin = min(
            Int((midiFrequency(maximumMidiNote) / spectrum.binWidth).rounded()),
            spectrum.magnitudes.count - 1
        )
        guard lowerBin <= upperBin else { return 0 }
        return spectrum.magnitudes[lowerBin...upperBin].max() ?? 0
    }

    private func localMagnitude(spectrum: MagnitudeSpectrum, frequency: Double) -> Float {
        guard spectrum.binWidth > 0 else { return 0 }
        let position = frequency / spectrum.binWidth
        let lower = Int(position.rounded(.down))
        let upper = lower + 1
        guard lower >= 0, upper < spectrum.magnitudes.count else { return 0 }
        let fraction = Float(position - Double(lower))
        return spectrum.magnitudes[lower] * (1 - fraction)
            + spectrum.magnitudes[upper] * fraction
    }

    private func midiFrequency(_ midiNote: Int) -> Double {
        440 * pow(2, Double(midiNote - 69) / 12)
    }

    private func segments(
        activeFramesByNote: [Int: [ActiveFrame]],
        sourceID: StemID?,
        voiceIndex: Int?,
        hopDuration: TimeInterval
    ) -> [VocalHarmonyObservation] {
        var observations: [VocalHarmonyObservation] = []
        for (midiNote, frames) in activeFramesByNote {
            let sorted = frames.sorted { $0.time < $1.time }
            var index = 0
            while index < sorted.count {
                var end = index
                while end + 1 < sorted.count,
                    sorted[end + 1].time - sorted[end].time <= hopDuration * 1.5
                {
                    end += 1
                }
                let startTime = sorted[index].time
                let duration = sorted[end].time + hopDuration - startTime
                if duration >= minimumSegmentDuration {
                    let confidences = sorted[index...end].map(\.confidence)
                    observations.append(
                        VocalHarmonyObservation(
                            timestamp: startTime,
                            duration: duration,
                            midiNote: midiNote,
                            confidence: confidences.reduce(0, +) / Float(confidences.count),
                            sourceID: sourceID,
                            voiceIndex: voiceIndex,
                            timbre: Self.averageTimbre(sorted[index...end])
                        )
                    )
                }
                index = end + 1
            }
        }
        return observations.sorted {
            if abs($0.timestamp - $1.timestamp) > 0.001 { return $0.timestamp < $1.timestamp }
            return $0.midiNote < $1.midiNote
        }
    }

    private func peakNormalized(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0, peak < detectionTargetPeak else { return samples }
        var gain = detectionTargetPeak / peak
        var output = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &gain, &output, 1, vDSP_Length(samples.count))
        return output
    }

    private func loadMonoSamples(url: URL) throws -> ([Float], Double) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else {
                throw WaveformAnalyzerError.unsupportedAudioFormat
            }
            for frame in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    value += channels[channel][frame]
                }
                samples.append(value / Float(format.channelCount))
            }
        }
        return (samples, format.sampleRate)
    }
}
