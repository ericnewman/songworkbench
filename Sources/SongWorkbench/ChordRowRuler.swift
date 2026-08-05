import CoreGraphics
import Foundation

/// THE single time→x mapping for one chart row. Every visual element on a row — words, chords,
/// beat dots, barlines, waveform strip, melody fills, balls, drag gestures — converts song time
/// to pixels through this one struct, so the whole row is on ONE axis by construction.
///
/// This exists because the chart previously had four coexisting x-axes in a single row (the beat
/// axis, the collision-nudged word axis, raw bar-pixel arithmetic, and a scaled time axis for
/// instrumental rows), and every spacing bug was one element disagreeing with another about the
/// ruler. Text labels may still be nudged apart so they don't overlap, but a nudge is a LABEL
/// offset — it must never feed back into any other element's position.
///
/// With a usable `grid` the axis is metric: one beat is exactly `pixelsPerBeat` wide regardless
/// of how long that beat actually lasted, so beats are equidistant and rows are directly
/// comparable ("graph paper"). The mapping is fractional — a word a third of the way through a
/// beat renders a third of the way through that beat's column; nothing is quantized. Without a
/// grid the whole row falls back to a uniform time axis at `pixelsPerSecond` — per row the axis
/// is one or the other, never a mix.
struct ChordRowRuler: Equatable {
    /// The song's measured beat grid, or nil for the uniform time-axis fallback.
    let grid: MeasureGrid?
    /// The time rendered at `gutterPx` — the row's resolving downbeat (or first word / row start).
    let originTime: TimeInterval
    /// Left px of the origin column; the pickup gutter sits to its left.
    let gutterPx: CGFloat
    /// Width of one beat on the metric axis.
    let pixelsPerBeat: CGFloat
    /// Scale of the no-grid fallback axis.
    let pixelsPerSecond: CGFloat

    private var originIndex: Double { grid?.beatIndex(atTime: originTime) ?? 0 }

    /// x of a song time. Clamped at 0 so pickups earlier than the gutter can't render off-canvas.
    func x(atTime time: TimeInterval) -> CGFloat {
        guard let grid else {
            return max(0, gutterPx + CGFloat(time - originTime) * pixelsPerSecond)
        }
        let delta = grid.beatIndex(atTime: time) - originIndex
        return max(0, gutterPx + CGFloat(delta) * pixelsPerBeat)
    }

    /// Inverse of `x(atTime:)` (ignoring the 0-clamp): the song time rendered at an x. This is
    /// what drag gestures must use — on the metric axis px-per-second varies locally with the
    /// measured beat lengths, so a fixed px/s conversion moves a dragged chord by the wrong time.
    func time(atX x: CGFloat) -> TimeInterval {
        guard let grid else {
            return originTime + TimeInterval((x - gutterPx) / max(pixelsPerSecond, 0.0001))
        }
        let index = originIndex + Double((x - gutterPx) / max(pixelsPerBeat, 0.0001))
        return grid.time(atBeatIndex: index)
    }

    /// x of every beat in `[start, end]`, generated in INDEX space so dots are exactly
    /// `pixelsPerBeat` apart on every row. Generating beats in time space and mapping them back
    /// through a measured grid is what previously made dot spacing wobble: a window with no
    /// measured beats got beats synthesized uniform-in-TIME, which are non-uniform in pixels on
    /// a measured-beat axis.
    func beatXs(from start: TimeInterval, to end: TimeInterval) -> [CGFloat] {
        guard end > start else { return [] }
        let firstIndex: Double
        let lastIndex: Double
        if let grid {
            firstIndex = grid.beatIndex(atTime: start).rounded(.up)
            lastIndex = grid.beatIndex(atTime: end).rounded(.down)
        } else {
            guard pixelsPerBeat > 0, pixelsPerSecond > 0 else { return [] }
            let beatLength = TimeInterval(pixelsPerBeat / pixelsPerSecond)
            guard beatLength > 0 else { return [] }
            firstIndex = ((start - originTime) / beatLength).rounded(.up)
            lastIndex = ((end - originTime) / beatLength).rounded(.down)
        }
        guard lastIndex >= firstIndex else { return [] }
        // Cap so a degenerate grid can never spin the layout loop.
        let count = min(Int(lastIndex - firstIndex) + 1, 512)
        let originIdx = originIndex
        return (0..<count).map { k in
            let index = firstIndex + Double(k)
            if grid != nil {
                return max(0, gutterPx + CGFloat(index - originIdx) * pixelsPerBeat)
            }
            return max(0, gutterPx + CGFloat(index) * pixelsPerBeat)
        }
    }
}
