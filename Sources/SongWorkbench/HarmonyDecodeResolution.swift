import Foundation

/// How finely the chord decoder slices time.
///
/// `ChordTimelineDecoder` emits at most one chord per window, so window length is a hard floor on
/// the shortest chord the pipeline can express. At `subdivision = 1` that floor is one beat: a
/// change on the "and" of a beat has nowhere to live, and no downstream filter can recover it
/// because it was never produced.
enum HarmonyDecodeResolution {
    /// The chroma hop at the pipeline's standard configuration (4096 samples at 44.1 kHz,
    /// `AudioFileAnalysisService`), i.e. how often the classifier can possibly change its mind.
    static let nominalChromaHopSeconds = 4096.0 / 44_100.0

    /// Windows per beat never exceed this. 4 accommodates the charting requirement of up to
    /// three chords per beat (Eric, 2026-08-19) with a sixteenth of headroom, and it is also
    /// the best configuration the ground-truth corpus ever measured: swept with the audits on
    /// (guitar arm, root F1 / over-segmentation) 1 = 50.9 / 2.34, 2 = 50.0 / 2.64,
    /// 4 = 56.7 / 1.56.
    static let maximumSubdivision = 4

    /// A window must expect at least this many chroma frames or it stops being a vote and
    /// degenerates into per-frame decoding. 1.6 is calibrated so the corpus's own best
    /// configuration stays admissible (94 BPM at subdivision 4 holds ~1.7 frames — the exact
    /// setting that measured 56.7 / 1.56); anything thinner steps DOWN a level instead.
    static let minimumFramesPerWindow = 1.6

    /// Windows per beat for a song whose beat lasts `beatLength` seconds: the finest level
    /// (up to `maximumSubdivision`) whose windows still hold `minimumFramesPerWindow` chroma
    /// frames. Slow songs decode at quarter-beat resolution; fast songs step down rather than
    /// out-resolving the evidence. `ChordEventDurationFilter`'s 0.25-beat floor and the
    /// decoder's per-frame no-chord normalization were both already sized for this.
    static func subdivision(beatLength: TimeInterval) -> Int {
        guard beatLength > 0 else { return 1 }
        let framesPerBeat = beatLength / nominalChromaHopSeconds
        var level = maximumSubdivision
        while level > 1, framesPerBeat / Double(level) < minimumFramesPerWindow {
            level -= 1
        }
        return level
    }
}
