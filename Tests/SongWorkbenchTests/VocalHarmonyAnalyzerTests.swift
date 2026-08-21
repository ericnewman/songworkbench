import Foundation
import XCTest

@testable import SongWorkbench

final class VocalHarmonyAnalyzerTests: XCTestCase {
    func testDetectsMultipleSungNotesAndLabelsInterval() {
        let sampleRate = 44_100.0
        let samples = sine(frequency: 220, sampleRate: sampleRate, duration: 1.0)
            .enumerated()
            .map { index, value in
                value + 0.75 * sineValue(frequency: 277.18, sampleRate: sampleRate, index: index)
            }

        let notes = VocalHarmonyAnalyzer().analyze(samples: samples, sampleRate: sampleRate)
        let detected = Set(notes.map(\.midiNote))

        XCTAssertTrue(detected.contains(57), "Expected A3 in \(notes)")
        XCTAssertTrue(detected.contains(61), "Expected C#4 in \(notes)")
        XCTAssertTrue(
            notes.contains { $0.midiNote == 61 && $0.intervalSemitones == 4 },
            "Expected C#4 to carry +M3 interval in \(notes)"
        )
    }

    func testHarmonyRowFormatterNamesNotesAndIntervals() {
        let notes = [
            VocalHarmonyObservation(
                timestamp: 1,
                duration: 0.5,
                midiNote: 57,
                confidence: 0.9,
                intervalSemitones: nil
            ),
            VocalHarmonyObservation(
                timestamp: 1.05,
                duration: 0.5,
                midiNote: 61,
                confidence: 0.9,
                intervalSemitones: 4
            ),
        ]

        let labels = VocalHarmonyRowFormatter.timedLabels(for: notes, inWindow: 0.5...2)

        XCTAssertEqual(labels.map(\.name), ["A3", "C#4 +M3"])
    }

    func testHarmonyRowFormatterLimitsVisibleVoiceCount() {
        let notes = [
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 57, confidence: 0.9),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 61, confidence: 0.8),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 64, confidence: 0.7),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 69, confidence: 0.6),
        ]

        let labels = VocalHarmonyRowFormatter.timedLabels(
            for: notes,
            inWindow: 0.5...2,
            maximumVoices: 3)

        XCTAssertEqual(labels.map(\.name), ["A3", "C#4", "E4"])
    }

    func testHarmonyRowFormatterShowsDetectorScaleMultiVoiceNotes() {
        let notes = [
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 57, confidence: 0.14),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 61, confidence: 0.13),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 64, confidence: 0.12),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 67, confidence: 0.08),
        ]

        let labels = VocalHarmonyRowFormatter.timedLabels(
            for: notes,
            inWindow: 0.5...2,
            maximumVoices: 4)

        XCTAssertEqual(labels.map(\.name), ["A3", "C#4", "E4"])
    }

    func testHarmonyRowFormatterSplitsSimultaneousNotesIntoPartRows() {
        let notes = [
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 57, confidence: 0.9),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 61, confidence: 0.8),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 64, confidence: 0.7),
            VocalHarmonyObservation(timestamp: 1, duration: 0.5, midiNote: 69, confidence: 0.6),
        ]

        let parts = VocalHarmonyRowFormatter.timedParts(
            for: notes,
            inWindow: 0.5...2,
            maximumVoices: 3)

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.map(\.displayName), ["Voice 1", "Voice 2", "Voice 3"])
        XCTAssertEqual(parts.map { $0.labels.map(\.name) }, [["A3"], ["C#4"], ["E4"]])
        XCTAssertEqual(
            VocalHarmonyRowFormatter.partLabels(
                for: notes,
                inWindow: 0.5...2,
                maximumVoices: 3
            ),
            ["Voice 1  A3", "Voice 2  C#4", "Voice 3  E4"]
        )
    }

    func testHarmonyRowFormatterKeepsEachVoiceOnItsOwnRowAcrossLeaps() {
        // Two singers a sixth apart; the lower line leaps a fifth mid-phrase. Onset-order row
        // assignment used to hand the leaping note to the other singer's row.
        let notes = [
            VocalHarmonyObservation(timestamp: 1, duration: 0.4, midiNote: 57, confidence: 0.9),
            VocalHarmonyObservation(timestamp: 1, duration: 0.4, midiNote: 66, confidence: 0.8),
            VocalHarmonyObservation(timestamp: 1.5, duration: 0.4, midiNote: 64, confidence: 0.9),
            VocalHarmonyObservation(timestamp: 1.5, duration: 0.4, midiNote: 73, confidence: 0.8),
        ]

        let parts = VocalHarmonyRowFormatter.timedParts(
            for: notes,
            inWindow: 0.5...2.5,
            maximumVoices: 2)

        XCTAssertEqual(
            parts.map { $0.labels.map(\.name) },
            [["A3", "E4"], ["F#4", "C#5"]]
        )
    }

    /// What this feature must do, and what it demonstrably does NOT do.
    ///
    /// The tones are built with an explicit source-filter model: a fixed set of resonances in Hz
    /// stands in for the singer, a second fixed set stands in for the vowel, and F0 is varied
    /// independently of both. A feature indexed on the note's own harmonics satisfies a test built
    /// from fixed partial RATIOS trivially and fails this one; the previous timbre vector did
    /// exactly that.
    ///
    /// Measured here (see the printed table):
    ///   same singer, different pitch  ~0.02   <- must be small; this is the bug being fixed
    ///   different singer, same vowel  ~0.026  <- larger than the above, but only just
    ///   same singer, different vowel  ~0.17   <- the LARGEST of the three
    ///
    /// So this is a pitch-invariant vocal-tract feature, not a singer detector: an "ah"-to-"ee"
    /// move by one singer moves the vector roughly seven times further than swapping the singer.
    /// That is a property of vocal acoustics, not of this filterbank -- any spectral-envelope
    /// feature has it, which is why real speaker recognition models a distribution over many
    /// frames instead of comparing two of them. The assertion that follows from it is the last
    /// one: one singer changing vowel must stay INSIDE the clustering threshold, so a vowel change
    /// can never fork a singer onto a second voice row.
    func testTimbreTracksTheSingerAcrossPitchAndVowel() throws {
        let sampleRate = 44_100.0
        let pitches: [(hertz: Double, midi: Int, name: String)] = [
            (220, 57, "A3"), (329.63, 64, "E4"), (440, 69, "A4"),
        ]

        var aAh: [[Float]] = []
        var bAh: [[Float]] = []
        var aEe: [[Float]] = []
        for pitch in pitches {
            aAh.append(try analyzedTimbre(Self.singerA, Self.vowelAh, pitch, sampleRate))
            bAh.append(try analyzedTimbre(Self.singerB, Self.vowelAh, pitch, sampleRate))
            aEe.append(try analyzedTimbre(Self.singerA, Self.vowelEe, pitch, sampleRate))
        }

        var acrossPitch: [Float] = []
        for lower in pitches.indices {
            for upper in (lower + 1)..<pitches.count {
                acrossPitch.append(cosineDistance(aAh[lower], aAh[upper]))
                acrossPitch.append(cosineDistance(bAh[lower], bAh[upper]))
            }
        }
        let acrossSinger = pitches.indices.map { cosineDistance(aAh[$0], bAh[$0]) }
        let acrossVowel = pitches.indices.map { cosineDistance(aAh[$0], aEe[$0]) }

        print(
            """
            timbre distances
              same singer, different pitch: \(acrossPitch.map(rounded))
              different singer, same pitch and vowel: \(acrossSinger.map(rounded))
              same singer, different vowel: \(acrossVowel.map(rounded))
            """)

        let worstPitch = try XCTUnwrap(acrossPitch.max())
        let closestSingers = try XCTUnwrap(acrossSinger.min())
        let widestVowel = try XCTUnwrap(acrossVowel.max())

        XCTAssertLessThan(
            worstPitch, 0.05,
            "the same voice drifted with pitch: \(acrossPitch.map(rounded))")
        XCTAssertGreaterThan(
            closestSingers, worstPitch,
            "two singers (\(acrossSinger.map(rounded))) are no further apart than one singer's "
                + "pitches (\(acrossPitch.map(rounded)))")
        XCTAssertLessThan(
            widestVowel, VocalTimbreClustering.timbreDistanceThreshold,
            "a vowel change (\(acrossVowel.map(rounded))) would fork one singer onto two rows")
    }

    func testTimbreVectorIsFiniteAndUnitNorm() throws {
        let sampleRate = 44_100.0
        let vector = try analyzedTimbre(
            Self.singerA, Self.vowelAh, (220, 57, "A3"), sampleRate)

        XCTAssertEqual(vector.count, MelTimbreExtractor.coefficientCount)
        XCTAssertTrue(vector.allSatisfy(\.isFinite), "non-finite timbre \(vector)")
        XCTAssertEqual(sqrt(vector.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-4)
    }

    func testTimbreVectorIsNilForSilence() {
        let extractor = MelTimbreExtractor(binWidth: 44_100.0 / 4_096, binCount: 4_096 / 2 + 1)
        let silent = MagnitudeSpectrum(
            timestamp: 0,
            binWidth: 44_100.0 / 4_096,
            magnitudes: [Float](repeating: 0, count: 4_096 / 2 + 1))

        XCTAssertNil(extractor.vector(for: silent))
    }

    func testTimbreDecodesAsNilForDocumentsSavedWithoutIt() throws {
        let legacy = #"{"timestamp":1,"duration":0.5,"midiNote":57,"confidence":0.9}"#
        let decoded = try JSONDecoder().decode(
            VocalHarmonyObservation.self,
            from: Data(legacy.utf8))

        XCTAssertNil(decoded.timbre)
    }

    func testAddIntervalsPreservesTimbre() {
        let fingerprint: [Float] = [0.5, 0.5, 0.5, 0.5, 0, 0, 0, 0]
        let observations = VocalHarmonyAnalyzer.addIntervals([
            VocalHarmonyObservation(
                timestamp: 1,
                duration: 0.5,
                midiNote: 57,
                confidence: 0.9,
                timbre: fingerprint
            ),
            VocalHarmonyObservation(
                timestamp: 1,
                duration: 0.5,
                midiNote: 61,
                confidence: 0.8,
                timbre: fingerprint
            ),
        ])

        XCTAssertEqual(observations.compactMap(\.timbre), [fingerprint, fingerprint])
        XCTAssertEqual(observations.map(\.intervalSemitones), [0, 4])
    }

    // MARK: - Source-filter voice synthesis

    /// One resonance of a vocal tract, in absolute Hz. Used to build a fixed formant filter that
    /// is applied to whatever F0 is being sung, so "who is singing" and "what note" are genuinely
    /// independent knobs in the tests above.
    struct Resonance {
        let frequency: Double
        let bandwidth: Double
    }

    /// Two singers, distinguished mainly by F3 / the singer's-formant region rather than by F1-F2.
    static let singerA = [
        Resonance(frequency: 700, bandwidth: 80),
        Resonance(frequency: 1_220, bandwidth: 90),
        Resonance(frequency: 2_600, bandwidth: 140),
    ]
    static let singerB = [
        Resonance(frequency: 530, bandwidth: 70),
        Resonance(frequency: 1_840, bandwidth: 110),
        Resonance(frequency: 2_480, bandwidth: 130),
    ]
    /// Vowel colouring, applied on top of the singer and varied independently of them.
    static let vowelAh = [
        Resonance(frequency: 800, bandwidth: 90),
        Resonance(frequency: 1_150, bandwidth: 100),
    ]
    static let vowelEe = [
        Resonance(frequency: 300, bandwidth: 60),
        Resonance(frequency: 2_300, bandwidth: 140),
    ]

    private func analyzedTimbre(
        _ singer: [Resonance],
        _ vowel: [Resonance],
        _ pitch: (hertz: Double, midi: Int, name: String),
        _ sampleRate: Double
    ) throws -> [Float] {
        try timbre(
            of: voice(singer: singer, vowel: vowel, f0: pitch.hertz, sampleRate: sampleRate),
            midiNote: pitch.midi,
            sampleRate: sampleRate)
    }

    /// A glottal source (harmonics of `f0` with a -9 dB/octave tilt) driven through the singer's
    /// and the vowel's resonances. Phases are deterministic but spread, so the waveform is not one
    /// giant impulse train.
    func voice(
        singer: [Resonance],
        vowel: [Resonance],
        f0: Double,
        sampleRate: Double,
        duration: TimeInterval = 1.0
    ) -> [Float] {
        let filter: [Resonance] = singer + vowel
        var frequencies: [Double] = []
        var gains: [Double] = []
        var phases: [Double] = []
        var harmonic: Int = 1
        while Double(harmonic) * f0 <= 8_000 {
            let frequency: Double = Double(harmonic) * f0
            var gain: Double = pow(Double(harmonic), -1.5)
            for resonance in filter {
                gain *= Self.resonance(resonance, at: frequency)
            }
            frequencies.append(frequency)
            gains.append(gain)
            let phase: Double = Double(harmonic * harmonic) * 0.7
            phases.append(phase.truncatingRemainder(dividingBy: 2 * Double.pi))
            harmonic += 1
        }

        let count: Int = Int(sampleRate * duration)
        var samples: [Float] = Array(repeating: 0, count: count)
        for index in 0..<count {
            let time: Double = Double(index) / sampleRate
            var value: Double = 0
            for partial in frequencies.indices {
                let angle: Double = 2 * Double.pi * frequencies[partial] * time + phases[partial]
                value += gains[partial] * sin(angle)
            }
            samples[index] = Float(value)
        }
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        guard peak > 0 else { return samples }
        let scale: Float = 0.8 / peak
        for index in samples.indices { samples[index] *= scale }
        return samples
    }

    /// Magnitude of a two-pole resonator, normalized to unity gain at DC.
    private static func resonance(_ resonance: Resonance, at frequency: Double) -> Double {
        let ratio = frequency / resonance.frequency
        let quality = resonance.frequency / resonance.bandwidth
        let real = 1 - ratio * ratio
        let imaginary = ratio / quality
        return 1 / sqrt(real * real + imaginary * imaginary)
    }

    private func rounded(_ value: Float) -> String {
        String(format: "%.3f", Double(value))
    }

    /// The strongest observation in the clip, whatever pitch the detector assigned it.
    ///
    /// Deliberately NOT filtered to an expected MIDI note. A vowel filter can push the second
    /// harmonic well above the fundamental — an "ah" at E4 is detected as E5, because the
    /// candidate gate wants the fundamental to carry a share of the in-band peak — and pinning the
    /// note would only measure that detector quirk. It does not affect what is under test here:
    /// the mel feature reads absolute frequency bands, so the vector for a frame is the same
    /// regardless of which MIDI number the detector stamped on it.
    private func timbre(
        of samples: [Float],
        midiNote: Int,
        sampleRate: Double
    ) throws -> [Float] {
        let observations = VocalHarmonyAnalyzer().analyze(samples: samples, sampleRate: sampleRate)
            .sorted {
                if $0.duration != $1.duration { return $0.duration > $1.duration }
                return $0.confidence > $1.confidence
            }
        return try XCTUnwrap(
            observations.first?.timbre,
            "no timbre at all for a clip sung at MIDI \(midiNote)")
    }

    private func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        precondition(lhs.count == rhs.count)
        return 1 - zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Additive tone: one fundamental plus the given relative partial amplitudes.
    private func tone(
        fundamental: Double,
        partials: [Double],
        sampleRate: Double,
        duration: TimeInterval = 1.0
    ) -> [Float] {
        let count = Int(sampleRate * duration)
        return (0..<count).map { index in
            partials.enumerated().reduce(Float.zero) { total, partial in
                total
                    + Float(partial.element)
                    * sineValue(
                        frequency: fundamental * Double(partial.offset + 1),
                        sampleRate: sampleRate,
                        index: index)
            }
        }
    }

    private func sine(
        frequency: Double,
        sampleRate: Double,
        duration: TimeInterval
    ) -> [Float] {
        let count = Int(sampleRate * duration)
        return (0..<count).map {
            sineValue(frequency: frequency, sampleRate: sampleRate, index: $0)
        }
    }

    private func sineValue(frequency: Double, sampleRate: Double, index: Int) -> Float {
        Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }
}
