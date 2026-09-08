import Foundation
import XCTest

@testable import SongWorkbench

/// Diagnostic, not a regression test: cuts the metronome-bucket note timeline for every analysed
/// song in the app's real store, scores each detected chord against the bucket evidence in its
/// span, and asks whether that evidence could disambiguate the LOW-confidence chords.
///
///     SW_BUCKET_CHORD_DIAG=1 swift test --skip-build --filter BucketChordAgreementDiagnosticTests
///
/// Writes a Markdown report to /tmp/bucket-chord-agreement.md and prints the summary. Skips when
/// the env var or the store is absent so CI never depends on Eric's library.
final class BucketChordAgreementDiagnosticTests: XCTestCase {
    private struct StoredSong: Decodable {
        let analysis: SongAnalysisDocument
        let sourcePath: String
    }

    private struct ParsedChord {
        let root: Int
        let quality: ChordQuality
        var tones: Set<Int> {
            var set: Set<Int> = [root, (root + 7) % 12]
            switch quality {
            case .major, .major7, .dominant7: set.insert((root + 4) % 12)
            case .minor, .minor7: set.insert((root + 3) % 12)
            }
            switch quality {
            case .major7: set.insert((root + 11) % 12)
            case .minor7, .dominant7: set.insert((root + 10) % 12)
            case .major, .minor: break
            }
            return set
        }
        var isMinorish: Bool { quality == .minor || quality == .minor7 }
        var triadName: String { Self.names[root] + (isMinorish ? "m" : "") }
        static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

        init?(symbol: String) {
            let base = symbol.split(separator: "/").first.map(String.init) ?? symbol
            guard let first = base.first, let letter = "C D EF G A B".firstIndex(of: first) else {
                return nil
            }
            var root = "C D EF G A B".distance(from: "C D EF G A B".startIndex, to: letter)
            var rest = base.dropFirst()
            if rest.first == "#" {
                root += 1
                rest = rest.dropFirst()
            }
            if rest.first == "b" {
                root -= 1
                rest = rest.dropFirst()
            }
            root = (root + 12) % 12
            let suffix = String(rest)
            let quality: ChordQuality
            if suffix.hasPrefix("maj7") {
                quality = .major7
            } else if suffix.hasPrefix("m7") {
                quality = .minor7
            } else if suffix.hasPrefix("m") && !suffix.hasPrefix("maj") {
                quality = .minor
            } else if suffix.hasPrefix("7") {
                quality = .dominant7
            } else {
                quality = .major
            }
            self.root = root
            self.quality = quality
        }
        init(root: Int, quality: ChordQuality) {
            self.root = root
            self.quality = quality
        }
    }

    private struct SpanEvidence {
        var pitchClassMass = [Double](repeating: 0, count: 12)
        var bassRoots = [Int: Double]()
        var polyphonicBuckets = 0
        var bassBuckets = 0
        var total: Double { pitchClassMass.reduce(0, +) }
        func agreement(with tones: Set<Int>) -> Double? {
            guard total > 0 else { return nil }
            return tones.reduce(0) { $0 + pitchClassMass[$1] } / total
        }
        func bassAgreement(root: Int) -> Double? {
            let sum = bassRoots.values.reduce(0, +)
            guard sum > 0 else { return nil }
            return (bassRoots[root] ?? 0) / sum
        }
    }

    private struct ChordVerdict {
        let songName: String
        let time: TimeInterval
        let symbol: String
        let confidence: Float
        let agreement: Double?
        let bassAgreement: Double?
        let evidenceBuckets: Int
        let suggestion: (name: String, score: Double, detectedScore: Double)?
    }

    func testBucketEvidenceVersusDetectedChords() throws {
        guard ProcessInfo.processInfo.environment["SW_BUCKET_CHORD_DIAG"] == "1" else {
            throw XCTSkip("Set SW_BUCKET_CHORD_DIAG=1 to run this diagnostic")
        }
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/songs"
        )
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: store.path) else {
            throw XCTSkip("No app store at \(store.path)")
        }

        var verdicts: [ChordVerdict] = []
        var report = "# Bucket notes vs. detected chords — \(Date())\n\n"
        for file in files.sorted() where file.hasSuffix(".json") {
            let data = try Data(contentsOf: store.appendingPathComponent(file))
            guard let stored = try? JSONDecoder().decode(StoredSong.self, from: data) else {
                continue
            }
            let document = stored.analysis
            let name = URL(fileURLWithPath: stored.sourcePath).deletingPathExtension()
                .lastPathComponent
            let chords = document.chords.filter { !$0.hidden }.sorted { $0.time < $1.time }
            guard !chords.isEmpty else { continue }
            let started = Date()
            guard let timeline = BucketNotePass.timeline(for: document) else {
                report += "## \(name)\nno bucket timeline (no grid or stems)\n\n"
                continue
            }
            let seconds = Date().timeIntervalSince(started)
            let songVerdicts = Self.judge(
                chords: chords, timeline: timeline, key: document.estimatedKey,
                duration: document.sourceDuration ?? timeline.clickTimes.last ?? 0, song: name)
            verdicts += songVerdicts
            report += Self.songSection(
                name: name, verdicts: songVerdicts, stems: timeline.stems.map(\.stemID.rawValue),
                seconds: seconds, key: document.estimatedKey?.displayName)
        }
        report = Self.summary(verdicts) + "\n" + report
        try report.write(
            toFile: "/tmp/bucket-chord-agreement.md", atomically: true, encoding: .utf8)
        print(Self.summary(verdicts))
        XCTAssertFalse(verdicts.isEmpty, "no chords judged")
    }

    /// Yield check for one song: how many buckets each stem actually filled, and where the top
    /// chroma share sits, so a share gate that silences whole stems is visible as such.
    func testPolyphonicYieldForOneSong() throws {
        guard let name = ProcessInfo.processInfo.environment["SW_BUCKET_YIELD_SONG"] else {
            throw XCTSkip("Set SW_BUCKET_YIELD_SONG=<substring of source filename>")
        }
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/songs"
        )
        for file in try FileManager.default.contentsOfDirectory(atPath: store.path) {
            let data = try Data(contentsOf: store.appendingPathComponent(file))
            guard let stored = try? JSONDecoder().decode(StoredSong.self, from: data),
                stored.sourcePath.contains(name)
            else { continue }
            let document = stored.analysis
            let clicks = MetronomeGrid.clickTimes(
                beatTimes: document.beatTimes, bpm: document.estimatedBPM,
                barGrid: document.barGrid, duration: document.sourceDuration ?? 0)
            print("song \(stored.sourcePath) buckets \(clicks.count - 1)")
            for entry in BucketNotePass.stemAudio(for: document) {
                guard let role = BucketNoteAnalyzer.role(for: entry.id) else { continue }
                let (samples, rate) = try MonoSampleLoader.load(url: entry.url)
                if role == .polyphonic {
                    let frames = BucketNoteAnalyzer.chromaFrames(samples: samples, sampleRate: rate)
                    let voiced = frames.filter { $0.weight > 0 }
                    let tops = voiced.map { $0.chroma.max() ?? 0 }.sorted()
                    func pct(_ q: Double) -> Float {
                        tops.isEmpty ? 0 : tops[Int(Double(tops.count - 1) * q)]
                    }
                    print(
                        String(
                            format:
                                "  %@ frames %d voiced %d  top-share p10 %.3f p50 %.3f p90 %.3f",
                            entry.id.rawValue, frames.count, voiced.count, pct(0.1), pct(0.5),
                            pct(0.9)))
                }
                let notes = BucketNoteAnalyzer().notes(
                    role: role, samples: samples, sampleRate: rate, clickTimes: clicks)
                print("  \(entry.id.rawValue) role \(role) bucket notes \(notes.count)")
            }
        }
    }

    // MARK: - Scoring

    private static let polyphonicRankWeights: [Double] = [1.0, 0.6, 0.4]

    private static func judge(
        chords: [EditableChordEvent], timeline: BucketNoteTimeline, key: MusicalKey?,
        duration: TimeInterval, song: String
    ) -> [ChordVerdict] {
        let clicks = timeline.clickTimes
        let diatonic = key.map(diatonicTriads) ?? []
        var result: [ChordVerdict] = []
        for (index, event) in chords.enumerated() {
            guard let parsed = ParsedChord(symbol: event.chord) else { continue }
            let start = event.time
            let end = index + 1 < chords.count ? chords[index + 1].time : max(duration, start)
            var evidence = SpanEvidence()
            for stem in timeline.stems {
                guard let role = BucketNoteAnalyzer.role(for: stem.stemID), role != .voice else {
                    continue
                }
                for note in stem.notes {
                    guard clicks.indices.contains(note.bucketIndex) else { continue }
                    let time = clicks[note.bucketIndex]
                    guard time >= start, time < end else { continue }
                    switch role {
                    case .polyphonic:
                        evidence.polyphonicBuckets += 1
                        for (rank, pitchClass) in note.pitchClasses.prefix(3).enumerated() {
                            evidence.pitchClassMass[pitchClass] +=
                                polyphonicRankWeights[rank] * Double(note.coverage)
                        }
                    case .bass:
                        guard let midi = note.midiNote else { continue }
                        evidence.bassBuckets += 1
                        evidence.bassRoots[((midi % 12) + 12) % 12, default: 0] +=
                            Double(note.coverage)
                    case .voice: break
                    }
                }
            }
            let agreement = evidence.agreement(with: parsed.tones)
            let bassAgreement = evidence.bassAgreement(root: parsed.root)
            var suggestion: (String, Double, Double)? = nil
            if evidence.polyphonicBuckets + evidence.bassBuckets >= 2 {
                let detectedTriad = ParsedChord(
                    root: parsed.root, quality: parsed.isMinorish ? .minor : .major)
                let detectedScore = triadScore(
                    detectedTriad, evidence: evidence, diatonic: diatonic)
                var best: (ParsedChord, Double)? = nil
                for root in 0..<12 {
                    for quality in [ChordQuality.major, .minor] {
                        let candidate = ParsedChord(root: root, quality: quality)
                        let score = triadScore(candidate, evidence: evidence, diatonic: diatonic)
                        if best == nil || score > best!.1 { best = (candidate, score) }
                    }
                }
                if let best, best.0.triadName != detectedTriad.triadName,
                    best.1 - detectedScore >= 0.15
                {
                    suggestion = (best.0.triadName, best.1, detectedScore)
                }
            }
            result.append(
                ChordVerdict(
                    songName: song, time: start, symbol: event.chord,
                    confidence: event.confidence ?? 1, agreement: agreement,
                    bassAgreement: bassAgreement,
                    evidenceBuckets: evidence.polyphonicBuckets + evidence.bassBuckets,
                    suggestion: suggestion))
        }
        return result
    }

    /// Chord-tone share of the polyphonic mass, plus half the bass-root share, plus a small
    /// diatonic prior — the same three signals a player uses to name a chord by ear.
    private static func triadScore(
        _ chord: ParsedChord, evidence: SpanEvidence, diatonic: Set<String>
    ) -> Double {
        let tones = evidence.agreement(with: chord.tones) ?? 0
        let bass = evidence.bassAgreement(root: chord.root) ?? 0
        let prior = diatonic.contains(chord.triadName) ? 0.1 : 0
        return tones + 0.5 * bass + prior
    }

    private static func diatonicTriads(_ key: MusicalKey) -> Set<String> {
        // Degrees of the major scale (relative major for minor keys) and their triad qualities.
        let tonic = key.quality == .minor ? (key.root.rawValue + 3) % 12 : key.root.rawValue
        let degrees = [0, 2, 4, 5, 7, 9, 11]
        let qualities: [ChordQuality] = [.major, .minor, .minor, .major, .major, .minor, .minor]
        return Set(
            zip(degrees, qualities).map {
                ParsedChord(root: (tonic + $0) % 12, quality: $1).triadName
            })
    }

    // MARK: - Reporting

    private static func bin(_ confidence: Float) -> String {
        confidence < 0.6 ? "<0.60" : confidence < 0.7 ? "0.60–0.69" : "≥0.70"
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    private static func summary(_ verdicts: [ChordVerdict]) -> String {
        var text =
            "## Summary (\(verdicts.count) chords, \(Set(verdicts.map(\.songName)).count) songs)\n\n"
        text +=
            "| confidence | chords | mean chord-tone agreement | mean bass-root agreement | alternative suggested | inconclusive (<2 buckets) |\n|---|---|---|---|---|---|\n"
        for label in ["<0.60", "0.60–0.69", "≥0.70"] {
            let group = verdicts.filter { bin($0.confidence) == label }
            let agree = group.compactMap(\.agreement)
            let bass = group.compactMap(\.bassAgreement)
            let suggested = group.filter { $0.suggestion != nil }.count
            let thin = group.filter { $0.evidenceBuckets < 2 }.count
            text += String(
                format: "| %@ | %d | %.2f | %.2f | %d (%.0f%%) | %d |\n", label, group.count,
                mean(agree), mean(bass), suggested,
                group.isEmpty ? 0 : 100 * Double(suggested) / Double(group.count), thin)
        }
        let pairs = verdicts.compactMap { v in v.agreement.map { (Double(v.confidence), $0) } }
        if pairs.count > 2 {
            let mx = mean(pairs.map(\.0))
            let my = mean(pairs.map(\.1))
            let cov = pairs.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            let vx = pairs.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
            let vy = pairs.reduce(0) { $0 + ($1.1 - my) * ($1.1 - my) }
            text += String(
                format: "\nPearson r(confidence, chord-tone agreement) = %.3f over %d chords\n",
                cov / (vx * vy).squareRoot(), pairs.count)
        }
        return text
    }

    private static func songSection(
        name: String, verdicts: [ChordVerdict], stems: [String], seconds: TimeInterval,
        key: String?
    ) -> String {
        var text = "## \(name)\n\n"
        text += String(
            format: "%d chords · key %@ · stems %@ · bucket pass %.1fs\n\n", verdicts.count,
            key ?? "?", stems.joined(separator: ", "), seconds)
        let low = verdicts.filter { $0.confidence < 0.65 }
        text += "Low-confidence chords (<0.65): \(low.count)\n\n"
        text +=
            "| time | detected | conf | tone agree | bass-root agree | buckets | bucket-evidence suggests |\n|---|---|---|---|---|---|---|\n"
        for v in low.sorted(by: { $0.confidence < $1.confidence }).prefix(25) {
            text += String(
                format: "| %.1f | %@ | %.2f | %@ | %@ | %d | %@ |\n", v.time, v.symbol,
                v.confidence, v.agreement.map { String(format: "%.2f", $0) } ?? "—",
                v.bassAgreement.map { String(format: "%.2f", $0) } ?? "—", v.evidenceBuckets,
                v.suggestion.map {
                    String(format: "%@ (%.2f vs %.2f)", $0.name, $0.score, $0.detectedScore)
                }
                    ?? (v.evidenceBuckets < 2 ? "inconclusive" : "confirms"))
        }
        text += "\n"
        return text
    }
}
