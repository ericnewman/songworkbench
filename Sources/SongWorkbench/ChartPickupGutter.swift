import Foundation

/// How much room a chart row reserves to the LEFT of its downbeat, in WHOLE BEATS.
///
/// The gutter exists so anacrusis — a word or chord sounding before the bar it resolves onto —
/// renders left of the downbeat instead of clipping. It used to be a flat 2 beats on every row,
/// which meant a song whose first sound lands on beat one still drew two beats of blank space in
/// front of it (Eric, on Doc Holiday, whose first chord is stored at beat index 0.00: it "is the
/// very first sound of the song", so it belongs at the left edge).
///
/// Two earlier designs were measured and rejected:
///
/// - A CONTINUOUS per-row gutter (`6c025e4`, reverted in `816857f`) put every row's downbeat at an
///   arbitrary sub-beat x, so beat dots and barlines stopped forming vertical columns down the
///   page ("uneven beats at the start of the lines").
/// - A SONG-LEVEL gutter sized to the largest pickup any row needs. Measured over the whole live
///   library 2026-08-07: every song has at least one row whose first word sits 1.6–2.1 beats
///   before its own downbeat, at every bar phase — so the song-level maximum resolves to the
///   2-beat cap on every song and renders pixel-identical to the flat gutter it was meant to
///   replace.
///
/// Quantising a PER-ROW gutter to whole beats gets both properties at once. `gutterPx` is then an
/// exact integer multiple of `pixelsPerBeat`, so every beat dot and barline still sits at phase 0
/// and the columns hold BY CONSTRUCTION; only the downbeat column shifts between rows, and by
/// whole beats. Eric confirmed (2026-08-07) the beat/bar columns are the alignment he reads off
/// the page.
enum ChartPickupGutter {
    /// Hard cap, shared with `ChordProPreviewLineLayout.gutterBeats`: a long lead-in must never
    /// push the row's content column off-screen.
    static let maximumBeats = 2

    /// Pickups smaller than this are performance jitter, not an anacrusis. Without it a bare
    /// `ceil` turns Doc Holiday's median 0.02-beat pickup into a full beat of empty gutter.
    static let deadbandBeats = 0.15

    /// Whole beats of gutter this row needs.
    ///
    /// `earliestContent` must be the row's earliest real SOUND — its first word or chord onset.
    /// Deliberately NOT the row's nominal start: a row can open in silence (the song's first row
    /// starts at 0:00 while the first sound is a second later) and reserving for that silence is
    /// exactly what pushed the opening chord away from the left edge.
    ///
    /// Deliberately NOT the leading melody fill either. That fill is drawn from
    /// `rowDownbeat - gutterSeconds` by construction, so feeding it back in here is circular —
    /// the gutter would create the evidence that justifies the gutter, and every row would pin
    /// to the cap.
    static func beats(
        downbeat: TimeInterval?,
        earliestContent: TimeInterval?,
        beatLengthSeconds: TimeInterval
    ) -> Int {
        guard let downbeat, let earliestContent, beatLengthSeconds > 0,
            earliestContent < downbeat
        else { return 0 }
        let pickupBeats = (downbeat - earliestContent) / beatLengthSeconds
        guard pickupBeats > deadbandBeats else { return 0 }
        let needed = Int(pickupBeats.rounded(.up))
        return min(max(needed, 0), maximumBeats)
    }

    /// The same value in seconds, for the row's `gutterSeconds`.
    static func seconds(
        downbeat: TimeInterval?,
        earliestContent: TimeInterval?,
        beatLengthSeconds: TimeInterval
    ) -> TimeInterval {
        Double(
            beats(
                downbeat: downbeat, earliestContent: earliestContent,
                beatLengthSeconds: beatLengthSeconds)
        ) * beatLengthSeconds
    }
}
