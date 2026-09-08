import Foundation
import XCTest

@testable import SongWorkbench

/// Diagnostic, not a regression test: runs `SoloTranscriptionPass` over every analysed song in
/// the app's real store and prints, per song and stem, the passages found (start/end, buckets,
/// confidence) with the first two bars of tab, plus how many buckets each stem classified as
/// lead/chordal/silent. Optional `SW_SOLO_DIAG_MATCH=substring` limits it to matching titles.
///
///     SW_SOLO_DIAG=1 swift test --skip-build --filter SoloTranscriptionDiagnosticTests
///
/// Also writes /tmp/solo-tab-diagnostic.md. Skips when the env var or the store is absent.
final class SoloTranscriptionDiagnosticTests: XCTestCase {
    private struct StoredSong: Decodable {
        let analysis: SongAnalysisDocument
        let sourcePath: String
    }

    func testSoloPassagesOnTheRealStore() throws {
        guard ProcessInfo.processInfo.environment["SW_SOLO_DIAG"] == "1" else {
            throw XCTSkip("Set SW_SOLO_DIAG=1 to run this diagnostic")
        }
        let match = ProcessInfo.processInfo.environment["SW_SOLO_DIAG_MATCH"]
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/songs"
        )
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: store.path) else {
            throw XCTSkip("No app store at \(store.path)")
        }
        var report = "# Solo tab diagnostic — \(Date())\n\n"
        for file in files.sorted() where file.hasSuffix(".json") {
            let data = try Data(contentsOf: store.appendingPathComponent(file))
            guard let stored = try? JSONDecoder().decode(StoredSong.self, from: data) else {
                continue
            }
            let name = URL(fileURLWithPath: stored.sourcePath).deletingPathExtension()
                .lastPathComponent
            if let match, !name.localizedCaseInsensitiveContains(match) { continue }
            let document = stored.analysis
            report += "## \(name)\n"
            guard let key = SoloTranscriptionPass.gridKey(for: document) else {
                report += "no grid\n\n"
                continue
            }
            let clicks = MetronomeGrid.clickTimes(
                beatTimes: document.beatTimes, bpm: document.estimatedBPM,
                barGrid: document.barGrid, duration: key.duration)
            let beatsPerBar = document.barGrid?.beatsPerBar ?? 4
            report += "bpm \(String(format: "%.1f", key.bpm)), \(clicks.count - 1) buckets, "
            report += "\(beatsPerBar)/4\n"
            let started = Date()
            let reference = SoloTranscriptionPass.referenceBucketRMS(
                for: document, clickTimes: clicks)
            report += reference == nil ? "no vocal stem for prominence\n" : ""
            for entry in SoloTranscriptionPass.stemAudio(for: document) {
                guard let (samples, rate) = try? MonoSampleLoader.load(url: entry.url) else {
                    report += "- \(entry.id.rawValue): unreadable\n"
                    continue
                }
                let chroma = BucketNoteAnalyzer.chromaFrames(samples: samples, sampleRate: rate)
                report += Self.levelProfile(samples: samples)
                let pitch = VocalHarmonyAnalyzer(
                    maximumNotesPerFrame: 1, midiRange: VocalHarmonyAnalyzer.guitarMidiRange
                ).frameEstimates(samples: samples, sampleRate: rate)
                let stemLevels = SoloTranscriptionAnalyzer.bucketRMS(
                    samples: samples, sampleRate: rate, clickTimes: clicks)
                let ungated = SoloTranscriptionAnalyzer.classifyBuckets(
                    chromaFrames: chroma, pitchFrames: pitch, clickTimes: clicks)
                let verdicts = SoloTranscriptionAnalyzer.classifyBuckets(
                    chromaFrames: chroma, pitchFrames: pitch, clickTimes: clicks,
                    levels: reference.map { (stem: stemLevels, reference: $0) })
                let counts = Dictionary(grouping: verdicts, by: \.kind).mapValues(\.count)
                let ungatedLead = ungated.filter { $0.kind == .lead }.count
                report +=
                    "- \(entry.id.rawValue): lead \(counts[.lead] ?? 0) (\(ungatedLead) before "
                    + "prominence gate), chordal \(counts[.chordal] ?? 0), silent "
                    + "\(counts[.silent] ?? 0)\n"
                if let reference {
                    // Stem-over-vocals level in dB across the ungated lead buckets: how far the
                    // prominence gate sits from what it keeps and rejects.
                    let ratios = ungated.filter { $0.kind == .lead }.map { verdict -> Float in
                        let voice = max(reference[verdict.bucketIndex], 1e-6)
                        return 20 * log10(max(stemLevels[verdict.bucketIndex], 1e-6) / voice)
                    }.sorted()
                    if !ratios.isEmpty {
                        report += String(
                            format: "  lead-bucket stem/vocals dB p10 %.0f p50 %.0f p90 %.0f\n",
                            ratios[ratios.count / 10], ratios[ratios.count / 2],
                            ratios[ratios.count * 9 / 10])
                    }
                }
                if ProcessInfo.processInfo.environment["SW_SOLO_DIAG_BARS"] == "1" {
                    report += Self.barProfile(
                        chroma: chroma, pitch: pitch, clicks: clicks, beatsPerBar: beatsPerBar)
                }
                let passages = SoloTranscriptionAnalyzer.passages(
                    verdicts: verdicts, clickTimes: clicks, beatsPerBar: beatsPerBar,
                    stemID: entry.id)
                let timeline = SoloTranscriptionTimeline(
                    gridKey: key, clickTimes: clicks, transcriptions: [])
                for passage in passages {
                    let notes = SoloTranscriptionAnalyzer.transcribe(
                        passage: passage, pitchFrames: pitch, clickTimes: clicks)
                    let transcription = SoloTranscription(
                        stemID: entry.id, passage: passage, notes: notes)
                    let columns = SoloTabRowFormatter.columns(
                        for: transcription, timeline: timeline
                    ).prefix(beatsPerBar * 2 * 4)
                    report += String(
                        format: "  - %@ %.1f–%.1f s (buckets %d–%d, %d notes, conf %.2f)\n",
                        Self.clock(passage.startTime) + "–" + Self.clock(passage.endTime),
                        passage.startTime, passage.endTime, passage.startBucket,
                        passage.endBucket, notes.count, passage.confidence)
                    for (row, label) in SoloTabRowFormatter.stringLabels.enumerated() {
                        report += "    \(label)|" + columns.map { $0.cells[row] }.joined() + "\n"
                    }
                }
            }
            report += String(format: "took %.1f s\n\n", Date().timeIntervalSince(started))
        }
        try report.write(
            to: URL(fileURLWithPath: "/tmp/solo-tab-diagnostic.md"), atomically: true,
            encoding: .utf8)
        print(report)
    }

    /// Per bar: the share of voiced chroma frames that are lead-like, the mean number of
    /// dominant pitch classes, the mean top-class share, and the pitch tracker's voiced share —
    /// the raw numbers the classifier's gates are set against.
    private static func barProfile(
        chroma: [BucketNoteAnalyzer.ChromaFrame], pitch: [PitchFrameEstimate],
        clicks: [TimeInterval], beatsPerBar: Int
    ) -> String {
        var out = "  bar   time  lead  dom   top  pitch  chg  dist  conf\n"
        var bar = 0
        while (bar + 1) * beatsPerBar < clicks.count {
            let start = clicks[bar * beatsPerBar]
            let end = clicks[(bar + 1) * beatsPerBar]
            let voiced = chroma.filter { $0.time >= start && $0.time < end && $0.weight > 0 }
            let total = chroma.filter { $0.time >= start && $0.time < end }.count
            let pitched = pitch.filter { $0.time >= start && $0.time < end }
            defer { bar += 1 }
            guard total > 0, Float(voiced.count) / Float(total) >= 0.2 else {
                out += String(format: "  %3d %6.1f  silent\n", bar, start)
                continue
            }
            let lead = voiced.filter { SoloTranscriptionAnalyzer.isLeadLike(chroma: $0.chroma) }
            let dominant = voiced.map { frame -> Float in
                let top = frame.chroma.max() ?? 0
                return Float(frame.chroma.filter { $0 >= top * 0.5 }.count)
            }
            let topShare = voiced.map { $0.chroma.max() ?? 0 }
            let pitchedShare =
                pitched.isEmpty
                ? 0
                : Float(pitched.filter { $0.midiNote != nil && $0.confidence > 0 }.count)
                    / Float(pitched.count)
            let track = pitched.compactMap(\.midiNote)
            var changes = 0
            for index in 1..<max(track.count, 1) where track[index] != track[index - 1] {
                changes += 1
            }
            let confidences = pitched.filter { $0.midiNote != nil }.map(\.confidence)
            out += String(
                format: "  %3d %6.1f  %.2f  %.1f  %.2f  %.2f  %3d  %4d  %.2f\n", bar, start,
                Float(lead.count) / Float(voiced.count),
                dominant.reduce(0, +) / Float(dominant.count),
                topShare.reduce(0, +) / Float(topShare.count), pitchedShare, changes,
                Set(track).count,
                confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count))
        }
        return out
    }

    /// Absolute (un-normalised) frame RMS percentiles in dBFS: what the stem's level actually
    /// is, so a leakage-only stem (a cappella voices in the "piano" stem) can be told from one
    /// that carries an instrument.
    private static func levelProfile(samples: [Float]) -> String {
        let frame = 4_096
        guard samples.count >= frame else { return "" }
        var rms: [Float] = []
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for index in start..<(start + frame) { sum += samples[index] * samples[index] }
            rms.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        rms.sort()
        func db(_ percentile: Double) -> String {
            let value = rms[min(Int(Double(rms.count - 1) * percentile), rms.count - 1)]
            return String(format: "%.0f", 20 * log10(max(value, 1e-6)))
        }
        return "  level dBFS p50 \(db(0.5)) p90 \(db(0.9)) p99 \(db(0.99))\n"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
