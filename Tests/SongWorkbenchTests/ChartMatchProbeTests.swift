import CoreML
import XCTest

@testable import SongWorkbench

/// Measures the guitar's chord line against ChordPro charts (Eric, 2026-10-07: his charts are the
/// reference for the right level of detail). Off unless `SW_CHART_PROBE_SET` names a tab-separated
/// file of `name, stem, analysis JSON (a SongAnalysisDocument), chart` lines.
///
/// A chart is untimed, so it is compared as an ORDERED sequence: both sides reduced to root and
/// major/minor, repeats collapsed, the detection transposed to whatever key the chart is written
/// in (capo shapes, a band tuned down), then the longest common subsequence gives precision
/// (detected chords that follow the chart) and recall (chart chords found). `inChart` is the share
/// of detected chords that are in the chart's chord set at all, which holds up even against a
/// coarse chart that names one chord per line.
final class ChartMatchProbeTests: XCTestCase {
    struct Score {
        var chords = 0
        var precision = 0.0
        var recall = 0.0
        var inChart = 0.0
        var f1: Double {
            precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        }
    }

    struct Song {
        let name: String
        let frames: [ChordObservation]
        let chordalFrames: [ChordObservation]
        let changePoints: [TimeInterval]
        let onsets: [TimeInterval]
        let key: MusicalKey?
        let document: SongAnalysisDocument
        let reference: [Int]
        /// The chord network's chords, when `SW_CHORDNET_MODEL` names the package.
        var segments: [ChordNetSegment]? = nil
    }

    struct Setting {
        let name: String
        let decoder: ChordTimelineDecoder
        let minimumBeatFraction: Double
        let chordalOnly: Bool
        var model = false
    }

    func testChordLineAgainstCharts() async throws {
        guard let setPath = ProcessInfo.processInfo.environment["SW_CHART_PROBE_SET"] else {
            throw XCTSkip("set SW_CHART_PROBE_SET")
        }
        let model = try ProcessInfo.processInfo.environment["SW_CHORDNET_MODEL"].map {
            try MLModel(contentsOf: MLModel.compileModel(at: URL(fileURLWithPath: $0)))
        }
        var songs: [Song] = []
        for line in try String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 4 else { continue }
            var song = try await Self.load(
                name: fields[0], stem: fields[1], analysis: fields[2], chart: fields[3])
            if let model {
                song.segments = try ChordNetRecognizer.segments(
                    stem: URL(fileURLWithPath: fields[1]), model: model)
            }
            songs.append(song)
        }

        var settings: [Setting] = []
        for penalty: Float in [1.5, 2.0, 3.0] {
            for weak: Float in [1.3, 2.0] {
                for minimum in [0.25, 1.0] {
                    for chordalOnly in [false, true] {
                        var decoder = ChordTimelineDecoder()
                        decoder.switchPenalty = penalty
                        decoder.weakBeatFactor = weak
                        settings.append(
                            Setting(
                                name: "penalty \(penalty) weak \(weak) min \(minimum)"
                                    + (chordalOnly ? " chordal" : ""),
                                decoder: decoder, minimumBeatFraction: minimum,
                                chordalOnly: chordalOnly))
                    }
                }
            }
        }

        if model != nil {
            for minimum in [0.25, 0.5, 1.0] {
                settings.append(
                    Setting(
                        name: "chordnet min \(minimum)", decoder: ChordTimelineDecoder(),
                        minimumBeatFraction: minimum, chordalOnly: false, model: true))
            }
        }

        var rows: [(name: String, mean: Score, perSong: [Score])] = []
        for setting in settings {
            let scores = songs.map { Self.run($0, setting) }
            let count = Double(max(scores.count, 1))
            var mean = Score()
            mean.chords = scores.map(\.chords).reduce(0, +) / max(scores.count, 1)
            mean.precision = scores.map(\.precision).reduce(0, +) / count
            mean.recall = scores.map(\.recall).reduce(0, +) / count
            mean.inChart = scores.map(\.inChart).reduce(0, +) / count
            rows.append((setting.name, mean, scores))
        }
        print(
            "PROBE songs: "
                + songs.map { "\($0.name) (\($0.reference.count))" }.joined(separator: ", "))
        for row in rows.sorted(by: { $0.mean.f1 > $1.mean.f1 }) {
            print(
                String(
                    format: "PROBE %@ | mean chords %3d | P %.2f R %.2f F1 %.2f | in chart %.0f%%",
                    row.name, row.mean.chords, row.mean.precision, row.mean.recall, row.mean.f1,
                    row.mean.inChart * 100))
        }
        for name in ["penalty 1.5 weak 1.3 min 0.25", "chordnet min 0.25"] {
            guard let current = rows.first(where: { $0.name == name }) else { continue }
            for (song, score) in zip(songs, current.perSong) {
                print(
                    String(
                        format: "PROBE \(name) | %@ | chords %3d vs chart %3d | F1 %.2f | in chart "
                            + "%.0f%%",
                        song.name, score.chords, song.reference.count, score.f1,
                        score.inChart * 100))
            }
        }
    }

    static func load(name: String, stem stemPath: String, analysis: String, chart: String)
        async throws -> Song
    {
        let stem = URL(fileURLWithPath: stemPath)
        let document = try JSONDecoder().decode(
            SongAnalysisDocument.self, from: Data(contentsOf: URL(fileURLWithPath: analysis)))
        // The harmony stage's inputs for this stem, computed once.
        let raw = try await AudioFileAnalysisService().analyze(url: stem)
        let frames = ChordalRestGate.applied(to: raw.chords, stemURLs: [stem])
        // Single-note moments (fills, licks, solo lines): at most two dominant chroma classes,
        // by majority over ±0.25 s so a decaying chord is not counted.
        let audio = try MonoAudioFile.samples(url: stem)
        let chroma = BucketNoteAnalyzer.chromaFrames(
            samples: audio.samples, sampleRate: audio.sampleRate)
        let voiced = chroma.filter { $0.weight > 0 }
        let lead = voiced.filter { SoloTranscriptionAnalyzer.isLeadLike(chroma: $0.chroma) }
        func isLead(_ time: TimeInterval) -> Bool {
            let near = voiced.filter { abs($0.time - time) <= 0.25 }.count
            let leadNear = lead.filter { abs($0.time - time) <= 0.25 }.count
            return near > 0 && Double(leadNear) / Double(near) > 0.5
        }
        let reference = sequence(
            chartLabels(try String(contentsOfFile: chart, encoding: .utf8))
                .compactMap(RomanNumeralMapper.parse).map { ($0.root.rawValue, $0.isMinor) })
        return Song(
            name: name, frames: frames, chordalFrames: frames.filter { !isLead($0.timestamp) },
            changePoints: raw.harmonicChangePoints ?? [],
            onsets: ChordalRestGate.sounding(
                InstrumentOnsetDetector.mergedOnsets(urls: [stem]), stemURLs: [stem]),
            key: raw.estimatedKey ?? MusicalKeyEstimator().estimate(from: raw.chords),
            document: document, reference: reference)
    }

    static func run(_ song: Song, _ setting: Setting) -> Score {
        guard let bpm = song.document.estimatedBPM else { return Score() }
        if setting.model, let segments = song.segments {
            return score(
                InstrumentChordPass.chordLine(
                    segments: segments, onsets: song.onsets, beats: song.document.beatTimes,
                    sourceDuration: song.document.sourceDuration,
                    minimumBeatFraction: setting.minimumBeatFraction),
                against: song.reference)
        }
        let events = InstrumentChordPass.chordLine(
            frames: setting.chordalOnly ? song.chordalFrames : song.frames,
            changePoints: song.changePoints, onsets: song.onsets, key: song.key,
            beats: song.document.beatTimes, bpm: bpm, barGrid: song.document.barGrid,
            sourceDuration: song.document.sourceDuration, decoder: setting.decoder,
            minimumBeatFraction: setting.minimumBeatFraction
        ).events
        return score(events, against: song.reference)
    }

    static func chartLabels(_ chart: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
        let range = NSRange(chart.startIndex..., in: chart)
        return pattern.matches(in: chart, range: range).compactMap {
            Range($0.range(at: 1), in: chart).map { String(chart[$0]) }
        }
    }

    /// Consecutive repeats collapsed: a chord held across two chart cells is one chord.
    static func sequence(_ chords: [(Int, Bool)]) -> [Int] {
        var out: [Int] = []
        for chord in chords {
            let code = chord.0 * 2 + (chord.1 ? 1 : 0)
            if out.last != code { out.append(code) }
        }
        return out
    }

    static func score(_ events: [EditableChordEvent], against reference: [Int]) -> Score {
        let parsed = events.compactMap { event in
            RomanNumeralMapper.parse(event.chord).map { ($0.root.rawValue, $0.isMinor) }
        }
        let chartSet = Set(reference)
        func code(_ chord: (Int, Bool), _ shift: Int) -> Int {
            ((chord.0 + shift) % 12) * 2 + (chord.1 ? 1 : 0)
        }
        // The chart may name chords in another key than the recording sounds (capo shapes, a band
        // tuned down): use the transposition that best overlaps the chart's chords.
        let shift =
            (0..<12).max { a, b in
                parsed.filter { chartSet.contains(code($0, a)) }.count
                    < parsed.filter { chartSet.contains(code($0, b)) }.count
            } ?? 0
        let detected = sequence(parsed.map { (($0.0 + shift) % 12, $0.1) })
        let common = longestCommonSubsequence(detected, reference)
        return Score(
            chords: detected.count,
            precision: detected.isEmpty ? 0 : Double(common) / Double(detected.count),
            recall: reference.isEmpty ? 0 : Double(common) / Double(reference.count),
            inChart: detected.isEmpty
                ? 0 : Double(detected.filter(chartSet.contains).count) / Double(detected.count))
    }

    static func longestCommonSubsequence(_ a: [Int], _ b: [Int]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [0]
            for (index, y) in b.enumerated() {
                current.append(
                    x == y ? previous[index] + 1 : max(previous[index + 1], current[index]))
            }
            previous = current
        }
        return previous.last ?? 0
    }
}
