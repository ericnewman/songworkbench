import Foundation

/// Builds the single mono signal that chord detection listens to, by weighting several isolated
/// stems together instead of picking one.
///
/// Before this existed, `HarmonyAudioSourceSelector` returned the FIRST available stem — with a
/// six-stem separation that is always `guitar`, so the piano stem was never consulted at all. On a
/// piano-led song the chroma came from a nearly-empty guitar stem.
///
/// Two rules make the weighting mean what it says:
///
/// **Normalize, then weight.** Each stem is scaled to unit RMS before its weight is applied, so a
/// weight is a statement about *priority*, not about how loud that instrument happened to be
/// mixed. Weighting raw stems would make a quiet-but-real piano part negligible no matter what
/// weight it was given.
///
/// **Gate leakage first.** Separation models routinely bleed a few dB of guitar into `piano` on
/// tracks with no piano at all. Normalizing such a stem would amplify pure bleed to full level and
/// double-count the guitar — so any stem more than `leakageFloorDecibels` below the loudest
/// contributor is dropped before normalization. The gate and the normalization only make sense
/// together; neither is safe alone.
enum HarmonyStemMix {
    /// Priority order for chord detection. Guitar leads, piano supports.
    ///
    /// **Bass defaults to 0 deliberately.** Bass tells you the root the *band* is on, which is
    /// frequently not what the guitarist is fretting — inversions, pedal points, and walking lines
    /// under a held chord all move the bass without any chord change. Folding it into the chroma
    /// manufactures those as root changes, and `ChordClassifier.rootWeight` (1.6) already biases
    /// classification toward root energy, so bass evidence would be counted twice. The bass stem
    /// is already used where it belongs: `BassInformedChordRefiner` and `BassChordReconciler`
    /// arbitrate the root AFTER a triad has been chosen, which is the sound way to use it.
    ///
    /// ponytail: this is one constant, not a setting. Raise `bass` above 0 to include it and
    /// measure the result against the ground-truth corpus before keeping the change.
    static let defaultWeights: [(kind: StemKind, weight: Float)] = [
        (.guitar, 1.0),
        (.piano, 0.6),
        (.bass, 0.0),
    ]

    /// A contributor more than this far below the loudest one is treated as bleed and dropped.
    /// Matches the 25 dB separation-artifact tell: a phantom stem sits far below the real one and
    /// its content is a subset of it.
    static let leakageFloorDecibels: Float = -25

    struct Contributor: Equatable, Sendable {
        /// Stable name for this contributor — a `StemKind.rawValue` in the pipeline. A plain
        /// label rather than a `StemKind` so the mixer stays usable for anything that can produce
        /// mono samples, and so the fallback source (which is not a stem at all) needs no
        /// optional case.
        let label: String
        let weight: Float
        let samples: [Float]
    }

    struct Mix: Equatable, Sendable {
        let samples: [Float]
        /// Stems that actually reached the mix, in weight order. Never empty when `samples` is
        /// non-empty.
        let included: [String]
        /// Stems dropped as leakage (below the floor relative to the loudest contributor).
        let excludedAsLeakage: [String]

        /// Stable description of what this mix contains, for the harmony cache key. Two runs that
        /// mix the same stems at the same weights must produce the same string; changing the
        /// weights must change it, so the cached chord analysis is not reused across a
        /// weighting change.
        var configurationIdentifier: String {
            guard !included.isEmpty else { return "harmony-empty-mix" }
            let parts = included.joined(separator: "+")
            return "harmony-mix-\(parts)"
        }
    }

    /// Weighted mono mix of `contributors`. Pure, deterministic, no I/O.
    ///
    /// Zero-weight, empty, and silent contributors are ignored. Output length is the shortest
    /// included contributor's (stems from one separation are the same length; truncating is only a
    /// defensive measure). Returns an empty mix when nothing survives.
    static func mixed(_ contributors: [Contributor]) -> Mix {
        let usable = contributors.filter { $0.weight > 0 && !$0.samples.isEmpty }
        guard !usable.isEmpty else {
            return Mix(samples: [], included: [], excludedAsLeakage: [])
        }

        let levels = usable.map { (contributor: $0, rms: rootMeanSquare($0.samples)) }
        guard let loudest = levels.map(\.rms).max(), loudest > 0 else {
            return Mix(samples: [], included: [], excludedAsLeakage: [])
        }
        let floor = loudest * pow(10, leakageFloorDecibels / 20)

        var kept: [(contributor: Contributor, rms: Float)] = []
        var leaked: [String] = []
        for level in levels {
            if level.rms >= floor, level.rms > 0 {
                kept.append(level)
            } else {
                leaked.append(level.contributor.label)
            }
        }
        guard !kept.isEmpty else {
            return Mix(samples: [], included: [], excludedAsLeakage: leaked)
        }

        let length = kept.map(\.contributor.samples.count).min() ?? 0
        guard length > 0 else {
            return Mix(samples: [], included: [], excludedAsLeakage: leaked)
        }

        var mix = [Float](repeating: 0, count: length)
        for entry in kept {
            // Unit-RMS normalization, so `weight` expresses priority rather than mix level.
            let scale = entry.contributor.weight / entry.rms
            let samples = entry.contributor.samples
            for i in 0..<length {
                mix[i] += samples[i] * scale
            }
        }

        // Absolute level is irrelevant to chroma (per-frame vectors are normalized), but keep the
        // signal inside [-1, 1] so anything else reading these samples sees an ordinary waveform.
        //
        // Scanned in place: `mix.map(abs).max()` allocated a SECOND full-length Float array just
        // to find one number — ~60 MB on a six-minute stem, at the point where the loaded stems
        // are still resident and memory is already at its peak.
        var peak: Float = 0
        for sample in mix { peak = max(peak, abs(sample)) }
        if peak > 1 {
            for i in mix.indices { mix[i] /= peak }
        }

        return Mix(
            samples: mix,
            included: kept.map(\.contributor.label),
            excludedAsLeakage: leaked
        )
    }

    /// Indices of the contributors that survive the leakage gate, given each one's RMS in the
    /// same order. Split out from `mixed` so a caller that streams stems one at a time (to keep
    /// only one resident) can apply exactly the same rule.
    static func keptAfterLeakageGate(_ levels: [Float]) -> Set<Int> {
        guard let loudest = levels.max(), loudest > 0 else { return [] }
        let floor = loudest * pow(10, leakageFloorDecibels / 20)
        return Set(levels.indices.filter { levels[$0] >= floor && levels[$0] > 0 })
    }

    /// Wraps an already-accumulated mix, scaling it into [-1, 1]. The streaming counterpart to
    /// the tail of `mixed`.
    static func normalizedToUnitPeak(_ samples: [Float], included: [String]) -> Mix {
        guard !samples.isEmpty else {
            return Mix(samples: [], included: [], excludedAsLeakage: [])
        }
        var scaled = samples
        var peak: Float = 0
        for sample in scaled { peak = max(peak, abs(sample)) }
        if peak > 1 {
            for i in scaled.indices { scaled[i] /= peak }
        }
        return Mix(samples: scaled, included: included, excludedAsLeakage: [])
    }

    static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Chords detected on ONE instrument stem on its own (Eric, 2026-09-14: on a piano-led song the
/// chord names still came from guitar). `HarmonyStemMix` blends guitar and piano into one signal,
/// so no detected chord knows its instrument; this track listens to a single chordal stem.
struct InstrumentChordTrack: Codable, Equatable, Sendable {
    var stemID: StemID
    /// Sorted by time.
    var chords: [EditableChordEvent]
}

/// Every chordal instrument's own chords, cut on the song's grid. Same staleness contract as
/// `BucketNoteTimeline`: check `isCurrent(for:)` against the current grid key before showing it.
struct InstrumentChordTimeline: Codable, Equatable, Sendable {
    /// Bump when detection changes so stored timelines recompute.
    static let currentVersionTag = "instrument-chords-1"

    var versionTag: String
    var gridKey: BucketGridKey
    var tracks: [InstrumentChordTrack]

    init(gridKey: BucketGridKey, tracks: [InstrumentChordTrack]) {
        self.versionTag = Self.currentVersionTag
        self.gridKey = gridKey
        self.tracks = tracks
    }

    /// True when this timeline was detected on `key` by the current detector.
    func isCurrent(for key: BucketGridKey?) -> Bool {
        guard let key else { return false }
        return versionTag == Self.currentVersionTag && gridKey.matches(key)
    }
}

/// Detects `InstrumentChordTimeline`: the harmony stage's chord chain — frame chroma, the key- and
/// bass-aware Viterbi on the song's OWN beat grid (no second beat tracking), bass refinement,
/// snapping to THIS stem's attacks, the duration filter and both evidence audits — run on each
/// chordal stem alone. A stem more than `HarmonyStemMix.leakageFloorDecibels` below the loudest is
/// skipped as bleed. Best-effort like `BucketNotePass`: an unreadable stem is simply absent. The
/// repeated-chorus vote is left out on purpose: a track should say what that instrument played.
enum InstrumentChordPass {
    /// The chordal instruments that get their own chord line.
    static let instruments: [StemKind] = [.guitar, .piano]

    /// The guitar and piano stems (a refined child stands in for its parent).
    static func stemAudio(for document: SongAnalysisDocument) -> [(id: StemID, url: URL)] {
        BucketNotePass.stemAudio(for: document).filter { entry in
            instruments.contains { kind in
                entry.id == StemID(kind) || entry.id.rawValue.hasPrefix(kind.rawValue + ".")
            }
        }
    }

    static func timeline(for document: SongAnalysisDocument) -> InstrumentChordTimeline? {
        guard let key = BucketNotePass.gridKey(for: document) else { return nil }
        let loaded = stemAudio(for: document).compactMap {
            entry -> (id: StemID, samples: [Float], sampleRate: Double)? in
            guard let audio = try? MonoAudioFile.samples(url: entry.url), !audio.samples.isEmpty
            else { return nil }
            return (entry.id, audio.samples, audio.sampleRate)
        }
        let found = tracks(for: loaded, document: document)
        guard !found.isEmpty else { return nil }
        return InstrumentChordTimeline(gridKey: key, tracks: found)
    }

    /// One track per stem that clears the leakage gate and yields chords.
    static func tracks(
        for stems: [(id: StemID, samples: [Float], sampleRate: Double)],
        document: SongAnalysisDocument
    ) -> [InstrumentChordTrack] {
        let kept = HarmonyStemMix.keptAfterLeakageGate(
            stems.map { HarmonyStemMix.rootMeanSquare($0.samples) })
        return stems.indices.filter { kept.contains($0) }.compactMap { index in
            let stem = stems[index]
            guard
                let found = try? chords(
                    samples: stem.samples, sampleRate: stem.sampleRate, document: document),
                !found.isEmpty
            else { return nil }
            return InstrumentChordTrack(stemID: stem.id, chords: found)
        }
    }

    /// The harmony stage's chord chain on one stem's samples.
    static func chords(
        samples: [Float], sampleRate: Double, document: SongAnalysisDocument
    ) throws -> [EditableChordEvent] {
        let beats = document.beatTimes
        guard beats.count >= 2, let bpm = document.estimatedBPM, bpm > 0 else { return [] }
        let configuration = try AudioAnalysisConfiguration(
            sampleRate: sampleRate, frameLength: 8_192, hopLength: 4_096)
        let frames = try ChordAnalysisPipeline(configuration: configuration).analyzeFrames(
            samples: samples)
        let changePoints = ChromaChangePointDetector.changePoints(frames: frames.chroma)
        let analysis = SongAudioAnalysis(
            beat: nil, chords: frames.observations, estimatedKey: document.estimatedKey,
            harmonicChangePoints: changePoints)
        let onsets = InstrumentOnsetDetector.onsets(samples: samples, sampleRate: sampleRate)
        let bassCues = document.bassNotes.filter { $0.confidence >= 0.5 }.map(\.timestamp)
        let beatLength = MetricalLevelReconciler.medianBeatLength(beatTimes: beats, bpm: bpm) ?? 0
        let subdivision = HarmonyDecodeResolution.subdivision(beatLength: beatLength)
        let decodeBeats = ChordTimelineDecoder.subdivided(
            ChordTimelineDecoder.extendedBackward(
                beats, toCover: frames.observations.first?.timestamp ?? 0),
            by: subdivision)
        let meter: ChordTimelineDecoder.BarMeter? = document.barGrid.flatMap { grid in
            grid.phaseSource == .drumAccents
                ? ChordTimelineDecoder.BarMeter(
                    beatsPerBar: grid.beatsPerBar * subdivision,
                    barPhase: grid.barPhase * subdivision)
                : nil
        }
        var decoder = ChordTimelineDecoder()
        decoder.switchPenalty *= Float(subdivision)
        var events = BassInformedChordRefiner().refine(
            decoder.events(
                from: analysis, key: document.estimatedKey, bassNotes: document.bassNotes,
                instrumentOnsets: onsets + bassCues, beatTimes: decodeBeats, meter: meter),
            bassNotes: document.bassNotes)
        if !onsets.isEmpty {
            events = ChordOnsetAligner.snap(events, toOnsets: onsets, beatTimes: beats)
        }
        events = ChordEventDurationFilter.merge(
            events, beatTimes: beats, sourceDuration: document.sourceDuration)
        events =
            ChordEvidenceAudit.filtered(
                events: events, frameObservations: frames.observations, attackOnsets: onsets,
                changePoints: changePoints, sourceDuration: document.sourceDuration,
                minimumAttackOnlyDuration: beatLength
            ).events
        events =
            ChordQualityAudit.corrected(
                events: events, frameObservations: frames.observations,
                sourceDuration: document.sourceDuration
            ).events
        return events.sorted { $0.time < $1.time }
    }

    /// Recomputes when the stored timeline is missing or stale for the current grid — or always
    /// with `force`, which a fresh harmony run passes since the stems themselves may be new.
    static func apply(to document: inout SongAnalysisDocument, force: Bool = false) {
        if !force, let existing = document.instrumentChords,
            existing.isCurrent(for: BucketNotePass.gridKey(for: document))
        {
            return
        }
        if let fresh = timeline(for: document) {
            document.instrumentChords = fresh
        }
    }
}

/// Which instrument a chart chord belongs to, from the per-instrument tracks.
enum InstrumentChordAgreement {
    /// The chord `track` has sounding at `time`: its latest visible change at or before
    /// `time + grace`, so a change landing just after the chart chord's onset still counts.
    static func sounding(
        in track: InstrumentChordTrack, at time: TimeInterval, grace: TimeInterval = 0.25
    ) -> EditableChordEvent? {
        track.chords.last { !$0.hidden && $0.time <= time + grace }
    }

    /// The instrument whose sounding chord matches `chord` at `time`, or nil when no instrument or
    /// more than one does — a chord both instruments play belongs to neither. Refined children of
    /// one instrument (lead and rhythm guitar) count as that one instrument.
    static func instrument(
        forChord chord: String, at time: TimeInterval, tracks: [InstrumentChordTrack]
    ) -> StemID? {
        let agreeing = tracks.filter { sounding(in: $0, at: time)?.chord == chord }.map(\.stemID)
        let kinds = Set(agreeing.map { $0.rawValue.split(separator: ".").first.map(String.init) })
        return kinds.count == 1 ? agreeing.first : nil
    }
}

/// Rows for the Review chart: each instrument's chord line, in the same shape as a bucket-note row
/// so it draws and stacks with them (Eric, 2026-09-14: chord lines "tied to the bucket notes").
enum InstrumentChordRowFormatter {
    /// The stem's bucket-row tag plus "C" ("GtC", "PnC"), so a chord line reads apart from the
    /// same instrument's bucket-note line.
    static func label(for stemID: StemID) -> String {
        BucketNoteRowFormatter.label(for: stemID) + "C"
    }

    /// One row per shown track with a chord to name in `window`. A chord still sounding from
    /// before the window opens the row, dimmed, so every line says what that instrument plays.
    static func rows(
        timeline: InstrumentChordTimeline, hiddenStems: Set<StemID> = [],
        inWindow window: ClosedRange<TimeInterval>, transposedBy semitones: Int = 0
    ) -> [BucketNoteRow] {
        timeline.tracks
            .filter { !hiddenStems.contains($0.stemID) }
            .sorted {
                BucketNoteRowFormatter.displayOrder($0.stemID)
                    < BucketNoteRowFormatter.displayOrder($1.stemID)
            }
            .compactMap { track in
                let chords = track.chords.filter { !$0.hidden }
                var cells = chords.filter { window.contains($0.time) }.map {
                    BucketNoteRowCell(
                        time: $0.time, text: transposedName($0.chord, by: semitones), isDim: false)
                }
                if cells.first.map({ $0.time > window.lowerBound + 0.05 }) ?? true,
                    let carried = chords.last(where: { $0.time < window.lowerBound })
                {
                    cells.insert(
                        BucketNoteRowCell(
                            time: window.lowerBound,
                            text: transposedName(carried.chord, by: semitones), isDim: true),
                        at: 0)
                }
                return cells.isEmpty
                    ? nil
                    : BucketNoteRow(
                        stemID: track.stemID, label: label(for: track.stemID), cells: cells)
            }
    }

    /// `noteRows` with each chord row right after its instrument's note row; a chord row whose
    /// instrument has no note row follows the rest.
    static func interleaved(noteRows: [BucketNoteRow], chordRows: [BucketNoteRow])
        -> [BucketNoteRow]
    {
        var rows = noteRows
        for chordRow in chordRows {
            if let index = rows.lastIndex(where: { $0.stemID == chordRow.stemID }) {
                rows.insert(chordRow, at: index + 1)
            } else {
                rows.append(chordRow)
            }
        }
        return rows
    }

    /// `chord` moved by `semitones`, spelled the way the chart transposes its own chords.
    static func transposedName(_ chord: String, by semitones: Int) -> String {
        guard semitones % 12 != 0,
            let document = try? ChordProDocument(parsing: "[\(chord)]").transposed(by: semitones)
        else { return chord }
        for element in document.elements {
            if case .chord(let transposed) = element { return transposed.description }
        }
        return chord
    }
}
