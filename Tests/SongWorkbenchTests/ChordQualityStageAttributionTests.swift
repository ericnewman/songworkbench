import AVFoundation
import XCTest

@testable import SongWorkbench

/// MANUAL offline diagnostic for the seventh-chord defect (not part of the normal suite —
/// requires the developer machine's real analysis caches). Run with:
///
///     SW_CHORD_STAGE_ATTR=1 SW_CHORD_STAGE_ATTR_OUT=/tmp/stage_attr.txt \
///       swift test --filter ChordQualityStageAttributionTests
///
/// Measured defect this exists to attribute (`Benchmarks/STEM_SOURCE_CHORD_ACCURACY.md`):
/// `maj7` is emitted 6.8 % of chord time where the ground-truth charts contain 0 %, and `m7`
/// is emitted 0.0 % where truth contains 2.8 %. The raw cached frames rule out the classifier
/// as the source of the maj7 — 5-17 maj7 FRAMES per song become 10-20 maj7 EVENTS — so the
/// inflation happens somewhere downstream and this harness finds out where.
///
/// Replays each cached harmony analysis through every stage of the real decode path in order,
/// tallying the chord-quality distribution after each one, so a quality that appears (or
/// disappears) can be pinned to a single stage rather than to "the pipeline".
///
/// Stage order mirrors `ChordTimelineDecoder.events` + `HarmonyStage.run`
/// (`AnalysisStage.swift:805-850`). NOTE it includes `ChorusChordConsensus` (S9), which
/// `StemSourceChordAccuracyTests` deliberately skips — that omission is why the harness's 6.8 %
/// and the persisted x20 maj7 count describe different pipelines.
final class ChordQualityStageAttributionTests: XCTestCase {
    private struct RawEnvelope: Decodable {
        let key: AnalysisResultCacheKey
        let value: SongAudioAnalysis
    }

    /// Minimal projection of `songs/*.json`. Deliberately NOT `StoredSongProject`: this only
    /// needs lyrics (to drive S9) and the duration used to pair a document with a cache entry,
    /// and a narrow struct cannot fail to decode because some unrelated field's schema moved.
    private struct SongDocumentProjection: Decodable {
        struct Analysis: Decodable {
            var lyrics: [TimedLyricSegment]?
            var beatTimes: [TimeInterval]?
            var sourceDuration: TimeInterval?
        }
        var analysis: Analysis?
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

    private var containerSongs: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.local.SongWorkbench/Data/Library/Application Support/SongWorkbench/songs"
            )
    }

    func testChordQualityStageAttribution() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SW_CHORD_STAGE_ATTR"] == "1",
            "manual diagnostic; set SW_CHORD_STAGE_ATTR=1 to run against the local container")

        let sink = Sink(path: ProcessInfo.processInfo.environment["SW_CHORD_STAGE_ATTR_OUT"])
        defer { sink.close() }
        sink.emit("=== chord-quality stage attribution ===")
        sink.emit("stages: S0 cached frames -> S9 chorus consensus (production order)")

        let fm = FileManager.default
        let jsons = try fm.contentsOfDirectory(at: containerCaches, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let stemDirs = Self.stemDirectories(root: containerStems)
        let documents = Self.songDocuments(root: containerSongs)

        var analyzed = 0
        for url in jsons {
            guard let data = try? Data(contentsOf: url),
                let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data),
                !envelope.value.chords.isEmpty,
                let beat = envelope.value.beat, beat.beatTimes.count >= 8, beat.bpm > 0,
                envelope.key.engine.identifier.contains("harmony")
            else { continue }

            let analysis = envelope.value
            let songEnd = beat.beatTimes.last ?? 0
            guard
                let stems = stemDirs.min(by: {
                    abs($0.duration - songEnd) < abs($1.duration - songEnd)
                }), abs(stems.duration - songEnd) < 2.0
            else { continue }
            analyzed += 1

            let name = String(url.deletingPathExtension().lastPathComponent.prefix(8))
            let guitarURL = stems.url.appendingPathComponent("guitar.wav")
            let bassURL = stems.url.appendingPathComponent("bass.wav")
            let drumsURL = stems.url.appendingPathComponent("drums.wav")
            let lyrics = Self.lyrics(matching: songEnd, in: documents)

            sink.emit("")
            sink.emit(
                "-- song=\(name) bpm=\(Int(beat.bpm)) frames=\(analysis.chords.count) "
                    + "stems=\(stems.url.lastPathComponent.prefix(8)) lyrics=\(lyrics.count)")

            // Shared inputs, built exactly as `HarmonyStage.run` builds them.
            let referenceBPM = beat.bpm
            var resolvedBeatTimes = beat.beatTimes
            if let onsets = try? InstrumentOnsetDetector.onsets(url: drumsURL), !onsets.isEmpty {
                let duration = max(onsets.last ?? 0, songEnd)
                let derived = DrumBeatGrid.beatTimes(
                    onsets: onsets, bpm: referenceBPM, duration: duration)
                if !derived.isEmpty { resolvedBeatTimes = derived }
            }
            let bassNotes = (try? BassLineAnalyzer().analyze(url: bassURL)) ?? []
            let bassCues = bassNotes.filter { $0.confidence >= 0.5 }.map(\.timestamp)
            var meter: ChordTimelineDecoder.BarMeter?
            if let strengths = try? DrumAccentProfile.beatStrengths(
                url: drumsURL, beatTimes: resolvedBeatTimes, bpm: referenceBPM),
                DownbeatEstimator.downbeatConfidence(beatStrengths: strengths) >= 0.08
            {
                meter = .init(
                    beatsPerBar: 4,
                    barPhase: DownbeatEstimator.barPhase(beatStrengths: strengths))
            }
            let key = analysis.estimatedKey ?? MusicalKeyEstimator().estimate(from: analysis.chords)
            let instrumentOnsets = (try? InstrumentOnsetDetector.onsets(url: guitarURL)) ?? []
            let sourceDuration = Self.duration(of: guitarURL)
            let decoder = ChordTimelineDecoder()

            // S0 - cached raw frames, straight from the chroma classifier.
            let s0 = analysis.chords
            sink.emit("   S0 frames            \(Self.render(observations: s0))")

            // S1 - bass-informed re-rooting at frame level (ChordTimelineDecoder.swift:92).
            let s1 = BassInformedChordRefiner().refineObservations(s0, bassNotes: bassNotes)
            sink.emit("   S1 bass re-root      \(Self.render(observations: s1))")
            let rewrites = Self.rewrites(from: s0, to: s1)
            if !rewrites.isEmpty {
                sink.emit("      quality rewrites: \(Self.renderCounts(rewrites))")
            }

            // S2 - the decoder's own confidence floor.
            let s2 = s1.filter { $0.confidence >= decoder.minimumConfidence }
            sink.emit(
                "   S2 conf>=\(decoder.minimumConfidence)        \(Self.render(observations: s2))")

            // S3 - Viterbi window labels, replicating `events(...)` step by step so the
            // per-window decision is observable rather than only its collapsed output.
            let rescorer = key.map { KeyPriorChordRescorer(key: $0) }
            let windows = ChordTimelineDecoder.windowEvidence(
                observations: s2, beatTimes: resolvedBeatTimes, rescorer: rescorer)
            let labels = ChordTimelineDecoder.observedLabels(windows)
            let penalties = ChordTimelineDecoder.windowSwitchPenalties(
                windows: windows,
                onsets: instrumentOnsets + bassCues,
                basePenalty: decoder.switchPenalty,
                onsetPenaltyFactor: decoder.onsetPenaltyFactor,
                onsetTolerance: decoder.onsetTolerance,
                meter: meter,
                downbeatFactor: decoder.downbeatFactor,
                halfBarFactor: decoder.halfBarFactor,
                weakBeatFactor: decoder.weakBeatFactor,
                minimumPenaltyFraction: decoder.minimumPenaltyFraction
            )
            let path = ChordTimelineDecoder.decode(
                windows: windows, labels: labels, switchPenalties: penalties,
                noChordFloor: decoder.noChordFloor)
            sink.emit("   S3 viterbi windows   \(Self.render(labels: path.compactMap { $0 }))")

            // S4 - collapse to events, then the same-root extension merge.
            var rawEvents: [EditableChordEvent] = []
            var previous: String?
            for (index, label) in path.enumerated() {
                guard let label, label != previous else { continue }
                rawEvents.append(
                    EditableChordEvent(
                        time: windows[index].start,
                        chord: label,
                        confidence: windows[index].meanRawConfidence[label] ?? 0.6))
                previous = label
            }
            let s4 = ChordTimelineDecoder.mergeSameRootExtensions(rawEvents)
            sink.emit(
                "   S4 merge extensions  \(Self.render(events: s4)) "
                    + "(from \(rawEvents.count) raw)")

            // S5 - the real entry point, as a cross-check that S1-S4 replicated it faithfully.
            let s5 = decoder.events(
                from: analysis, key: key, bassNotes: bassNotes,
                instrumentOnsets: instrumentOnsets + bassCues,
                beatTimes: resolvedBeatTimes, meter: meter)
            let replicated = s4.map(\.chord) == s5.map(\.chord)
            sink.emit("   S5 decoder.events    \(Self.render(events: s5)) replicated=\(replicated)")

            // S6-S9 - the rest of `HarmonyStage.run`.
            let s6 = BassInformedChordRefiner().refine(s5, bassNotes: bassNotes)
            sink.emit("   S6 event re-root     \(Self.render(events: s6))")
            let s7 =
                instrumentOnsets.isEmpty
                ? s6
                : ChordOnsetAligner.snap(
                    s6, toOnsets: instrumentOnsets, beatTimes: resolvedBeatTimes)
            sink.emit("   S7 onset snap        \(Self.render(events: s7))")
            let s8 = ChordEventDurationFilter.merge(
                s7, beatTimes: resolvedBeatTimes, sourceDuration: sourceDuration)
            sink.emit("   S8 duration filter   \(Self.render(events: s8))")
            let s9 = ChorusChordConsensus.applied(
                chords: s8, lyrics: lyrics, beatTimes: resolvedBeatTimes)
            sink.emit("   S9 chorus consensus  \(Self.render(events: s9))")
            let consensusRewrites = Self.rewrites(from: s8, to: s9)
            if !consensusRewrites.isEmpty {
                sink.emit("      quality rewrites: \(Self.renderCounts(consensusRewrites))")
            }

            // Sizing probe for the argmax fix: `refineObservations` scans its candidate list
            // FIRST-MATCH (`ChordClassification.swift:278-286`), so `.minor` returns before any
            // seventh is ever considered and `.minor7` is not in the list at all. Count how many
            // frames an argmax over all five qualities would label differently.
            let shipping = Self.simulate(
                observations: s0, bassNotes: bassNotes, select: Self.shippingSelect)
            let argmax = Self.simulate(
                observations: s0, bassNotes: bassNotes, select: Self.argmaxSelect)
            let sized = Self.simulate(
                observations: s0, bassNotes: bassNotes, select: Self.sizedSelect)
            let faithful = shipping.map(\.chord) == s1.map(\.chord)
            sink.emit(
                "   sim shipping         \(Self.render(observations: shipping)) faithful=\(faithful)"
            )
            sink.emit("   sim argmax           \(Self.render(observations: argmax))")
            sink.emit("   sim argmax+sized     \(Self.render(observations: sized))")
        }

        sink.emit("")
        sink.emit("=== attributed \(analyzed) cached analyses ===")
        XCTAssertGreaterThan(analyzed, 0, "no harmony caches found - container path changed?")
    }

    // MARK: - Rendering

    private static let qualityOrder: [String] = ChordQuality.allCases.map(\.rawValue)

    private static func render(observations: [ChordObservation]) -> String {
        render(
            counts: observations.reduce(into: [:]) {
                $0[$1.chord.quality.rawValue, default: 0] += 1
            })
    }

    private static func render(events: [EditableChordEvent]) -> String {
        render(labels: events.map(\.chord))
    }

    private static func render(labels: [String]) -> String {
        render(counts: labels.reduce(into: [:]) { $0[quality(ofLabel: $1), default: 0] += 1 })
    }

    private static func render(counts: [String: Int]) -> String {
        let total = max(counts.values.reduce(0, +), 1)
        let body = qualityOrder.map { quality -> String in
            let count = counts[quality] ?? 0
            return String(
                format: "%@ %d (%.1f%%)", quality, count, 100 * Double(count) / Double(total))
        }
        return "n=\(total)  " + body.joined(separator: "  ")
    }

    private static func renderCounts(_ counts: [String: Int]) -> String {
        counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key)x\($0.value)" }
            .joined(separator: " ")
    }

    /// Quality bucket of a rendered label ("Cmaj7" -> major7). Order matters: "Cm7" ends in
    /// "7" and "Cmaj7" ends in "7" too, so the longest suffixes must be tested first.
    static func quality(ofLabel label: String) -> String {
        if label.hasSuffix("maj7") { return ChordQuality.major7.rawValue }
        if label.hasSuffix("m7") { return ChordQuality.minor7.rawValue }
        if label.hasSuffix("7") { return ChordQuality.dominant7.rawValue }
        if label.hasSuffix("m") { return ChordQuality.minor.rawValue }
        return ChordQuality.major.rawValue
    }

    // MARK: - Attribution

    /// Per-index quality changes between two equal-length frame lists.
    private static func rewrites(from: [ChordObservation], to: [ChordObservation]) -> [String: Int]
    {
        guard from.count == to.count else { return [:] }
        var counts: [String: Int] = [:]
        for (before, after) in zip(from, to) where before.chord != after.chord {
            let key = "\(before.chord.quality.rawValue)->\(after.chord.quality.rawValue)"
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Quality changes between two event lists, matched by position in time. Consensus only
    /// rewrites labels in place (never adds or removes), so a positional zip is exact.
    private static func rewrites(from: [EditableChordEvent], to: [EditableChordEvent])
        -> [String: Int]
    {
        guard from.count == to.count else { return ["COUNT-CHANGED": abs(from.count - to.count)] }
        var counts: [String: Int] = [:]
        for (before, after) in zip(from, to) where before.chord != after.chord {
            let key = "\(quality(ofLabel: before.chord))->\(quality(ofLabel: after.chord))"
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Faithful re-implementation of `BassInformedChordRefiner.refineObservations`
    /// (`ChordClassification.swift:251-289`) with the candidate-selection rule factored out, so
    /// competing rules can be scored against the SAME frames before any shipping code changes.
    /// The `faithful=` flag on the `sim shipping` line asserts the re-implementation reproduces
    /// the real S1 output exactly — without that check these projections would be worthless.
    private static func simulate(
        observations: [ChordObservation],
        bassNotes: [BassNoteObservation],
        select: (Set<Int>, Int) -> ChordQuality?
    ) -> [ChordObservation] {
        guard !bassNotes.isEmpty else { return observations }
        let sorted = bassNotes.sorted { $0.timestamp < $1.timestamp }
        return observations.map { observation in
            let root = observation.chord.root.rawValue
            guard
                let sounding = sorted.last(where: {
                    $0.timestamp >= observation.timestamp - 4
                        && $0.timestamp <= observation.timestamp + 0.1
                }), sounding.confidence >= 0.35
            else { return observation }
            let bass = ((sounding.midiNote % 12) + 12) % 12
            guard bass != root else { return observation }
            let detected = triad(root: root, quality: observation.chord.quality)
            if detected.contains(bass) { return observation }
            guard let quality = select(detected, bass), let pitchClass = PitchClass(rawValue: bass)
            else { return observation }
            return ChordObservation(
                timestamp: observation.timestamp,
                chord: Chord(root: pitchClass, quality: quality),
                confidence: observation.confidence)
        }
    }

    /// Shipping rule: FIRST candidate in a fixed order sharing >= 2 tones. `.minor7` is absent
    /// from the list, so it can never be produced.
    private static func shippingSelect(_ detected: Set<Int>, _ bass: Int) -> ChordQuality? {
        [ChordQuality.major, .minor, .major7, .dominant7].first {
            tones(root: bass, quality: $0).intersection(detected).count >= 2
        }
    }

    /// Argmax over all five qualities at a >= 2 floor, tie-broken toward the plain triad.
    private static func argmaxSelect(_ detected: Set<Int>, _ bass: Int) -> ChordQuality? {
        best(detected: detected, bass: bass) { _, score in score >= 2 }
    }

    /// Argmax with a SIZE-NORMALISED floor: a triad must match 2 of its 3 tones, a seventh 3 of
    /// its 4. The shipping >= 2 floor is not normalised for chord size, which is why a 4-note
    /// seventh clears it so easily — it has more tones to hit the threshold with, so an
    /// unrelated bass note manufactures a maj7 out of a 2-tone coincidence.
    private static func sizedSelect(_ detected: Set<Int>, _ bass: Int) -> ChordQuality? {
        best(detected: detected, bass: bass) { quality, score in
            score >= (rank(quality) == 0 ? 2 : 3)
        }
    }

    private static func best(
        detected: Set<Int>,
        bass: Int,
        qualifies: (ChordQuality, Int) -> Bool
    ) -> ChordQuality? {
        ChordQuality.allCases
            .map {
                (quality: $0, score: tones(root: bass, quality: $0).intersection(detected).count)
            }
            .filter { qualifies($0.quality, $0.score) }
            .max { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                // Tie-break toward the plain triad: a seventh must EARN the extra tone.
                return rank(rhs.quality) < rank(lhs.quality)
            }?.quality
    }

    private static func rank(_ quality: ChordQuality) -> Int {
        switch quality {
        case .major, .minor: return 0
        case .major7, .minor7, .dominant7: return 1
        }
    }

    /// Mirrors `BassInformedChordRefiner.triad` / `.tones`, which are private.
    private static func triad(root: Int, quality: ChordQuality) -> Set<Int> {
        let third = (quality == .minor || quality == .minor7) ? 3 : 4
        return [root % 12, (root + third) % 12, (root + 7) % 12]
    }

    private static func tones(root: Int, quality: ChordQuality) -> Set<Int> {
        var result = triad(root: root, quality: quality)
        switch quality {
        case .major7: result.insert((root + 11) % 12)
        case .minor7, .dominant7: result.insert((root + 10) % 12)
        case .major, .minor: break
        }
        return result
    }

    // MARK: - Container discovery

    private static func stemDirectories(root: URL) -> [(url: URL, duration: TimeInterval)] {
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .compactMap { dir -> (url: URL, duration: TimeInterval)? in
                let guitar = dir.appendingPathComponent("guitar.wav")
                let bass = dir.appendingPathComponent("bass.wav")
                let drums = dir.appendingPathComponent("drums.wav")
                guard fm.fileExists(atPath: guitar.path), fm.fileExists(atPath: bass.path),
                    fm.fileExists(atPath: drums.path), let duration = duration(of: drums)
                else { return nil }
                return (dir, duration)
            } ?? []
    }

    private static func songDocuments(root: URL) -> [(
        lyrics: [TimedLyricSegment], end: TimeInterval
    )] {
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (lyrics: [TimedLyricSegment], end: TimeInterval)? in
                guard let data = try? Data(contentsOf: url),
                    let document = try? JSONDecoder().decode(
                        SongDocumentProjection.self, from: data),
                    let analysis = document.analysis
                else { return nil }
                let end = analysis.sourceDuration ?? analysis.beatTimes?.last ?? 0
                guard end > 0 else { return nil }
                return (analysis.lyrics ?? [], end)
            } ?? []
    }

    /// Lyrics from the song document whose duration matches this analysis. Empty when nothing
    /// matches, which makes S9 a no-op rather than wrong.
    private static func lyrics(
        matching songEnd: TimeInterval,
        in documents: [(lyrics: [TimedLyricSegment], end: TimeInterval)]
    ) -> [TimedLyricSegment] {
        guard let best = documents.min(by: { abs($0.end - songEnd) < abs($1.end - songEnd) }),
            abs(best.end - songEnd) < 2.0
        else { return [] }
        return best.lyrics
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Writes each song's block and fsyncs before moving on (`tasks/lessons.md:377-390`).
    final class Sink {
        private let handle: FileHandle?

        init(path: String?) {
            guard let path else {
                handle = nil
                return
            }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            handle = FileHandle(forWritingAtPath: path)
            try? handle?.truncate(atOffset: 0)
        }

        func emit(_ text: String) {
            print(text)
            guard let handle else { return }
            handle.write(Data((text + "\n").utf8))
            try? handle.synchronize()
        }

        func close() { try? handle?.close() }
    }
}
