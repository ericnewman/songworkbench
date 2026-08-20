import AVFoundation
import XCTest

@testable import SongWorkbench

/// MANUAL offline validation harness for decoder changes (not part of the normal suite —
/// requires the developer machine's real analysis caches). Run with:
///
///     SW_OFFLINE_VALIDATION=1 swift test --filter ChordDecoderOfflineValidationTests
///
/// Replays every cached harmony analysis (chroma frames + beat grid) in the app container
/// through the decoder WITH and WITHOUT the metric (downbeat-aware) switch-penalty prior,
/// pairing each analysis with a drums stem by duration to estimate the bar phase the way
/// `TranscriptionStage`/`HarmonyStage` does. Reports per-song event counts, chords-per-bar
/// density, sub-beat events, and exactly which events the prior removed/moved — the decision
/// evidence for tuning `downbeatFactor`/`weakBeatFactor`.
final class ChordDecoderOfflineValidationTests: XCTestCase {
    private struct RawEnvelope: Decodable {
        let key: AnalysisResultCacheKey
        let value: SongAudioAnalysis
    }

    private var containerCaches: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/Caches/SongWorkbench/Analysis"
            )
    }

    private var containerStems: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/Analysis/Stems"
            )
    }

    func testMetricPenaltyOfflineValidation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SW_OFFLINE_VALIDATION"] == "1",
            "manual harness; set SW_OFFLINE_VALIDATION=1 to run against the local container")

        let fm = FileManager.default
        let jsons = try fm.contentsOfDirectory(at: containerCaches, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let drumStems =
            (try? fm.contentsOfDirectory(at: containerStems, includingPropertiesForKeys: nil))?
            .compactMap { dir -> (url: URL, duration: TimeInterval)? in
                let drums = dir.appendingPathComponent("drums.wav")
                guard fm.fileExists(atPath: drums.path),
                    let file = try? AVAudioFile(forReading: drums)
                else { return nil }
                return (drums, Double(file.length) / file.processingFormat.sampleRate)
            } ?? []

        var analyzed = 0
        var withMeter = 0
        for url in jsons {
            guard let data = try? Data(contentsOf: url),
                let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
                !envelope.value.chords.isEmpty,
                let beat = envelope.value.beat, beat.beatTimes.count >= 8, beat.bpm > 0
            else { continue }
            // Only harmony caches decode into non-empty chords; identifier double-checks.
            guard envelope.key.engine.identifier.contains("harmony") else { continue }
            analyzed += 1

            let analysis = envelope.value
            let beats = beat.beatTimes
            let songEnd = beats.last ?? 0
            let key = analysis.estimatedKey ?? MusicalKeyEstimator().estimate(from: analysis.chords)

            // Pair a drums stem by duration (within 2 s of the beat-grid extent).
            let drums = drumStems.min {
                abs($0.duration - songEnd) < abs($1.duration - songEnd)
            }
            var meter: ChordTimelineDecoder.BarMeter?
            var confidence = 0.0
            if let drums, abs(drums.duration - songEnd) < 2.0,
                let strengths = try? DrumAccentProfile.beatStrengths(
                    url: drums.url, beatTimes: beats, bpm: beat.bpm)
            {
                confidence = DownbeatEstimator.downbeatConfidence(beatStrengths: strengths)
                if confidence >= 0.08 {
                    meter = .init(
                        beatsPerBar: 4,
                        barPhase: DownbeatEstimator.barPhase(beatStrengths: strengths))
                }
            }

            let decoder = ChordTimelineDecoder()
            let old = decoder.events(from: analysis, key: key)
            let new = decoder.events(from: analysis, key: key, meter: meter)
            if meter != nil { withMeter += 1 }

            func stats(_ events: [EditableChordEvent]) -> String {
                let bars = max(1.0, Double(beats.count) / 4.0)
                let beatLength = 60.0 / beat.bpm
                var subBeat = 0
                for i in 1..<max(events.count, 1) where i < events.count {
                    if events[i].time - events[i - 1].time < beatLength * 0.9 { subBeat += 1 }
                }
                return String(
                    format: "%3d events  %.2f/bar  %d sub-beat",
                    events.count, Double(events.count) / bars, subBeat)
            }

            let name = url.deletingPathExtension().lastPathComponent.prefix(8)
            print(
                "── \(name)  bpm \(Int(beat.bpm))  meterConf \(String(format: "%.3f", confidence))"
                    + (meter.map { "  phase \($0.barPhase)" } ?? "  meter=nil"))
            print("   old: \(stats(old))")
            print("   new: \(stats(new))")
            if old.count != new.count {
                let oldSet = Set(old.map { "\(String(format: "%.2f", $0.time)) \($0.chord)" })
                let newSet = Set(new.map { "\(String(format: "%.2f", $0.time)) \($0.chord)" })
                let removed = oldSet.subtracting(newSet).sorted()
                let added = newSet.subtracting(oldSet).sorted()
                if !removed.isEmpty { print("   removed: \(removed.joined(separator: ", "))") }
                if !added.isEmpty { print("   added:   \(added.joined(separator: ", "))") }
            }
        }
        print("═══ validated \(analyzed) cached analyses, \(withMeter) with a usable meter ═══")
        XCTAssertGreaterThan(analyzed, 0, "no harmony caches found — container path changed?")
    }

    /// Sub-beat decode (derived subdivision + subdivision-scaled switch penalty, 2026-08-20)
    /// vs the old beat-window configuration, across every cached real-song analysis. Reports
    /// the event-density shift so a runaway (flicker explosion, or chords collapsing away)
    /// shows up here before it shows up in a chart. Flat meter, like the harness above — the
    /// drum-locked grid and bar phase are not in these caches.
    func testSubBeatDecodeOfflineComparison() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SW_OFFLINE_VALIDATION"] == "1",
            "manual harness; set SW_OFFLINE_VALIDATION=1 to run against the local container")

        let fm = FileManager.default
        let jsons = try fm.contentsOfDirectory(at: containerCaches, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var analyzed = 0
        var totalOld = 0
        var totalNew = 0
        var subdivisionCounts: [Int: Int] = [:]
        for url in jsons {
            guard let data = try? Data(contentsOf: url),
                let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
                !envelope.value.chords.isEmpty,
                let beat = envelope.value.beat, beat.beatTimes.count >= 8, beat.bpm > 0,
                envelope.key.engine.identifier.contains("harmony")
            else { continue }
            analyzed += 1
            let analysis = envelope.value
            let beats = beat.beatTimes
            let key = analysis.estimatedKey ?? MusicalKeyEstimator().estimate(from: analysis.chords)
            let beatLength = 60.0 / beat.bpm
            let subdivision = HarmonyDecodeResolution.subdivision(beatLength: beatLength)
            subdivisionCounts[subdivision, default: 0] += 1

            let old = ChordTimelineDecoder().events(from: analysis, key: key)
            var scaled = ChordTimelineDecoder()
            scaled.switchPenalty *= Float(subdivision)
            let new = scaled.events(
                from: analysis, key: key,
                beatTimes: ChordTimelineDecoder.subdivided(beats, by: subdivision))

            func stats(_ events: [EditableChordEvent]) -> String {
                let bars = max(1.0, Double(beats.count) / 4.0)
                var subBeat = 0
                for i in 1..<max(events.count, 1) where i < events.count {
                    if events[i].time - events[i - 1].time < beatLength * 0.9 { subBeat += 1 }
                }
                return String(
                    format: "%3d events  %.2f/bar  %d sub-beat",
                    events.count, Double(events.count) / bars, subBeat)
            }
            totalOld += old.count
            totalNew += new.count
            let name = url.deletingPathExtension().lastPathComponent.prefix(8)
            print("── \(name)  bpm \(Int(beat.bpm))  subdivision \(subdivision)")
            print("   beat-window: \(stats(old))")
            print("   sub-beat:    \(stats(new))")
        }
        let ratio = totalOld > 0 ? Double(totalNew) / Double(totalOld) : 0
        print(
            "═══ \(analyzed) songs · subdivisions \(subdivisionCounts.sorted { $0.key < $1.key }) "
                + "· events \(totalOld) → \(totalNew) (×\(String(format: "%.2f", ratio))) ═══")
        XCTAssertGreaterThan(analyzed, 0, "no harmony caches found — container path changed?")
    }
}
