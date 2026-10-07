import Accelerate
import Foundation

/// Chooses the ONE player chord detection listens to, and the leakage gate that decides whether a
/// stem holds a part at all.
///
/// The chord line is the guitarist's chords (Eric, 2026-09-27), in guitar's color; a song with no
/// guitar part falls back to the instrument that does play, in that instrument's color. This used
/// to blend guitar and piano into one signal, which produced chords neither player played.
///
/// **Gate leakage first.** Separation models routinely bleed a few dB of guitar into `piano` on
/// tracks with no piano at all (and the reverse). A stem more than `leakageFloorDecibels` below the
/// loudest candidate is bleed, not a part, so it can never be chosen as the player.
enum HarmonyStemMix {
    /// Priority order for chord detection: guitar first, then piano. Only the order and `weight > 0`
    /// matter now — chords come from one player, not a weighted blend.
    ///
    /// **Bass defaults to 0 deliberately.** Bass tells you the root the *band* is on, which is
    /// frequently not what the guitarist is fretting — inversions, pedal points, and walking lines
    /// under a held chord all move the bass without any chord change. Folding it into the chroma
    /// manufactures those as root changes, and `ChordClassifier.rootWeight` (1.6) already biases
    /// classification toward root energy, so bass evidence would be counted twice. Nor does the
    /// bass arbitrate the chord line afterwards (Eric, 2026-10-07: only the guitar stem): it has
    /// its own Bass Notes row, and `BassChordReconciler` only rounds bass notes to the chords.
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

    /// The one player chord detection listens to: the highest-priority contributor (levels are in
    /// priority order) that survives the leakage gate. nil when none is audible.
    static func leadIndex(_ levels: [Float]) -> Int? {
        keptAfterLeakageGate(levels).min()
    }

    /// Indices of the contributors that survive the leakage gate, given each one's RMS in the
    /// same order. Split out from `mixed` so a caller that streams stems one at a time (to keep
    /// only one resident) can apply exactly the same rule.
    static func keptAfterLeakageGate(_ levels: [Float]) -> Set<Int> {
        guard let loudest = levels.max(), loudest > 0 else { return [] }
        let floor = loudest * pow(10, leakageFloorDecibels / 20)
        return Set(levels.indices.filter { levels[$0] >= floor && levels[$0] > 0 })
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
    // instrument-chords-2: a stem's resting frames carry no chord evidence (`SoundingFrameGate`).
    // instrument-chords-3: records `rests`, the stretches where guitar and piano are not playing.
    // instrument-chords-4: drops chart chords no player's track has (CHORD-007).
    static let currentVersionTag = "instrument-chords-4"

    var versionTag: String
    var gridKey: BucketGridKey
    var tracks: [InstrumentChordTrack]
    /// Stretches of at least `PlayerRests.minimumSeconds` where guitar + piano together are not
    /// sounding. The chord timeline stores CHANGES only, so without these nothing says "stop":
    /// the chart restated a held chord across an a cappella passage and could not end a chord's
    /// hold line. Optional so timelines stored before it still decode.
    var rests: [ClosedRange<TimeInterval>]?

    init(
        gridKey: BucketGridKey, tracks: [InstrumentChordTrack],
        rests: [ClosedRange<TimeInterval>] = []
    ) {
        self.versionTag = Self.currentVersionTag
        self.gridKey = gridKey
        self.tracks = tracks
        self.rests = rests
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
    static func stemAudio(for document: SongAnalysisDocument, gated: Bool = true)
        -> [(id: StemID, url: URL)]
    {
        BucketNotePass.stemAudio(for: document, gated: gated).filter { entry in
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
        return InstrumentChordTimeline(
            gridKey: key, tracks: found,
            rests: PlayerRests.intervals(stems: loaded.map { ($0.samples, $0.sampleRate) }))
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
        // One instrument's track: no chords where THAT instrument rests.
        let frames = try ChordAnalysisPipeline(configuration: configuration).analyzeFrames(
            samples: samples, gatesRestingFrames: true)
        let changePoints = ChromaChangePointDetector.changePoints(frames: frames.chroma)
        let analysis = SongAudioAnalysis(
            beat: nil, chords: frames.observations, estimatedKey: document.estimatedKey,
            harmonicChangePoints: changePoints)
        // This stem's own attacks only; no bass (see the harmony stage's chord line).
        let onsets = InstrumentOnsetDetector.onsets(samples: samples, sampleRate: sampleRate)
        let beatLength = MetricalLevelReconciler.medianBeatLength(beatTimes: beats, bpm: bpm) ?? 0
        let subdivision = HarmonyDecodeResolution.subdivision(beatLength: beatLength)
        let decodeBeats = ChordTimelineDecoder.subdivided(
            ChordTimelineDecoder.extendedBackward(
                beats, toCover: frames.observations.first?.timestamp ?? 0),
            by: subdivision)
        let meter: ChordTimelineDecoder.BarMeter? = document.barGrid.flatMap { grid in
            grid.isMeasured
                ? ChordTimelineDecoder.BarMeter(
                    beatsPerBar: grid.beatsPerBar * subdivision,
                    barPhase: grid.barPhase * subdivision)
                : nil
        }
        var decoder = ChordTimelineDecoder()
        decoder.switchPenalty *= Float(subdivision)
        var events = decoder.events(
            from: analysis, key: document.estimatedKey, instrumentOnsets: onsets,
            beatTimes: decodeBeats, meter: meter)
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
            let beat =
                MetricalLevelReconciler.medianBeatLength(
                    beatTimes: document.beatTimes, bpm: document.estimatedBPM ?? 0) ?? 0
            document.chords = playedChords(
                document.chords, tracks: fresh.tracks, rests: fresh.rests ?? [], beatLength: beat)
        }
    }

    /// CHORD-007: the chart keeps a chord only when a player's own track has it within a beat —
    /// the two decodes can place one change up to a beat apart, and that is still the player's
    /// chord. A chord neither the guitar track nor the piano track has is nobody's part: omitted,
    /// even if the harmony is right. The user's own decisions (accepted, moved) are never dropped.
    /// Dropping the B of A-B-A leaves the second A restating a chord still held, so it goes too,
    /// unless the player rested in between and is striking it again.
    static func playedChords(
        _ chords: [EditableChordEvent], tracks: [InstrumentChordTrack],
        rests: [ClosedRange<TimeInterval>], beatLength: TimeInterval
    ) -> [EditableChordEvent] {
        guard !tracks.isEmpty else { return chords }
        var kept: [EditableChordEvent] = []
        for chord in chords {
            let isUsers = chord.accepted || chord.manualTime != nil || chord.hidden
            let played = !InstrumentChordAgreement.agreeingStems(
                forChord: chord.chord, at: chord.time, tracks: tracks, within: beatLength
            ).isEmpty
            guard isUsers || played else { continue }
            if !isUsers, let last = kept.last(where: { !$0.hidden }), last.chord == chord.chord,
                !PlayerRests.interrupts(rests, chordTime: last.time, at: chord.time)
            {
                continue
            }
            kept.append(chord)
        }
        return kept
    }
}

/// Which instrument a chart chord belongs to, from the per-instrument tracks.
/// When the guitarist and the pianist are NOT playing: runs where the guitar + piano sum stays more
/// than `SoundingFrameGate.floorDecibels` below its loud level.
enum PlayerRests {
    static let hopSeconds = 0.1
    /// Shorter dips are the space between strums, not a rest.
    static let minimumSeconds = 1.0

    static func intervals(stems: [(samples: [Float], sampleRate: Double)])
        -> [ClosedRange<TimeInterval>]
    {
        guard let sampleRate = stems.first?.sampleRate, sampleRate > 0 else { return [] }
        var sum: [Float] = []
        for stem in stems where stem.sampleRate == sampleRate {
            if sum.isEmpty {
                sum = stem.samples
            } else {
                let length = min(sum.count, stem.samples.count)
                vDSP_vadd(sum, 1, stem.samples, 1, &sum, 1, vDSP_Length(length))
            }
        }
        let hop = max(1, Int(hopSeconds * sampleRate))
        let levels = stride(from: 0, to: sum.count, by: hop).map {
            SoundingFrameGate.level(of: sum, from: $0, count: hop)
        }
        return intervals(levels: levels)
    }

    static func intervals(levels: [Float]) -> [ClosedRange<TimeInterval>] {
        let sounding = SoundingFrameGate.sounding(frameLevels: levels)
        var rests: [ClosedRange<TimeInterval>] = []
        var runStart: Int?
        for index in 0...sounding.count {
            let resting = index < sounding.count && !sounding[index]
            if resting {
                runStart = runStart ?? index
            } else if let start = runStart {
                let from = Double(start) * hopSeconds
                let to = Double(index) * hopSeconds
                if to - from >= minimumSeconds { rests.append(from...to) }
                runStart = nil
            }
        }
        return rests
    }

    /// True when the player is not holding a chord struck at `chordTime` any more at `time`:
    /// `time` is inside a rest, or a rest began after the chord and before `time`.
    static func interrupts(
        _ rests: [ClosedRange<TimeInterval>], chordTime: TimeInterval, at time: TimeInterval
    ) -> Bool {
        rests.contains { $0.lowerBound > chordTime && $0.lowerBound <= time || $0.contains(time) }
    }

    /// Where a chord struck at `chordTime` stops being held: the first rest that begins after it.
    static func end(of chordTime: TimeInterval, rests: [ClosedRange<TimeInterval>])
        -> TimeInterval?
    {
        rests.map(\.lowerBound).filter { $0 > chordTime }.min()
    }
}

enum InstrumentChordAgreement {
    /// The chord `track` has sounding at `time`: its latest visible change at or before
    /// `time + grace`, so a change landing just after the chart chord's onset still counts.
    static func sounding(
        in track: InstrumentChordTrack, at time: TimeInterval, grace: TimeInterval = 0.25
    ) -> EditableChordEvent? {
        track.chords.last { !$0.hidden && $0.time <= time + grace }
    }

    /// Every stem whose own chord track has `chord` sounding at `time`. Empty means no player
    /// can be credited with the chord — which must not LOOK like a credit: the label used to fall
    /// back to the accent tint, the same blue as the bass lane, and read as "the bass plays Am"
    /// on a passage with no bass (Eric, 2026-09-20).
    /// `within` widens the match to a beat either side: the chart line and a player's track are
    /// separate decodes and can place the same change up to a beat apart.
    static func agreeingStems(
        forChord chord: String, at time: TimeInterval, tracks: [InstrumentChordTrack],
        within tolerance: TimeInterval = 0
    ) -> [StemID] {
        let times = tolerance > 0 ? [time, time - tolerance, time + tolerance] : [time]
        return tracks.filter { track in
            times.contains { sounding(in: track, at: $0)?.chord == chord }
        }.map(\.stemID)
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
