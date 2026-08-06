import AVFoundation
import XCTest

@testable import SongWorkbench

/// Offline harness for the question "which stem should the chord chroma come from?" — guitar,
/// accompaniment, or the original full mix — plus the metrics needed to tell a stem problem apart
/// from a vocabulary problem.
///
/// Three tests:
/// - `testSyntheticThreeArmComparisonRunsEndToEnd` always runs on generated audio and proves the
///   harness is wired correctly. It asserts structure only, never accuracy.
/// - `testRealSongThreeArmComparison` is gated on `SW_STEM_SOURCE_EVAL=1` and reads real stems
///   from the environment, so no personal path is ever baked into the repo.
/// - `testBatchAgreementAcrossSeparatedSongs` is gated on `SW_STEM_BATCH=1` and sweeps a whole
///   library of separated songs in agreement-only mode — no ground truth, no accuracy.
///
///     SW_STEM_SOURCE_EVAL=1 \
///     SW_STEM_SOURCE_EVAL_DIR=/path/to/stems \
///     SW_STEM_SOURCE_EVAL_MIX=/path/to/mix.wav \
///     SW_STEM_SOURCE_EVAL_CHART=/path/to/reviewed.cho \
///     swift test --filter StemSourceChordAccuracyTests
final class StemSourceChordAccuracyTests: XCTestCase {

    // MARK: - Report types

    struct ArmReport {
        let name: String
        let eventCount: Int
        let estimatedKey: String
        /// The grid this arm actually decoded on. Recorded per arm so the shared-grid control can
        /// be *checked* rather than assumed.
        let beatTimes: [TimeInterval]
        let spans: [Span]
        let rootAccuracy: Double?
        let fullAccuracy: Double?
    }

    struct PairAgreement {
        let left: String
        let right: String
        let fraction: Double
    }

    struct Report {
        let arms: [ArmReport]
        let sharedBeatCount: Int
        let gridIdenticalAcrossArms: Bool
        let groundTruthLabelCount: Int
        /// Fraction of ground-truth labels whose quality cannot be expressed by `ChordQuality`.
        let vocabularyCeiling: Double?
        let pairwiseAgreement: [PairAgreement]
    }

    /// A chord held over a half-open time span. Both the detected timeline and the ground-truth
    /// chart are piecewise-constant, so every metric here is an integral over these.
    struct Span {
        let start: TimeInterval
        let end: TimeInterval
        let label: String
    }

    // MARK: - Test 1: synthetic, always runs

    func testSyntheticThreeArmComparisonRunsEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemSourceChordAccuracy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let song = try Self.writeSyntheticSong(into: directory)
        let report = try await evaluate(
            arms: [
                (name: "guitar", url: song.guitar),
                (name: "accompaniment", url: song.accompaniment),
                (name: "fullmix", url: song.mix),
            ],
            bassURL: song.bass,
            drumsURL: song.drums,
            groundTruth: song.groundTruth
        )

        print(Self.render(report, title: "synthetic 4-bar C-F-G-C at 100 BPM"))

        XCTAssertEqual(report.arms.count, 3)
        // The experimental control itself: every arm must have decoded on the same grid, or the
        // comparison measures grid drift instead of chroma source.
        XCTAssertTrue(report.gridIdenticalAcrossArms, "arms decoded on different beat grids")
        XCTAssertGreaterThan(report.sharedBeatCount, 1, "shared grid degenerated to a fallback")
        for arm in report.arms {
            XCTAssertFalse(arm.beatTimes.isEmpty, "\(arm.name) produced no beat grid")
        }
        // Deliberately no accuracy assertion: sine triads are not a quality bar, and pinning one
        // here would turn a synthesis tweak into a false failure.
    }

    // MARK: - Test 2: real stems, env-gated

    func testRealSongThreeArmComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SW_STEM_SOURCE_EVAL"] == "1",
            "manual harness; set SW_STEM_SOURCE_EVAL=1 plus SW_STEM_SOURCE_EVAL_DIR and "
                + "SW_STEM_SOURCE_EVAL_MIX to run against real stems")

        guard
            let stemDirectory = environment["SW_STEM_SOURCE_EVAL_DIR"].map(
                { URL(fileURLWithPath: $0) })
        else { throw XCTSkip("SW_STEM_SOURCE_EVAL_DIR is unset") }
        guard
            let mixURL = environment["SW_STEM_SOURCE_EVAL_MIX"].map(
                { URL(fileURLWithPath: $0) })
        else { throw XCTSkip("SW_STEM_SOURCE_EVAL_MIX is unset") }

        let guitarURL = stemDirectory.appendingPathComponent("guitar.wav")
        let accompanimentURL = stemDirectory.appendingPathComponent("accompaniment.wav")
        let bassURL = stemDirectory.appendingPathComponent("bass.wav")
        let drumsURL = stemDirectory.appendingPathComponent("drums.wav")

        let manager = FileManager.default
        let required = [guitarURL, accompanimentURL, mixURL]
        for url in required where !manager.fileExists(atPath: url.path) {
            throw XCTSkip("missing required input: \(url.path)")
        }

        var groundTruth: [(time: TimeInterval, label: String)]?
        if let chartPath = environment["SW_STEM_SOURCE_EVAL_CHART"] {
            guard manager.fileExists(atPath: chartPath) else {
                throw XCTSkip("SW_STEM_SOURCE_EVAL_CHART does not exist: \(chartPath)")
            }
            let source = try String(contentsOfFile: chartPath, encoding: .utf8)
            let entries = ChordProChordTimeCarrier.parse(source)
            guard !entries.isEmpty else {
                throw XCTSkip("chart has no {x_chord_times:...} entries: \(chartPath)")
            }
            groundTruth = entries.map { (time: $0.time, label: $0.label) }
        }

        let report = try await evaluate(
            arms: [
                (name: "guitar", url: guitarURL),
                (name: "accompaniment", url: accompanimentURL),
                (name: "fullmix", url: mixURL),
            ],
            bassURL: manager.fileExists(atPath: bassURL.path) ? bassURL : nil,
            drumsURL: manager.fileExists(atPath: drumsURL.path) ? drumsURL : nil,
            groundTruth: groundTruth
        )

        print(Self.render(report, title: stemDirectory.lastPathComponent))
        XCTAssertTrue(report.gridIdenticalAcrossArms, "arms decoded on different beat grids")
    }

    // MARK: - Test 3: batch sweep, env-gated

    /// One arm pair on one song. The disagreement is split because the two halves mean different
    /// things: a ROOT divergence says the arms heard a different chord, a QUALITY divergence says
    /// they heard the same chord and disagreed only about its colour (C vs Cmaj7). A stem-source
    /// problem shows up mostly as root divergence; a vocabulary/threshold problem mostly as quality.
    struct BatchPairMetrics {
        let left: String
        let right: String
        let agree: Double
        let rootDiverge: Double
        let qualityDiverge: Double
    }

    struct BatchSongResult {
        let id: String
        let duration: TimeInterval
        let events: [(arm: String, count: Int)]
        let pairs: [BatchPairMetrics]
        /// Per arm, the fraction of labelled time spent in each of `qualityOrder`.
        let qualities: [(arm: String, distribution: [Double])]
    }

    /// Agreement-only sweep across a library of separated songs. There is NO ground truth here, so
    /// nothing in the output says which arm is right — only how far the chord read moves when the
    /// chroma source changes while the grid, bass notes, and meter are held fixed.
    ///
    ///     SW_STEM_BATCH=1 \
    ///     SW_STEM_BATCH_ROOT=/path/to/library \
    ///     SW_STEM_BATCH_MIXMAP=/path/to/mixes.tsv \
    ///     swift test --filter StemSourceChordAccuracyTests
    ///
    /// `SW_STEM_BATCH_ROOT` holds one subdirectory per song (guitar.wav, accompaniment.wav,
    /// bass.wav, drums.wav). `SW_STEM_BATCH_MIXMAP` is optional and maps `<stemDirName>\t<mix path>`
    /// one per line; songs without a row simply run two arms instead of three.
    func testBatchAgreementAcrossSeparatedSongs() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SW_STEM_BATCH"] == "1",
            "manual harness; set SW_STEM_BATCH=1 plus SW_STEM_BATCH_ROOT (and optionally "
                + "SW_STEM_BATCH_MIXMAP) to sweep a separated-stem library")

        guard let rootPath = environment["SW_STEM_BATCH_ROOT"] else {
            throw XCTSkip("SW_STEM_BATCH_ROOT is unset")
        }
        let manager = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: rootPath, isDirectory: &rootIsDirectory),
            rootIsDirectory.boolValue
        else { throw XCTSkip("SW_STEM_BATCH_ROOT is not a directory: \(rootPath)") }
        let root = URL(fileURLWithPath: rootPath)

        let mixes = Self.loadMixMap(environment["SW_STEM_BATCH_MIXMAP"])
        // Sorted so two runs over the same library produce diffable output.
        let songDirectories = try manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        print(Self.batchBanner)
        print(Self.batchVocabularyNote)
        print("batch_root=\(root.path)")
        print("candidate_songs=\(songDirectories.count) mixmap_entries=\(mixes.count)")

        var results: [BatchSongResult] = []
        for directory in songDirectories {
            let id = directory.lastPathComponent
            let guitarURL = directory.appendingPathComponent("guitar.wav")
            let accompanimentURL = directory.appendingPathComponent("accompaniment.wav")
            guard manager.fileExists(atPath: guitarURL.path),
                manager.fileExists(atPath: accompanimentURL.path)
            else {
                print("song=\(Self.shortID(id)) status=skipped reason=missing_guitar_or_accomp")
                continue
            }

            var arms: [(name: String, url: URL)] = [
                (name: "guitar", url: guitarURL),
                (name: "accompaniment", url: accompanimentURL),
            ]
            if let mixURL = mixes[id], manager.fileExists(atPath: mixURL.path) {
                arms.append((name: "fullmix", url: mixURL))
            }

            do {
                // THE CONTROL: bass and drums are always handed in, so every arm of a song decodes
                // on the same drums-derived grid with the same bass notes. `evaluate` degrades to
                // the plain uniform grid on its own if a stem is absent or unreadable.
                let report = try await evaluate(
                    arms: arms,
                    bassURL: directory.appendingPathComponent("bass.wav"),
                    drumsURL: directory.appendingPathComponent("drums.wav"),
                    groundTruth: nil
                )
                XCTAssertTrue(
                    report.gridIdenticalAcrossArms,
                    "\(id): arms decoded on different beat grids")
                let result = Self.batchResult(id: id, report: report, sourceURL: guitarURL)
                results.append(result)
                // Printed as we go: a 25-song run takes long enough that a silent test looks hung.
                print(Self.batchProgressLine(result, gridIdentical: report.gridIdenticalAcrossArms))
            } catch {
                // One unreadable song must not cost the other twenty-four.
                print("song=\(Self.shortID(id)) status=failed reason=\(error)")
            }
        }

        XCTAssertFalse(results.isEmpty, "no song under \(root.path) produced a result")
        guard !results.isEmpty else { return }
        print(Self.renderBatch(results))
    }

    // MARK: - Test 4: ground-truth sequences, env-gated

    /// One chord reduced to what can actually be compared across a chart and a detection: a CONCERT
    /// pitch class plus one of the five qualities the decoder can emit. `quality` is `nil` for an
    /// out-of-vocabulary chart suffix (add9, 6, sus4, dim, aug, ...) — the root of such a chord is
    /// still comparable, its colour is not.
    struct SequenceToken: Equatable {
        let root: Int
        let quality: String?
    }

    /// One LCS match count turned into the full precision/recall/F1 triple.
    ///
    /// A single LCS element is simultaneously one chart chord and one detected chord, so the same
    /// `matched` integer is the numerator of both ratios. Recall alone — all this file scored
    /// before — can never FALL when an arm emits more chords, so an arm over-segmenting 3.6x posted
    /// 100% while disagreeing with the chart about nearly every boundary. F1 is the number that
    /// cannot be gamed that way; precision and recall stay beside it because the DIRECTION of the
    /// error matters (low precision = over-segmentation, low recall = missed chords).
    struct SequenceScore {
        let matched: Int
        let truthCount: Int
        let detectedCount: Int

        /// False when the chart contributed nothing to compare against. Reported as `n/a` rather
        /// than 0.0, which would read as a detector failure instead of an absent yardstick.
        var isScorable: Bool { truthCount > 0 }

        /// Fraction of the chart's chords that were found. Numerically IDENTICAL to the old
        /// `*_seq_acc_pct` value, so numbers from the earlier benchmark run stay comparable.
        var recall: Double? {
            isScorable ? Double(matched) / Double(truthCount) : nil
        }

        /// Fraction of the emitted chords that were real. Zero when the arm emitted nothing at
        /// all — no true positives among no predictions.
        var precision: Double? {
            guard isScorable else { return nil }
            return detectedCount > 0 ? Double(matched) / Double(detectedCount) : 0
        }

        var f1: Double? {
            guard let precision, let recall else { return nil }
            let total = precision + recall
            guard total > 0 else { return 0 }
            return 2 * precision * recall / total
        }

        /// `detected / truth`. Printed as its own column rather than left for the reader to
        /// divide: the 3.6x over-detection that made one song's 100% recall meaningless stayed
        /// invisible for a whole benchmark run precisely because it was implicit.
        var overSegmentationRatio: Double? {
            isScorable ? Double(detectedCount) / Double(truthCount) : nil
        }
    }

    /// Detected sequence lengths travel with the scores so over- and under-segmentation is visible:
    /// an arm can score well on roots while emitting three times as many chords as the chart lists.
    struct SequenceArmResult {
        let arm: String
        let root: SequenceScore
        let full: SequenceScore
    }

    struct SequenceSongResult {
        let id: String
        /// The chart's `{subtitle: ...}` line verbatim, so charts can be tiered by trustworthiness
        /// straight from the report without opening the source files.
        let provenance: String
        /// Free-text trust bucket — the manifest's optional 5th column, else the `{subtitle:}`
        /// value. A REPORTING dimension only: no song is ever skipped or excluded by its tier.
        let tier: String
        let capo: Int
        let writtenKey: String
        let concertKey: String
        let truthRootLength: Int
        let truthFullLength: Int
        let collapsedTruthLength: Int
        let oovCount: Int
        let arms: [SequenceArmResult]

        var oovFraction: Double {
            guard collapsedTruthLength > 0 else { return 0 }
            return Double(oovCount) / Double(collapsedTruthLength)
        }
    }

    struct GroundTruthRow {
        let id: String
        let stemDirectory: URL
        let mix: URL?
        let chart: URL
        /// Optional 5th column. `nil` means "fall back to the chart's own `{subtitle:}`".
        let tier: String?
    }

    struct GroundTruthChart {
        let capo: Int
        let writtenKey: String?
        let provenance: String
        /// Concert pitch, consecutive duplicates already collapsed.
        let tokens: [SequenceToken]
    }

    /// Scores the detector against human-authored ChordPro charts.
    ///
    /// Those charts carry NO timing — no `{x_chord_times:...}`, just inline `[C]` markup over lyric
    /// text — so a time-weighted accuracy is not merely inconvenient here, it is uncomputable. What
    /// IS computable is the ordered chord SEQUENCE, scored by longest common subsequence: it credits
    /// the right chords in the right order and is blind to how long each was held.
    ///
    ///     SW_STEM_GT=1 \
    ///     SW_STEM_GT_MANIFEST=/path/to/songs.tsv \
    ///     SW_STEM_GT_OUT=/path/to/results.txt \
    ///     swift test --filter StemSourceChordAccuracyTests
    ///
    /// Manifest rows are
    /// `<stemDirName>\t<stems dir>\t<mix path or empty>\t<chart .cho path>[\t<tier>]`.
    func testGroundTruthSequenceAccuracy() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SW_STEM_GT"] == "1",
            "manual harness; set SW_STEM_GT=1 plus SW_STEM_GT_MANIFEST (and optionally "
                + "SW_STEM_GT_OUT) to score against human-authored charts")

        guard let manifestPath = environment["SW_STEM_GT_MANIFEST"] else {
            throw XCTSkip("SW_STEM_GT_MANIFEST is unset")
        }
        guard let manifestText = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            throw XCTSkip("SW_STEM_GT_MANIFEST is unreadable: \(manifestPath)")
        }
        let rows = Self.parseGroundTruthManifest(manifestText)
        guard !rows.isEmpty else {
            throw XCTSkip("SW_STEM_GT_MANIFEST has no usable rows: \(manifestPath)")
        }

        let manager = FileManager.default
        let sink = GroundTruthSink(path: environment["SW_STEM_GT_OUT"])
        defer { sink.close() }

        sink.emit(Self.sequenceBanner)
        sink.emit(Self.sequenceCapoNote)
        sink.emit(Self.sequenceScoringNote)
        sink.emit("manifest=\(manifestPath)")
        sink.emit("tuning=\(Self.tuningDescription)")
        sink.emit("candidate_songs=\(rows.count)")

        var results: [SequenceSongResult] = []
        for row in rows {
            let guitarURL = row.stemDirectory.appendingPathComponent("guitar.wav")
            let accompanimentURL = row.stemDirectory.appendingPathComponent("accompaniment.wav")
            guard manager.fileExists(atPath: guitarURL.path),
                manager.fileExists(atPath: accompanimentURL.path)
            else {
                sink.emit("song=\(Self.shortID(row.id)) status=skipped reason=missing_stems")
                continue
            }

            let chart: GroundTruthChart
            do {
                chart = try Self.loadGroundTruthChart(row.chart)
            } catch {
                // A chart the shipping parser rejects is a chart problem, not a detector problem —
                // one of them must not cost the rest of the sweep.
                sink.emit(
                    "song=\(Self.shortID(row.id)) status=skipped reason=chart_parse:\(error)")
                continue
            }
            guard !chart.tokens.isEmpty else {
                sink.emit("song=\(Self.shortID(row.id)) status=skipped reason=chart_has_no_chords")
                continue
            }

            var arms: [(name: String, url: URL)] = [
                (name: "guitar", url: guitarURL),
                (name: "accompaniment", url: accompanimentURL),
            ]
            if let mixURL = row.mix, manager.fileExists(atPath: mixURL.path) {
                arms.append((name: "fullmix", url: mixURL))
            }

            do {
                // Ground truth is deliberately passed as `nil`: `evaluate`'s own accuracy fields are
                // time-weighted, and these charts have no timing to weight with. The grid/bass/meter
                // control it applies is the reason this test reuses it at all.
                let report = try await evaluate(
                    arms: arms,
                    bassURL: row.stemDirectory.appendingPathComponent("bass.wav"),
                    drumsURL: row.stemDirectory.appendingPathComponent("drums.wav"),
                    groundTruth: nil
                )
                XCTAssertTrue(
                    report.gridIdenticalAcrossArms,
                    "\(row.id): arms decoded on different beat grids")
                let result = Self.sequenceResult(
                    id: row.id,
                    chart: chart,
                    report: report,
                    tier: Self.resolveTier(manifest: row.tier, provenance: chart.provenance))
                results.append(result)
                // Emitted and fsynced per song, not accumulated: a sweep of this size runs for
                // minutes, and a silent test is indistinguishable from a hung one.
                for line in Self.renderSequenceSong(result) { sink.emit(line) }
            } catch {
                sink.emit("song=\(Self.shortID(row.id)) status=failed reason=\(error)")
            }
        }

        XCTAssertFalse(results.isEmpty, "no song in \(manifestPath) produced a sequence score")
        guard !results.isEmpty else { return }
        for line in Self.renderSequenceAggregate(results) { sink.emit(line) }
    }

    // MARK: - Shared evaluation

    /// MIRRORS the production harmony sequence in `Sources/SongWorkbench/AnalysisStage.swift`
    /// (`HarmonyStage.run`, ~lines 740-839): drum-locked beat grid, bass-note detection, instrument
    /// onsets, key-prior Viterbi decode with a bar meter, bass re-rooting, onset snap, duration
    /// filter. IT WILL DRIFT IF THAT CHANGES — there is no compile-time link between the two.
    /// Driving `HarmonyStage.run` directly is not practical here: it needs a full
    /// `AnalysisStageContext` (request, document, cache, engines), so this is a deliberate
    /// duplication with a known maintenance cost. When harmony results move unexpectedly, diff this
    /// function against `HarmonyStage.run` first.
    ///
    /// THE EXPERIMENTAL CONTROL: the beat grid, bass notes, and bar meter are computed ONCE and
    /// passed identically to every arm. Every downstream step quantizes to the grid (the 0.8-beat
    /// duration filter, the onset snap), so per-arm grids would confound "which chroma source is
    /// better" with "whose grid drifted", and the experiment would measure nothing. Only the chroma
    /// source — and the per-arm instrument onsets that follow from it — varies.
    // MARK: - Segmentation sweep knobs

    /// Decoder parameters, overridable from the environment so the SAME scoring path can be run
    /// across a parameter grid without editing code between runs. Unset (the normal case) means
    /// the shipping defaults, so every existing invocation is byte-identical to before.
    ///
    /// Exists because over-segmentation — 1.1x to 3.7x more chord events than the reference
    /// charts carry — is the dominant F1 term (one song scores 100 % recall against 27 %
    /// precision), and stage attribution showed the excess comes out of the Viterbi decode
    /// itself, not the downstream filters: the extension merge and duration filter together
    /// only take 192 events to 174.
    static func tunedDecoder() -> ChordTimelineDecoder {
        var decoder = ChordTimelineDecoder()
        if let value = envFloat("SW_CHORD_SWITCH_PENALTY") { decoder.switchPenalty = value }
        if let value = envFloat("SW_CHORD_WEAK_BEAT_FACTOR") { decoder.weakBeatFactor = value }
        if let value = envFloat("SW_CHORD_ONSET_PENALTY_FACTOR") {
            decoder.onsetPenaltyFactor = value
        }
        if let value = envFloat("SW_CHORD_MIN_PENALTY_FRACTION") {
            decoder.minimumPenaltyFraction = value
        }
        return decoder
    }

    static var tunedMinimumBeatFraction: Double {
        envDouble("SW_CHORD_MIN_BEAT_FRACTION") ?? 0.8
    }

    /// One line describing the active knobs, so a sweep's output rows are self-identifying.
    static var tuningDescription: String {
        let decoder = tunedDecoder()
        return "switch=\(decoder.switchPenalty) weak=\(decoder.weakBeatFactor) "
            + "onset=\(decoder.onsetPenaltyFactor) minfrac=\(decoder.minimumPenaltyFraction) "
            + "minbeat=\(tunedMinimumBeatFraction)"
    }

    private static func envFloat(_ key: String) -> Float? {
        ProcessInfo.processInfo.environment[key].flatMap(Float.init)
    }

    private static func envDouble(_ key: String) -> Double? {
        ProcessInfo.processInfo.environment[key].flatMap(Double.init)
    }

    func evaluate(
        arms: [(name: String, url: URL)],
        bassURL: URL?,
        drumsURL: URL?,
        groundTruth: [(time: TimeInterval, label: String)]?
    ) async throws -> Report {
        XCTAssertFalse(arms.isEmpty, "evaluate requires at least one arm")

        // Step 0: per-arm chroma analysis. Run first because the shared grid needs a tempo prior,
        // and production takes that from the harmony result too.
        let service = AudioFileAnalysisService()
        var analyses: [SongAudioAnalysis] = []
        for arm in arms {
            analyses.append(try await service.analyze(url: arm.url))
        }

        let referenceBPM = analyses[0].beat?.bpm ?? 0
        let referenceBeatTimes = analyses[0].beat?.beatTimes ?? []

        // Step 1: ONE beat grid for every arm. Drum-locked when a drums stem exists, exactly as
        // `HarmonyStage.run` does; otherwise the first arm's own uniform grid.
        var sharedBeatTimes = referenceBeatTimes
        if let drumsURL, referenceBPM > 0,
            let onsets = try? InstrumentOnsetDetector.onsets(url: drumsURL), !onsets.isEmpty
        {
            let duration = max(onsets.last ?? 0, referenceBeatTimes.last ?? 0)
            let derived = DrumBeatGrid.beatTimes(
                onsets: onsets, bpm: referenceBPM, duration: duration)
            if !derived.isEmpty { sharedBeatTimes = derived }
        }
        let resolvedBeatTimes = sharedBeatTimes

        // Step 2: ONE bass line for every arm.
        let sharedBassNotes: [BassNoteObservation] =
            bassURL.flatMap { try? BassLineAnalyzer().analyze(url: $0) } ?? []
        let bassCues = sharedBassNotes.filter { $0.confidence >= 0.5 }.map(\.timestamp)

        // Step 3: ONE bar meter for every arm, behind the same 0.08 confidence gate production uses.
        var sharedMeter: ChordTimelineDecoder.BarMeter?
        if let drumsURL, referenceBPM > 0,
            let strengths = try? DrumAccentProfile.beatStrengths(
                url: drumsURL, beatTimes: resolvedBeatTimes, bpm: referenceBPM),
            DownbeatEstimator.downbeatConfidence(beatStrengths: strengths) >= 0.08
        {
            sharedMeter = ChordTimelineDecoder.BarMeter(
                beatsPerBar: 4,
                barPhase: DownbeatEstimator.barPhase(beatStrengths: strengths)
            )
        }

        // Steps 4-6: per arm, vary only the chroma source.
        var armReports: [ArmReport] = []
        for (index, arm) in arms.enumerated() {
            let analysis = analyses[index]
            let key = analysis.estimatedKey ?? MusicalKeyEstimator().estimate(from: analysis.chords)
            let instrumentOnsets = (try? InstrumentOnsetDetector.onsets(url: arm.url)) ?? []
            let sourceDuration = Self.duration(of: arm.url)

            var events = BassInformedChordRefiner().refine(
                Self.tunedDecoder().events(
                    from: analysis,
                    key: key,
                    bassNotes: sharedBassNotes,
                    instrumentOnsets: instrumentOnsets + bassCues,
                    beatTimes: resolvedBeatTimes,
                    meter: sharedMeter
                ),
                bassNotes: sharedBassNotes
            )
            if !instrumentOnsets.isEmpty {
                events = ChordOnsetAligner.snap(
                    events, toOnsets: instrumentOnsets, beatTimes: resolvedBeatTimes)
            }
            events = ChordEventDurationFilter.merge(
                events,
                beatTimes: resolvedBeatTimes,
                minimumBeatFraction: Self.tunedMinimumBeatFraction,
                sourceDuration: sourceDuration)
            // ChorusChordConsensus is skipped on purpose: it rewrites labels using lyric sections
            // and is a no-op without lyrics, so including it would add a dependency this harness
            // cannot feed.

            let end = sourceDuration ?? resolvedBeatTimes.last ?? events.last?.time ?? 0
            let spans = Self.spans(
                events.map { (time: $0.time, label: $0.chord) }, end: end)

            var rootAccuracy: Double?
            var fullAccuracy: Double?
            if let groundTruth, !groundTruth.isEmpty {
                let truthSpans = Self.spans(groundTruth, end: max(end, groundTruth.last?.time ?? 0))
                rootAccuracy = Self.agreement(spans, truthSpans, matching: Self.rootsMatch)
                fullAccuracy = Self.agreement(spans, truthSpans, matching: Self.chordsMatch)
            }

            armReports.append(
                ArmReport(
                    name: arm.name,
                    eventCount: events.count,
                    estimatedKey: key?.displayName ?? "-",
                    beatTimes: resolvedBeatTimes,
                    spans: spans,
                    rootAccuracy: rootAccuracy,
                    fullAccuracy: fullAccuracy
                )
            )
        }

        var pairwise: [PairAgreement] = []
        for left in armReports.indices {
            for right in (left + 1)..<armReports.count {
                guard
                    let fraction = Self.agreement(
                        armReports[left].spans, armReports[right].spans, matching: Self.chordsMatch)
                else { continue }
                pairwise.append(
                    PairAgreement(
                        left: armReports[left].name,
                        right: armReports[right].name,
                        fraction: fraction))
            }
        }

        return Report(
            arms: armReports,
            sharedBeatCount: resolvedBeatTimes.count,
            gridIdenticalAcrossArms: armReports.allSatisfy { $0.beatTimes == resolvedBeatTimes },
            groundTruthLabelCount: groundTruth?.count ?? 0,
            vocabularyCeiling: groundTruth.map(Self.vocabularyCeiling),
            pairwiseAgreement: pairwise
        )
    }

    // MARK: - Metrics

    /// Builds a piecewise-constant timeline: each chord holds until the next one starts, and the
    /// last holds until `end`.
    static func spans(_ points: [(time: TimeInterval, label: String)], end: TimeInterval) -> [Span]
    {
        let sorted = points.sorted { $0.time < $1.time }.filter { $0.time < end }
        return sorted.enumerated().compactMap { index, point in
            let stop = index + 1 < sorted.count ? min(sorted[index + 1].time, end) : end
            guard stop > point.time else { return nil }
            return Span(start: point.time, end: stop, label: point.label)
        }
    }

    /// Time-weighted agreement between two piecewise-constant timelines, integrated over the span
    /// where both are defined. `nil` when they do not overlap.
    static func agreement(
        _ lhs: [Span],
        _ rhs: [Span],
        matching: (String, String) -> Bool
    ) -> Double? {
        guard let lhsStart = lhs.first?.start, let lhsEnd = lhs.last?.end,
            let rhsStart = rhs.first?.start, let rhsEnd = rhs.last?.end
        else { return nil }
        let start = max(lhsStart, rhsStart)
        let end = min(lhsEnd, rhsEnd)
        guard end > start else { return nil }

        var boundaries = Set<TimeInterval>([start, end])
        for span in lhs + rhs {
            if span.start > start && span.start < end { boundaries.insert(span.start) }
            if span.end > start && span.end < end { boundaries.insert(span.end) }
        }
        let ordered = boundaries.sorted()
        var matched = 0.0
        for index in 0..<(ordered.count - 1) {
            let width = ordered[index + 1] - ordered[index]
            guard width > 0 else { continue }
            let midpoint = ordered[index] + width / 2
            guard let left = label(at: midpoint, in: lhs), let right = label(at: midpoint, in: rhs)
            else { continue }
            if matching(left, right) { matched += width }
        }
        return matched / (end - start)
    }

    static func label(at time: TimeInterval, in spans: [Span]) -> String? {
        spans.first { time >= $0.start && time < $0.end }?.label
    }

    /// Fraction of ground-truth labels whose quality falls outside the five `ChordQuality` cases.
    /// This is the ceiling on FULL accuracy: no amount of stem-source improvement can push full
    /// accuracy above `1 - ceiling`, so a run where root accuracy is high and full accuracy sits
    /// near this number is vocabulary-bound, not stem-bound.
    static func vocabularyCeiling(_ groundTruth: [(time: TimeInterval, label: String)]) -> Double {
        guard !groundTruth.isEmpty else { return 0 }
        let unrepresentable = groundTruth.filter { parse($0.label)?.quality == nil }.count
        return Double(unrepresentable) / Double(groundTruth.count)
    }

    // MARK: - Batch metrics

    /// The five qualities the decoder can emit, in report order. Anything else parses to a `nil`
    /// quality and lands outside the distribution — the shortfall from 100% is the "other" bucket.
    static let qualityOrder: [(name: String, suffix: String)] = [
        (name: "major", suffix: ""),
        (name: "minor", suffix: "m"),
        (name: "maj7", suffix: "maj7"),
        (name: "m7", suffix: "m7"),
        (name: "dom7", suffix: "7"),
    ]

    /// Splits pairwise disagreement into root and quality halves.
    ///
    /// `chordsMatch` is a strict subset of `rootsMatch` (it requires equal roots first), so
    /// `agree <= rootAgree` and the three numbers sum to exactly 1. Time where either arm has no
    /// span, or emits a label that will not parse, counts as ROOT divergence — the same convention
    /// the existing `agreement` helper already uses when it declines to credit a slice.
    static func pairMetrics(_ left: ArmReport, _ right: ArmReport) -> BatchPairMetrics? {
        guard let agree = agreement(left.spans, right.spans, matching: chordsMatch),
            let rootAgree = agreement(left.spans, right.spans, matching: rootsMatch)
        else { return nil }
        return BatchPairMetrics(
            left: left.name,
            right: right.name,
            agree: agree,
            rootDiverge: 1 - rootAgree,
            qualityDiverge: max(0, rootAgree - agree)
        )
    }

    /// Fraction of labelled time each of the five emittable qualities occupies. Shows how much of
    /// the vocabulary the detector actually reaches for on real material.
    static func qualityDistribution(_ spans: [Span]) -> [Double] {
        var totals = [Double](repeating: 0, count: qualityOrder.count)
        // ponytail: denominator is labelled time, not file duration — the two differ only by the
        // lead-in before the first chord, and using labelled time keeps the row interpretable as
        // "of the chords it emitted, this is the mix".
        var labelled = 0.0
        for span in spans {
            let width = span.end - span.start
            guard width > 0 else { continue }
            labelled += width
            guard let quality = parse(span.label)?.quality,
                let index = qualityOrder.firstIndex(where: { $0.suffix == quality })
            else { continue }
            totals[index] += width
        }
        guard labelled > 0 else { return totals }
        return totals.map { $0 / labelled }
    }

    static func batchResult(id: String, report: Report, sourceURL: URL) -> BatchSongResult {
        // ponytail: song duration comes from the first arm's file, falling back to the decoded
        // timeline. Arms are the same song, so per-arm durations differ only by encoder padding —
        // not worth reconciling for what is only a weighting term.
        let songDuration = duration(of: sourceURL) ?? (report.arms.first?.spans.last?.end ?? 0)
        var pairs: [BatchPairMetrics] = []
        for left in report.arms.indices {
            for right in (left + 1)..<report.arms.count {
                guard let metrics = pairMetrics(report.arms[left], report.arms[right]) else {
                    continue
                }
                pairs.append(metrics)
            }
        }
        return BatchSongResult(
            id: id,
            duration: songDuration,
            events: report.arms.map { (arm: $0.name, count: $0.eventCount) },
            pairs: pairs,
            qualities: report.arms.map {
                (arm: $0.name, distribution: qualityDistribution($0.spans))
            }
        )
    }

    /// `<stemDirName>\t<absolute mix path>`, one per line. Missing file, unreadable file, and
    /// malformed line all degrade to "this song has no full-mix arm".
    static func loadMixMap(_ path: String?) -> [String: URL] {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var map: [String: URL] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let key = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let value = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key] = URL(fileURLWithPath: value)
        }
        return map
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - Chord label parsing

    struct ParsedChord {
        let root: Int
        /// One of the five `ChordQuality` cases in canonical suffix form, or `nil` when the label's
        /// quality cannot be represented at all (sus2, sus4, dim, aug, 6, 9, 11, 13, add9, ...).
        let quality: String?
        let rawSuffix: String
    }

    private static let pitchNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]
    private static let enharmonics = [
        "Db": "C#", "Eb": "D#", "Fb": "E", "Gb": "F#", "Ab": "G#", "Bb": "A#", "Cb": "B",
        "E#": "F", "B#": "C",
    ]
    /// Suffix spellings that map onto the five representable qualities.
    private static let representableQualities: [String: String] = [
        "": "", "maj": "", "M": "", "major": "",
        "m": "m", "min": "m", "-": "m", "minor": "m",
        "maj7": "maj7", "M7": "maj7", "Δ7": "maj7", "Δ": "maj7",
        "m7": "m7", "min7": "m7", "-7": "m7",
        "7": "7", "dom7": "7",
    ]

    static func parse(_ label: String) -> ParsedChord? {
        // ponytail: slash bass is stripped rather than modeled — "C/G" scores as C major, so
        // inversions do NOT count against the vocabulary ceiling. Upgrade path: add a bass field to
        // ParsedChord and a separate inversion metric, once the pipeline can emit slash chords.
        var text = label.trimmingCharacters(in: .whitespaces)
        if let slash = text.firstIndex(of: "/") { text = String(text[text.startIndex..<slash]) }
        guard let first = text.first, first.isLetter else { return nil }

        var root = String(first)
        var rest = String(text.dropFirst())
        if let accidental = rest.first, accidental == "#" || accidental == "b" {
            root.append(accidental)
            rest = String(rest.dropFirst())
        }
        root = enharmonics[root] ?? root
        guard let index = pitchNames.firstIndex(of: root) else { return nil }
        return ParsedChord(root: index, quality: representableQualities[rest], rawSuffix: rest)
    }

    static func rootsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = parse(lhs), let right = parse(rhs) else { return false }
        return left.root == right.root
    }

    static func chordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = parse(lhs), let right = parse(rhs), left.root == right.root
        else { return false }
        // Unrepresentable qualities fall back to the raw suffix, which the pipeline can never emit
        // — so they are always a full-accuracy miss. That is exactly the ceiling.
        return (left.quality ?? left.rawSuffix) == (right.quality ?? right.rawSuffix)
    }

    // MARK: - Output

    static func render(_ report: Report, title: String) -> String {
        var lines: [String] = []
        lines.append("=== stem-source chord accuracy: \(title) ===")
        lines.append("shared_beat_count=\(report.sharedBeatCount)")
        lines.append("grid_identical_across_arms=\(report.gridIdenticalAcrossArms)")
        lines.append("ground_truth_labels=\(report.groundTruthLabelCount)")
        if let ceiling = report.vocabularyCeiling {
            lines.append("vocabulary_ceiling_pct=\(percent(ceiling))")
            lines.append("max_attainable_full_accuracy_pct=\(percent(1 - ceiling))")
        } else {
            lines.append("vocabulary_ceiling_pct=n/a")
        }
        for arm in report.arms {
            lines.append(
                "arm=\(arm.name) events=\(arm.eventCount) key=\(arm.estimatedKey) "
                    + "root_acc_pct=\(percent(arm.rootAccuracy)) "
                    + "full_acc_pct=\(percent(arm.fullAccuracy))")
        }
        for pair in report.pairwiseAgreement {
            lines.append("agreement_\(pair.left)_vs_\(pair.right)_pct=\(percent(pair.fraction))")
        }
        lines.append("")
        lines.append("| arm | events | key | root acc | full acc |")
        lines.append("| --- | ---: | --- | ---: | ---: |")
        for arm in report.arms {
            lines.append(
                "| \(arm.name) | \(arm.eventCount) | \(arm.estimatedKey) "
                    + "| \(percent(arm.rootAccuracy)) | \(percent(arm.fullAccuracy)) |")
        }
        if !report.pairwiseAgreement.isEmpty {
            lines.append("")
            lines.append("| arm A | arm B | same-chord time |")
            lines.append("| --- | --- | ---: |")
            for pair in report.pairwiseAgreement {
                lines.append("| \(pair.left) | \(pair.right) | \(percent(pair.fraction)) |")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value * 100)
    }

    static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f", value) }

    /// Two decimals, not a percentage: `over_seg_ratio=3.62` is a multiplier, and printing it as
    /// "362.0" alongside a column of percentages would invite exactly the misreading this metric
    /// exists to prevent.
    static func ratio(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }

    // MARK: - Batch output

    static let batchBanner =
        "=== AGREEMENT-ONLY — NO GROUND TRUTH — divergence shows sensitivity to stem source, "
        + "NOT which arm is correct ==="

    /// Printed instead of `vocabulary_ceiling_pct`: the ceiling is a property of the *chart*, and
    /// computing it from detections would be a tautology, not a measurement.
    static let batchVocabularyNote =
        "note=vocabulary_ceiling_not_measurable_without_ground_truth (detector can only emit the "
        + "5 qualities, so any ceiling computed from detections is 0.0 by construction)"

    static func shortID(_ id: String) -> String { String(id.prefix(12)) }

    static func batchProgressLine(_ result: BatchSongResult, gridIdentical: Bool) -> String {
        let events = result.events.map { "\($0.arm):\($0.count)" }.joined(separator: ",")
        return "song=\(shortID(result.id)) status=ok duration_s=\(seconds(result.duration)) "
            + "arms=\(result.events.count) events=\(events) "
            + "grid_identical=\(gridIdentical)"
    }

    static func renderBatch(_ results: [BatchSongResult]) -> String {
        var lines: [String] = []
        // The banner and the vocabulary note are printed once, in the header, before the per-song
        // progress stream — repeating them here would just be noise in the pasted report.
        lines.append("")
        lines.append("=== per-song agreement ===")
        lines.append("")
        lines.append("| song | dur_s | arms | events | pair | agree % | root div % | qual div % |")
        lines.append("| --- | ---: | ---: | --- | --- | ---: | ---: | ---: |")
        for result in results {
            let events = result.events.map { "\($0.arm):\($0.count)" }.joined(separator: " ")
            for pair in result.pairs {
                lines.append(
                    "| \(shortID(result.id)) | \(seconds(result.duration)) "
                        + "| \(result.events.count) | \(events) "
                        + "| \(pair.left) vs \(pair.right) | \(percent(pair.agree)) "
                        + "| \(percent(pair.rootDiverge)) | \(percent(pair.qualityDiverge)) |")
            }
        }
        lines.append(contentsOf: renderBatchAggregate(results))
        return lines.joined(separator: "\n")
    }

    private static func renderBatchAggregate(_ results: [BatchSongResult]) -> [String] {
        var lines: [String] = []
        let totalDuration = results.reduce(0) { $0 + $1.duration }
        lines.append("")
        lines.append("=== aggregate ===")
        lines.append("songs=\(results.count)")
        lines.append("total_duration_s=\(seconds(totalDuration))")

        // Duration weighting keeps a 30 s fragment from counting as much as a 5 min song; the
        // unweighted median sits beside it so one pathological song cannot hide behind the mean.
        var pairOrder: [String] = []
        var agreeWeighted: [String: Double] = [:]
        var rootWeighted: [String: Double] = [:]
        var qualityWeighted: [String: Double] = [:]
        var pairWeight: [String: Double] = [:]
        var agreeValues: [String: [Double]] = [:]
        for result in results {
            for pair in result.pairs {
                let key = "\(pair.left)_vs_\(pair.right)"
                if !pairOrder.contains(key) { pairOrder.append(key) }
                agreeWeighted[key, default: 0] += pair.agree * result.duration
                rootWeighted[key, default: 0] += pair.rootDiverge * result.duration
                qualityWeighted[key, default: 0] += pair.qualityDiverge * result.duration
                pairWeight[key, default: 0] += result.duration
                agreeValues[key, default: []].append(pair.agree)
            }
        }

        var pairRows: [String] = []
        for key in pairOrder {
            let weight = pairWeight[key] ?? 0
            guard weight > 0 else { continue }
            let values = agreeValues[key] ?? []
            let agree = (agreeWeighted[key] ?? 0) / weight
            let root = (rootWeighted[key] ?? 0) / weight
            let quality = (qualityWeighted[key] ?? 0) / weight
            lines.append(
                "pair=\(key) songs=\(values.count) agree_pct=\(percent(agree)) "
                    + "root_diverge_pct=\(percent(root)) "
                    + "quality_diverge_pct=\(percent(quality)) "
                    + "median_agree_pct=\(percent(median(values)))")
            pairRows.append(
                "| \(key) | \(values.count) | \(percent(agree)) | \(percent(root)) "
                    + "| \(percent(quality)) | \(percent(median(values))) |")
        }
        if !pairRows.isEmpty {
            lines.append("")
            lines.append(
                "| pair | songs | agree % (wt) | root div % (wt) | qual div % (wt) "
                    + "| median agree % |")
            lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
            lines.append(contentsOf: pairRows)
        }

        var armOrder: [String] = []
        var qualityTotals: [String: [Double]] = [:]
        var armWeight: [String: Double] = [:]
        for result in results {
            for entry in result.qualities {
                if !armOrder.contains(entry.arm) { armOrder.append(entry.arm) }
                var running =
                    qualityTotals[entry.arm]
                    ?? [Double](repeating: 0, count: qualityOrder.count)
                for index in running.indices {
                    running[index] += entry.distribution[index] * result.duration
                }
                qualityTotals[entry.arm] = running
                armWeight[entry.arm, default: 0] += result.duration
            }
        }

        var qualityRows: [String] = []
        for arm in armOrder {
            let weight = armWeight[arm] ?? 0
            guard weight > 0, let totals = qualityTotals[arm] else { continue }
            let shares = totals.map { $0 / weight }
            let pairs = zip(qualityOrder, shares).map { "\($0.name)=\(percent($1))" }
            lines.append("arm=\(arm) quality_mix_pct \(pairs.joined(separator: " "))")
            qualityRows.append(
                "| \(arm) | " + shares.map { percent($0) }.joined(separator: " | ") + " |")
        }
        if !qualityRows.isEmpty {
            lines.append("")
            lines.append(
                "| arm | " + qualityOrder.map { $0.name }.joined(separator: " % | ") + " % |")
            lines.append(
                "| --- |" + String(repeating: " ---: |", count: qualityOrder.count))
            lines.append(contentsOf: qualityRows)
        }
        return lines
    }

    // MARK: - Ground-truth sequence metrics

    /// `<stemDirName>\t<stems dir>\t<mix path or empty>\t<chart .cho path>[\t<tier>]`, one per
    /// line. A short or blank row is dropped rather than failing the sweep; an empty third column
    /// simply means the song runs two arms instead of three.
    ///
    /// The 5th column is optional free text (`reviewed`, `automated`, ...). It only ever changes
    /// how a song is GROUPED in the report — an unrecognised, empty, or absent tier still runs the
    /// song, because excluding material based on a label would silently reshape the benchmark.
    static func parseGroundTruthManifest(_ text: String) -> [GroundTruthRow] {
        var rows: [GroundTruthRow] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, !fields[0].isEmpty, !fields[1].isEmpty, !fields[3].isEmpty
            else { continue }
            let tier = fields.count >= 5 && !fields[4].isEmpty ? fields[4] : nil
            rows.append(
                GroundTruthRow(
                    id: fields[0],
                    stemDirectory: URL(fileURLWithPath: fields[1]),
                    mix: fields[2].isEmpty ? nil : URL(fileURLWithPath: fields[2]),
                    chart: URL(fileURLWithPath: fields[3]),
                    tier: tier))
        }
        return rows
    }

    /// Reads a chart through the SHIPPING ChordPro parser, so the harness cannot quietly disagree
    /// with the app about what a chart says.
    static func loadGroundTruthChart(_ url: URL) throws -> GroundTruthChart {
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = try ChordProDocument(parsing: source)

        var capo = 0
        var writtenKey: String?
        var provenance = "-"
        var written: [ParsedChord] = []
        for element in document.elements {
            switch element {
            case .directive(let line):
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = directiveValue(trimmed, name: "capo"), let fret = Int(value) {
                    capo = fret
                }
                if let value = directiveValue(trimmed, name: "key") { writtenKey = value }
                if directiveValue(trimmed, name: "subtitle") != nil { provenance = trimmed }
            case .chord(let chord):
                // Rebuilt from the parsed parts rather than reusing `chord.description` for two
                // reasons: `ChordProNote` keeps the letter's original case, and the slash bass is
                // dropped here so it never reaches `parse` at all.
                // A no-chord marker is a rest, not a harmony — it contributes nothing to the
                // ground-truth chord sequence.
                guard let root = chord.root else { continue }
                let letter = String(root.letter).uppercased()
                let accidental = root.accidental?.rawValue ?? ""
                guard let parsed = parse(letter + accidental + chord.suffix) else { continue }
                written.append(parsed)
            case .text:
                continue
            }
        }

        // CAPO — the single most important correction in this file. These charts are written as
        // guitar SHAPES; a capo at fret N makes those shapes SOUND N semitones higher. The detector
        // analyses the recording and therefore reports CONCERT pitch, so every chart chord has to be
        // pushed up by the capo before the two are even in the same key. Sanity check: "Summertime's
        // here with you" is {key: G} {capo: 1} and its own comment reads "Concert key: Ab", and
        // G (7) + 1 = 8 = Ab.
        let tokens = collapse(
            written.map { SequenceToken(root: ($0.root + capo) % 12, quality: $0.quality) })
        return GroundTruthChart(
            capo: capo, writtenKey: writtenKey, provenance: provenance, tokens: tokens)
    }

    /// `{name: value}` → `value`, case-insensitive on the name. `nil` for any other directive.
    static func directiveValue(_ line: String, name: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return nil }
        text = String(text.dropFirst().dropLast())
        guard let colon = text.firstIndex(of: ":"),
            text[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name
        else { return nil }
        return String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Chord labels → comparable tokens. Applied to BOTH sides so neither the chart nor the detector
    /// gets a spelling or repetition advantage. Slash bass is already stripped by `parse`.
    static func sequenceTokens(_ labels: [String]) -> [SequenceToken] {
        collapse(labels.compactMap(parse).map { SequenceToken(root: $0.root, quality: $0.quality) })
    }

    /// Consecutive duplicates collapse to one. Charts restate the same chord on every line and the
    /// decoder re-emits it every bar, so without this the score would mostly measure repetition
    /// style rather than harmony.
    static func collapse<T: Equatable>(_ tokens: [T]) -> [T] {
        tokens.reduce(into: []) { result, token in
            if result.last != token { result.append(token) }
        }
    }

    /// Root-only view. Collapsed a second time because two distinct tokens can share a root
    /// (C then Cmaj7), and at root level that is one chord, not two.
    static func rootSequence(_ tokens: [SequenceToken]) -> [Int] {
        collapse(tokens.map(\.root))
    }

    /// Root+quality view over IN-VOCABULARY tokens only. An OOV suffix cannot be matched by anything
    /// the decoder is able to emit, so leaving it in the denominator would just re-bake the
    /// vocabulary ceiling into the score.
    ///
    /// ponytail: OOV tokens are dropped BEFORE the second collapse, so C - Csus4 - C reads as a
    /// single C rather than two. That treats an unrepresentable chord as a decoration on its
    /// neighbours, which is the charitable reading; the strict alternative would penalise the
    /// detector for correctly holding one chord through a passing sus.
    static func fullSequence(_ tokens: [SequenceToken]) -> [String] {
        collapse(tokens.compactMap { token in token.quality.map { "\(token.root):\($0)" } })
    }

    /// Plain O(n*m) DP over two rolling rows. Collapsed chord sequences run to a few hundred tokens,
    /// so the table is tiny and anything cleverer would only cost readability.
    static func longestCommonSubsequence<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = previous
        for left in 1...lhs.count {
            for right in 1...rhs.count {
                current[right] =
                    lhs[left - 1] == rhs[right - 1]
                    ? previous[right - 1] + 1
                    : max(previous[right], current[right - 1])
            }
            // Safe to swap rather than clear: every index from 1 is overwritten next pass, and
            // index 0 is always 0.
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// The chart's own `{key:}` pushed up by the capo, printed so the concert key can be eyeballed
    /// against the detector's estimate. Sharp spelling only — Ab prints as G# — and the mode is
    /// dropped, so `{key: Cm}` at capo 1 prints `C#`. This is a display line, not an input to any
    /// score, so neither is worth a spelling model.
    static func concertKeyName(written: String?, capo: Int) -> String {
        guard let written, let parsed = parse(written) else { return "-" }
        return pitchNames[(parsed.root + capo) % 12]
    }

    /// Manifest column wins; otherwise the chart's own `{subtitle:}` value, which is where chart
    /// trustworthiness was already being recorded. Never used to filter — only to group.
    static func resolveTier(manifest: String?, provenance: String) -> String {
        if let manifest, !manifest.isEmpty { return manifest }
        return directiveValue(provenance, name: "subtitle") ?? "unknown"
    }

    static func sequenceResult(
        id: String,
        chart: GroundTruthChart,
        report: Report,
        tier: String
    ) -> SequenceSongResult {
        let truthRoots = rootSequence(chart.tokens)
        let truthFull = fullSequence(chart.tokens)

        var arms: [SequenceArmResult] = []
        for arm in report.arms {
            let detected = sequenceTokens(arm.spans.map(\.label))
            let detectedRoots = rootSequence(detected)
            let detectedFull = fullSequence(detected)
            arms.append(
                SequenceArmResult(
                    arm: arm.name,
                    root: SequenceScore(
                        matched: longestCommonSubsequence(detectedRoots, truthRoots),
                        truthCount: truthRoots.count,
                        detectedCount: detectedRoots.count),
                    full: SequenceScore(
                        matched: longestCommonSubsequence(detectedFull, truthFull),
                        truthCount: truthFull.count,
                        detectedCount: detectedFull.count)))
        }

        return SequenceSongResult(
            id: id,
            provenance: chart.provenance,
            tier: tier,
            capo: chart.capo,
            writtenKey: chart.writtenKey ?? "-",
            concertKey: concertKeyName(written: chart.writtenKey, capo: chart.capo),
            truthRootLength: truthRoots.count,
            truthFullLength: truthFull.count,
            collapsedTruthLength: chart.tokens.count,
            oovCount: chart.tokens.filter { $0.quality == nil }.count,
            arms: arms)
    }

    // MARK: - Ground-truth sequence output

    static let sequenceBanner =
        "=== GROUND-TRUTH SEQUENCE ACCURACY — untimed charts, LCS over collapsed chord sequences "
        + "— NOT time-weighted ==="

    /// Printed with the banner because a reader who misses it will misread every number below: a
    /// capo chart and a detection are in different keys until this correction is applied.
    static let sequenceCapoNote =
        "note=chart_chords_transposed_to_concert_pitch_by_capo (written shapes sound {capo:N} "
        + "semitones higher; the detector hears the recording, so it is already concert)"

    /// Printed with the banner because `root_seq_acc_pct` is a RECALL number and always was —
    /// a reader who assumes it is an accuracy will over-read any arm that over-segments.
    static let sequenceScoringNote =
        "note=root_seq_acc_pct_and_full_seq_acc_pct_are_RECALL_only (unchanged for continuity); "
        + "headline metric is *_f1_pct; over_seg_ratio=det_roots/truth_roots, >1 means the arm "
        + "emitted more chords than the chart lists"

    /// Writes each song's block to disk and fsyncs before moving on. A previous 12-minute sweep
    /// buffered all of its stdout until process exit, so a crash near the end lost every result and
    /// there was no way to tell a slow run from a hung one.
    final class GroundTruthSink {
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

    static func renderSequenceSong(_ result: SequenceSongResult) -> [String] {
        var lines: [String] = []
        lines.append(
            "song=\(shortID(result.id)) status=ok capo=\(result.capo) "
                + "key_written=\(result.writtenKey) key_concert=\(result.concertKey) "
                + "truth_chords=\(result.collapsedTruthLength) "
                + "truth_roots=\(result.truthRootLength) truth_full=\(result.truthFullLength) "
                + "oov=\(result.oovCount) oov_pct=\(percent(result.oovFraction))")
        lines.append(
            "song=\(shortID(result.id)) tier=\(result.tier) provenance=\(result.provenance)")
        for arm in result.arms {
            // The legacy line is emitted byte-for-byte as it was, on its own, so a reader diffing
            // against the previous benchmark doc greps the same keys and gets the same numbers.
            // Redefining `root_seq_acc_pct` to mean F1 would have silently invalidated that doc.
            lines.append(
                "song=\(shortID(result.id)) arm=\(arm.arm) "
                    + "det_roots=\(arm.root.detectedCount) det_full=\(arm.full.detectedCount) "
                    + "root_seq_acc_pct=\(percent(arm.root.recall)) "
                    + "full_seq_acc_pct=\(percent(arm.full.recall))")
            lines.append(
                "song=\(shortID(result.id)) arm=\(arm.arm) "
                    + "root_f1_pct=\(percent(arm.root.f1)) "
                    + "root_precision_pct=\(percent(arm.root.precision)) "
                    + "root_recall_pct=\(percent(arm.root.recall)) "
                    + "full_f1_pct=\(percent(arm.full.f1)) "
                    + "full_precision_pct=\(percent(arm.full.precision)) "
                    + "full_recall_pct=\(percent(arm.full.recall)) "
                    + "over_seg_ratio=\(ratio(arm.root.overSegmentationRatio))")
        }
        return lines
    }

    static func renderSequenceAggregate(_ results: [SequenceSongResult]) -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("=== per-song sequence accuracy ===")
        lines.append("")
        // F1 leads each triple because it is the only one of the three that cannot be improved by
        // emitting more chords; precision and recall follow so the direction of the error is still
        // legible at a glance.
        lines.append(
            "| song | tier | capo | truth roots | truth full | oov % | arm | det roots "
                + "| det full | over seg | root f1 % | root prec % | root rec % | full f1 % "
                + "| full prec % | full rec % |")
        lines.append(
            "| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: "
                + "| ---: | ---: | ---: | ---: |")
        for result in results {
            for arm in result.arms {
                lines.append(
                    "| \(shortID(result.id)) | \(result.tier) | \(result.capo) "
                        + "| \(result.truthRootLength) | \(result.truthFullLength) "
                        + "| \(percent(result.oovFraction)) | \(arm.arm) "
                        + "| \(arm.root.detectedCount) | \(arm.full.detectedCount) "
                        + "| \(ratio(arm.root.overSegmentationRatio)) "
                        + "| \(percent(arm.root.f1)) | \(percent(arm.root.precision)) "
                        + "| \(percent(arm.root.recall)) | \(percent(arm.full.f1)) "
                        + "| \(percent(arm.full.precision)) | \(percent(arm.full.recall)) |")
            }
        }
        lines.append("")
        lines.append("=== chart provenance ===")
        lines.append("")
        lines.append("| song | tier | capo | key written | key concert | provenance |")
        lines.append("| --- | --- | ---: | --- | --- | --- |")
        for result in results {
            lines.append(
                "| \(shortID(result.id)) | \(result.tier) | \(result.capo) | \(result.writtenKey) "
                    + "| \(result.concertKey) | \(result.provenance) |")
        }
        lines.append(contentsOf: renderSequenceMeans(results))
        lines.append(contentsOf: renderSequenceTiers(results))
        return lines
    }

    /// One arm's per-song scores across the sweep. Every list holds one entry per song that
    /// actually produced that metric, so a chart with no in-vocabulary chords contributes fewer
    /// `full*` entries rather than a zero that would drag the mean down.
    struct ArmScoreBucket {
        var rootF1: [Double] = []
        var rootPrecision: [Double] = []
        var rootRecall: [Double] = []
        var fullF1: [Double] = []
        var fullPrecision: [Double] = []
        var fullRecall: [Double] = []
        var overSegmentation: [Double] = []
    }

    /// Arms in first-seen order plus their collected scores. Order is preserved rather than sorted
    /// so the aggregate rows line up with the per-song rows above them.
    static func armScoreBuckets(
        _ results: [SequenceSongResult]
    ) -> (order: [String], buckets: [String: ArmScoreBucket]) {
        var order: [String] = []
        var buckets: [String: ArmScoreBucket] = [:]
        for result in results {
            for arm in result.arms {
                if !order.contains(arm.arm) { order.append(arm.arm) }
                var bucket = buckets[arm.arm] ?? ArmScoreBucket()
                if let value = arm.root.f1 { bucket.rootF1.append(value) }
                if let value = arm.root.precision { bucket.rootPrecision.append(value) }
                if let value = arm.root.recall { bucket.rootRecall.append(value) }
                if let value = arm.full.f1 { bucket.fullF1.append(value) }
                if let value = arm.full.precision { bucket.fullPrecision.append(value) }
                if let value = arm.full.recall { bucket.fullRecall.append(value) }
                if let value = arm.root.overSegmentationRatio {
                    bucket.overSegmentation.append(value)
                }
                buckets[arm.arm] = bucket
            }
        }
        return (order, buckets)
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Plain unweighted mean, one vote per song. Duration weighting would be meaningless here: the
    /// charts carry no timing, so a "long" song is only a long chord LIST. The median sits beside
    /// the mean so one pathological chart cannot hide inside it.
    private static func renderSequenceMeans(_ results: [SequenceSongResult]) -> [String] {
        let (order, buckets) = armScoreBuckets(results)

        var lines: [String] = []
        lines.append("")
        lines.append("=== aggregate (unweighted mean across songs) ===")
        lines.append("songs=\(results.count)")
        var rows: [String] = []
        for arm in order {
            let bucket = buckets[arm] ?? ArmScoreBucket()
            let roots = bucket.rootRecall
            let fulls = bucket.fullRecall
            // Legacy line, unchanged: `mean_root_seq_acc_pct` still means mean RECALL. The F1
            // headline goes on its own line below rather than replacing this one.
            lines.append(
                "arm=\(arm) songs=\(roots.count) mean_root_seq_acc_pct=\(percent(mean(roots))) "
                    + "median_root_seq_acc_pct=\(percent(median(roots))) "
                    + "mean_full_seq_acc_pct=\(percent(mean(fulls))) "
                    + "median_full_seq_acc_pct=\(percent(median(fulls)))")
            lines.append(
                "arm=\(arm) songs=\(bucket.rootF1.count) "
                    + "mean_root_f1_pct=\(percent(mean(bucket.rootF1))) "
                    + "median_root_f1_pct=\(percent(median(bucket.rootF1))) "
                    + "mean_root_precision_pct=\(percent(mean(bucket.rootPrecision))) "
                    + "mean_root_recall_pct=\(percent(mean(bucket.rootRecall))) "
                    + "mean_full_f1_pct=\(percent(mean(bucket.fullF1))) "
                    + "median_full_f1_pct=\(percent(median(bucket.fullF1))) "
                    + "mean_full_precision_pct=\(percent(mean(bucket.fullPrecision))) "
                    + "mean_full_recall_pct=\(percent(mean(bucket.fullRecall))) "
                    + "mean_over_seg_ratio=\(ratio(mean(bucket.overSegmentation)))")
            rows.append(
                "| \(arm) | \(roots.count) | \(percent(mean(bucket.rootF1))) "
                    + "| \(percent(median(bucket.rootF1))) "
                    + "| \(percent(mean(bucket.rootPrecision))) "
                    + "| \(percent(mean(bucket.rootRecall))) "
                    + "| \(percent(mean(bucket.fullF1))) "
                    + "| \(percent(median(bucket.fullF1))) "
                    + "| \(percent(mean(bucket.fullPrecision))) "
                    + "| \(percent(mean(bucket.fullRecall))) "
                    + "| \(ratio(mean(bucket.overSegmentation))) |")
        }
        guard !rows.isEmpty else { return lines }
        lines.append("")
        lines.append(
            "| arm | songs | mean root f1 % | median root f1 % | mean root prec % "
                + "| mean root rec % | mean full f1 % | median full f1 % | mean full prec % "
                + "| mean full rec % | mean over seg |")
        lines.append(
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        lines.append(contentsOf: rows)
        return lines
    }

    /// Same F1 numbers, segmented by chart tier. Printed so a reviewed-only or automated-only view
    /// can be read straight off a completed sweep instead of costing another multi-minute run.
    private static func renderSequenceTiers(_ results: [SequenceSongResult]) -> [String] {
        var tierOrder: [String] = []
        var grouped: [String: [SequenceSongResult]] = [:]
        for result in results {
            if !tierOrder.contains(result.tier) { tierOrder.append(result.tier) }
            grouped[result.tier, default: []].append(result)
        }

        var lines: [String] = []
        lines.append("")
        lines.append("=== aggregate by chart tier (unweighted mean F1) ===")
        lines.append("tiers=\(tierOrder.count)")
        var rows: [String] = []
        for tier in tierOrder {
            let songs = grouped[tier] ?? []
            let (order, buckets) = armScoreBuckets(songs)
            for arm in order {
                let bucket = buckets[arm] ?? ArmScoreBucket()
                lines.append(
                    "tier=\(tier) arm=\(arm) songs=\(songs.count) "
                        + "mean_root_f1_pct=\(percent(mean(bucket.rootF1))) "
                        + "mean_full_f1_pct=\(percent(mean(bucket.fullF1))) "
                        + "mean_over_seg_ratio=\(ratio(mean(bucket.overSegmentation)))")
                rows.append(
                    "| \(tier) | \(arm) | \(songs.count) | \(percent(mean(bucket.rootF1))) "
                        + "| \(percent(mean(bucket.fullF1))) "
                        + "| \(ratio(mean(bucket.overSegmentation))) |")
            }
        }
        guard !rows.isEmpty else { return lines }
        lines.append("")
        lines.append("| tier | arm | songs | mean root f1 % | mean full f1 % | mean over seg |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: |")
        lines.append(contentsOf: rows)
        return lines
    }

    // MARK: - Synthetic multitrack

    struct SyntheticSong {
        let guitar: URL
        let accompaniment: URL
        let mix: URL
        let bass: URL
        let drums: URL
        let groundTruth: [(time: TimeInterval, label: String)]
    }

    private static let sampleRate = 44_100.0
    private static let bpm = 100.0
    private static let beatsPerBar = 4
    private static let barCount = 8

    /// One bar per entry, the 4-bar C-F-G-C cycle played twice: ~19.2 s at 100 BPM.
    private static let progression: [(label: String, triad: [Double], root: Double)] = [
        ("C", [261.63, 329.63, 392.00], 65.41),
        ("F", [349.23, 440.00, 523.25], 87.31),
        ("G", [392.00, 493.88, 587.33], 98.00),
        ("C", [261.63, 329.63, 392.00], 65.41),
    ]

    static func writeSyntheticSong(into directory: URL) throws -> SyntheticSong {
        let beat = 60.0 / bpm
        let barLength = beat * Double(beatsPerBar)
        let totalFrames = Int(barLength * Double(barCount) * sampleRate)
        var noise = DeterministicNoise(seed: 0x5EED_1234)

        var guitar = [Float](repeating: 0, count: totalFrames)
        var extras = [Float](repeating: 0, count: totalFrames)
        var bass = [Float](repeating: 0, count: totalFrames)
        var drums = [Float](repeating: 0, count: totalFrames)
        var groundTruth: [(time: TimeInterval, label: String)] = []

        for bar in 0..<barCount {
            let chord = progression[bar % progression.count]
            groundTruth.append((time: Double(bar) * barLength, label: chord.label))
            for beatIndex in 0..<beatsPerBar {
                let start = Double(bar * beatsPerBar + beatIndex) * beat
                let firstFrame = Int(start * sampleRate)
                let lastFrame = min(totalFrames, firstFrame + Int(beat * sampleRate))
                guard firstFrame < lastFrame else { continue }
                for frame in firstFrame..<lastFrame {
                    let elapsed = Double(frame - firstFrame) / sampleRate
                    // Re-attack every beat so the tempo tracker and onset detector have something
                    // to lock onto; a sustained pad would give both arms a flat envelope.
                    let envelope = Float(exp(-2.5 * elapsed) * min(1, elapsed / 0.005))
                    let phase = Double(frame) / sampleRate
                    for frequency in chord.triad {
                        guitar[frame] += 0.18 * envelope * Float(sin(2 * .pi * frequency * phase))
                        extras[frame] +=
                            0.05 * envelope * Float(sin(4 * .pi * frequency * phase))
                    }
                    bass[frame] += 0.5 * envelope * Float(sin(2 * .pi * chord.root * phase))
                    // 60 ms decaying noise burst per beat.
                    if elapsed < 0.06 {
                        drums[frame] = Float(exp(-40 * elapsed)) * noise.next() * 0.6
                    }
                    extras[frame] += noise.next() * 0.01
                }
            }
        }

        let accompaniment: [Float] = zip(guitar, extras).map { $0 + $1 }
        var mix = [Float](repeating: 0, count: totalFrames)
        for index in 0..<totalFrames {
            let harmony: Float = guitar[index] * 0.5
            let low: Float = bass[index] * 0.4
            let percussion: Float = drums[index] * 0.3
            mix[index] = harmony + low + percussion
        }

        let song = SyntheticSong(
            guitar: directory.appendingPathComponent("guitar.wav"),
            accompaniment: directory.appendingPathComponent("accompaniment.wav"),
            mix: directory.appendingPathComponent("mix.wav"),
            bass: directory.appendingPathComponent("bass.wav"),
            drums: directory.appendingPathComponent("drums.wav"),
            groundTruth: groundTruth
        )
        try writeStereoWAV(guitar, to: song.guitar)
        try writeStereoWAV(accompaniment, to: song.accompaniment)
        try writeStereoWAV(mix, to: song.mix)
        try writeStereoWAV(bass, to: song.bass)
        try writeStereoWAV(drums, to: song.drums)
        return song
    }

    /// Reproducible white noise — a seeded LCG keeps the synthetic arms byte-identical run to run,
    /// so a change in the numbers always means a change in the pipeline.
    struct DeterministicNoise {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return Float(unit * 2 - 1)
        }
    }

    static func writeStereoWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            let target = buffer.floatChannelData![channel]
            for frame in samples.indices { target[frame] = samples[frame] }
        }
        try file.write(from: buffer)
    }

    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }
}
