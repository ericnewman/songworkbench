import XCTest

@testable import SongWorkbench

final class AudioAnalysisTests: XCTestCase {
    func testFramerAppliesHannWindowAndTimestampsEachHop() throws {
        let framer = try MonoSampleFramer(frameLength: 4, hopLength: 2, sampleRate: 8)

        let frames = framer.frames(from: Array(repeating: 1, count: 8))

        XCTAssertEqual(frames.map(\.timestamp), [0, 0.25, 0.5])
        XCTAssertEqual(frames[0].samples[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(frames[0].samples[1], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(frames[0].samples[2], 1, accuracy: 0.000_001)
        XCTAssertEqual(frames[0].samples[3], 0.5, accuracy: 0.000_001)
    }

    func testMagnitudeSpectrumFindsBinCenteredTone() throws {
        let sampleRate = 4_096.0
        let frameLength = 4_096
        let samples = sineWave(frequency: 440, sampleRate: sampleRate, count: frameLength)
        let frame = AudioFrame(timestamp: 1.25, samples: samples)

        let spectrum = try MagnitudeSpectrumAnalyzer().analyze(
            frame,
            sampleRate: sampleRate
        )

        let peakBin = spectrum.magnitudes.indices.max {
            spectrum.magnitudes[$0] < spectrum.magnitudes[$1]
        }
        XCTAssertEqual(peakBin, 440)
        XCTAssertEqual(spectrum.timestamp, 1.25)
        XCTAssertEqual(spectrum.binWidth, 1, accuracy: 0.000_001)
    }

    func testChromaConcentratesEnergyInMajorTriadPitchClasses() throws {
        let sampleRate = 8_192.0
        let frameLength = 8_192
        let samples = mixedSineWave(
            frequencies: [261, 330, 392],
            sampleRate: sampleRate,
            count: frameLength
        )
        let spectrum = try MagnitudeSpectrumAnalyzer().analyze(
            AudioFrame(timestamp: 0.5, samples: samples),
            sampleRate: sampleRate
        )

        let chroma = ChromaAnalyzer().analyze(spectrum)

        XCTAssertEqual(chroma.timestamp, 0.5)
        XCTAssertGreaterThan(chroma.values[PitchClass.c.rawValue], 0.2)
        XCTAssertGreaterThan(chroma.values[PitchClass.e.rawValue], 0.2)
        XCTAssertGreaterThan(chroma.values[PitchClass.g.rawValue], 0.2)
        XCTAssertGreaterThan(
            chroma.values[PitchClass.c.rawValue]
                + chroma.values[PitchClass.e.rawValue]
                + chroma.values[PitchClass.g.rawValue],
            0.8
        )
    }

    func testClassifierProducesTimestampedMajorAndMinorObservations() {
        let classifier = ChordClassifier()
        let cMajor = ChromaVector(timestamp: 2.0, values: triad(root: .c, third: 4))
        let aMinor = ChromaVector(timestamp: 3.5, values: triad(root: .a, third: 3))

        let majorObservation = classifier.classify(cMajor)
        let minorObservation = classifier.classify(aMinor)

        XCTAssertEqual(majorObservation.timestamp, 2.0)
        XCTAssertEqual(majorObservation.chord, Chord(root: .c, quality: .major))
        XCTAssertGreaterThan(majorObservation.confidence, 0.9)
        XCTAssertEqual(minorObservation.timestamp, 3.5)
        XCTAssertEqual(minorObservation.chord, Chord(root: .a, quality: .minor))
        XCTAssertGreaterThan(minorObservation.confidence, 0.9)
    }

    func testRootWeightingDisambiguatesAbMajorFromCMinor() {
        // Ab major (Ab-C-Eb) and C minor (C-Eb-G) share C and Eb. With the Ab bass
        // present plus some G bleed, equal-weight templates pick C minor; weighting the
        // root recovers Ab major.
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        values[PitchClass.gSharp.rawValue] = 0.95  // Ab
        values[PitchClass.c.rawValue] = 0.7
        values[PitchClass.dSharp.rawValue] = 0.95  // Eb
        values[PitchClass.g.rawValue] = 1.0
        let chroma = ChromaVector(timestamp: 0, values: values)

        XCTAssertEqual(
            ChordClassifier(rootWeight: 1).classify(chroma).chord,
            Chord(root: .c, quality: .minor)
        )
        XCTAssertEqual(
            ChordClassifier(rootWeight: 1.6).classify(chroma).chord,
            Chord(root: .gSharp, quality: .major)
        )
    }

    func testPipelineClassifiesSyntheticAMinorChord() throws {
        let sampleRate = 8_192.0
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: sampleRate,
            frameLength: 8_192,
            hopLength: 4_096
        )
        let samples = mixedSineWave(
            frequencies: [220, 262, 330],
            sampleRate: sampleRate,
            count: 8_192
        )

        let observations = try ChordAnalysisPipeline(configuration: configuration)
            .analyze(samples: samples)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].timestamp, 0)
        XCTAssertEqual(observations[0].chord, Chord(root: .a, quality: .minor))
    }

    func testPipelineHonorsTaskCancellationBetweenFrames() async throws {
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: 44_100,
            frameLength: 4_096,
            hopLength: 1_024
        )
        let task = Task {
            try ChordAnalysisPipeline(configuration: configuration).analyze(
                samples: [Float](repeating: 0.1, count: 441_000)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(task.isCancelled)
        }
    }

    private func sineWave(frequency: Double, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func mixedSineWave(
        frequencies: [Double],
        sampleRate: Double,
        count: Int
    ) -> [Float] {
        let scale = 1 / Float(frequencies.count)
        return (0..<count).map { index in
            frequencies.reduce(Float.zero) { sample, frequency in
                sample + scale * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
            }
        }
    }

    private func triad(root: PitchClass, third: Int) -> [Float] {
        var values = Array(repeating: Float.zero, count: PitchClass.allCases.count)
        values[root.rawValue] = 1
        values[(root.rawValue + third) % values.count] = 1
        values[(root.rawValue + 7) % values.count] = 1
        return values
    }
}
