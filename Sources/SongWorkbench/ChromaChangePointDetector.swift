import Accelerate
import Foundation

/// Detects points in time where the underlying HARMONY changes — as opposed to where a note is
/// merely struck. This is the rigorous counterpart to `InstrumentOnsetDetector`: that type finds
/// broadband energy attacks (any pluck/strum), which conflates a note attack *within* a sustained
/// chord with an actual chord CHANGE. A chroma change-point looks at the pitch-class content
/// itself: a strummed repeat of the same chord barely moves the chroma vector, while a chord
/// CHANGE moves it a lot, even when the pick attack is soft or the new chord shares notes with the
/// old one.
///
/// Pipeline: frame-to-frame cosine distance between successive chroma vectors → optional centered
/// moving-average smoothing (off by default: validated against synthetic step functions and 50
/// independent jittered trials, smoothing turned out to bias a clean step's detected time by half
/// a smoothing window and bought no extra robustness once the threshold below is scale-correct) →
/// adaptive-threshold peak picking (median + k·MAD of the distance curve, the same robust-
/// statistics shape `InstrumentOnsetDetector` uses for its flux threshold, with the MAD scaled by
/// the standard 1.4826 consistency constant so it approximates a noise std-dev instead of
/// under-estimating it) → minimum-spacing de-bounce so one harmonic transition doesn't fire twice.
///
/// Pure & deterministic — no I/O, no audio decoding. Consumes whatever produced the chroma frames
/// (the live per-frame `ChromaAnalyzer` output, or any synthetic sequence for testing) so it does
/// not depend on how those frames were generated.
enum ChromaChangePointDetector {
    struct Configuration: Sendable {
        /// Frames averaged together (centered) before peak-picking. 1 disables smoothing (the
        /// default — see the type doc for why smoothing is off by default).
        var smoothingWindow: Int = 1
        /// Multiple of the (scaled) MAD added to the median distance to form the adaptive
        /// threshold. Higher = fewer, more confident change-points. 6.0 was the smallest value
        /// that cleared jitter noise across 50 independent synthetic trials while still catching
        /// every genuine change in a 4-chord/15-transition progression (see
        /// `ChromaChangePointDetectorTests`).
        var thresholdMultiplier: Double = 6.0
        /// Minimum spacing between successive change-points, so one harmonic transition (which can
        /// spread its distance bump across a couple of frames once smoothed) only fires once.
        var minSpacingSeconds: TimeInterval = 0.12

        init(
            smoothingWindow: Int = 1,
            thresholdMultiplier: Double = 6.0,
            minSpacingSeconds: TimeInterval = 0.12
        ) {
            self.smoothingWindow = max(smoothingWindow, 1)
            self.thresholdMultiplier = max(thresholdMultiplier, 0)
            self.minSpacingSeconds = max(minSpacingSeconds, 0)
        }
    }

    /// Harmonic change-point times (seconds), one per detected chroma transition. Empty for
    /// degenerate input (fewer than 2 frames, or a flat/silent chroma sequence with no distance
    /// signal at all).
    ///
    /// - Precondition: none enforced — frames need not be sorted; they are sorted internally by
    ///   `timestamp` before distances are computed, so an out-of-order sequence still yields
    ///   correct change-points (just as a defensive measure; callers should already supply frames
    ///   in time order).
    static func changePoints(
        frames: [ChromaVector],
        configuration: Configuration = .init()
    ) -> [TimeInterval] {
        guard frames.count >= 2 else { return [] }
        let sorted = frames.sorted { $0.timestamp < $1.timestamp }

        let distances = frameToFrameDistances(sorted)
        guard distances.contains(where: { $0 > 0 }) else { return [] }

        let smoothed = movingAverage(distances, window: configuration.smoothingWindow)
        let threshold = adaptiveThreshold(
            smoothed, multiplier: configuration.thresholdMultiplier)

        var changePoints: [TimeInterval] = []
        var lastPointTime = -Double.infinity
        // distances[i] is the distance between sorted[i] and sorted[i+1]; a change "belongs" to
        // the later frame's timestamp, i.e. the moment the new chord is first observed.
        for i in smoothed.indices {
            guard smoothed[i] >= threshold else { continue }
            let prev = i > 0 ? smoothed[i - 1] : -Double.infinity
            let next = i + 1 < smoothed.count ? smoothed[i + 1] : -Double.infinity
            guard smoothed[i] >= prev, smoothed[i] >= next else { continue }  // local maximum
            let time = sorted[i + 1].timestamp
            guard time - lastPointTime >= configuration.minSpacingSeconds else { continue }
            changePoints.append(time)
            lastPointTime = time
        }
        return changePoints
    }

    /// Cosine distance (`1 - cosine similarity`) between each pair of adjacent frames. Cosine
    /// distance (rather than Euclidean) is insensitive to the frames' overall loudness/energy —
    /// both `ChromaVector`s are already normalized to sum to 1, but cosine distance additionally
    /// stays well-behaved for quiet passages where the vectors are small but not zero. Distance is
    /// `0` for identical direction, up to `2` for opposite, `0` whenever either frame is silent
    /// (all-zero chroma) so silence never manufactures a spurious change-point.
    private static func frameToFrameDistances(_ frames: [ChromaVector]) -> [Double] {
        guard frames.count >= 2 else { return [] }
        var distances = [Double](repeating: 0, count: frames.count - 1)
        for i in 0..<(frames.count - 1) {
            distances[i] = cosineDistance(frames[i].values, frames[i + 1].values)
        }
        return distances
    }

    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b)
        let normA = sqrt(vDSP.sumOfSquares(a))
        let normB = sqrt(vDSP.sumOfSquares(b))
        guard normA > 0, normB > 0 else { return 0 }
        let cosineSimilarity = Double(dot) / Double(normA * normB)
        return 1 - max(-1, min(1, cosineSimilarity))
    }

    /// Centered moving average; `window` of 1 returns the input unchanged. Edge frames average
    /// over however much of the window actually fits (no zero-padding, so edges are not damped
    /// toward zero).
    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        let half = window / 2
        var result = [Double](repeating: 0, count: values.count)
        for i in values.indices {
            let lower = max(0, i - half)
            let upper = min(values.count - 1, i + half)
            var sum = 0.0
            for j in lower...upper { sum += values[j] }
            result[i] = sum / Double(upper - lower + 1)
        }
        return result
    }

    /// Consistency constant that scales MAD (median absolute deviation) to approximate a normal
    /// distribution's standard deviation. Without this scaling, MAD alone under-estimates the
    /// noise spread by roughly 1.5x for continuous jitter, which let real synthetic jitter trials
    /// slip several false change-points past the threshold (validated empirically; see
    /// `ChromaChangePointDetectorTests`). Standard statistical constant, not tuned per-dataset.
    private static let madConsistencyScale = 1.4826
    /// Absolute floor under the adaptive threshold. Guards two degenerate cases: (1) a perfectly
    /// flat/near-silent distance curve, where both the median and MAD are exactly 0 and any
    /// nonzero value — including floating-point noise — would otherwise clear a threshold of 0;
    /// (2) the same shape with actual float noise. Tiny relative to any real chroma-distance
    /// signal (distances range roughly 0...2).
    private static let minimumThresholdFloor = 1e-6

    /// Median + `multiplier` × (scaled) MAD of `values`. Robust to a handful of large outlier
    /// distances (the real change-points themselves), unlike a mean+stddev threshold which those
    /// same outliers would inflate.
    private static func adaptiveThreshold(_ values: [Double], multiplier: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sortedValues = values.sorted()
        let med = median(sortedValues)
        let deviations = values.map { abs($0 - med) }.sorted()
        let mad = median(deviations) * madConsistencyScale
        let spread: Double
        if mad > 0 {
            spread = mad
        } else if med > 0 {
            // Zero MAD but a nonzero median: fall back to a small fraction of the median.
            spread = med * 0.1
        } else {
            // Both are exactly 0 (a flat/silent curve broken only by a few real spikes, or true
            // silence). Base the floor on the curve's own peak so it scales with the signal
            // instead of ever being literally 0.
            let peak = values.max() ?? 0
            spread = max(peak * 0.1, minimumThresholdFloor)
        }
        return max(med + multiplier * spread, minimumThresholdFloor)
    }

    private static func median(_ sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let mid = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[mid - 1] + sortedValues[mid]) / 2
        }
        return sortedValues[mid]
    }
}

/// Compares persisted chord-event boundary times against genuine harmonic change-points (from
/// `ChromaChangePointDetector`), rather than against crude broadband-onset peaks. This is the
/// metric the 2026-07-02 "There's a party goin on" audit flagged as missing: onset-nearest-
/// neighbour metrics conflate note attacks with chord changes, so a chord event can score as
/// "near an onset" purely because of a strum inside the SAME chord, not because a chord change
/// actually happened there.
struct ChordChangePointAudit: Sendable {
    struct Result: Equatable, Sendable {
        /// Signed median of (nearest change-point time − chord event time), seconds. Positive
        /// means chord events tend to fire BEFORE the detected harmonic change; negative means
        /// AFTER.
        let signedMedianError: TimeInterval
        /// Median of |nearest change-point time − chord event time|, seconds.
        let medianAbsoluteError: TimeInterval
        /// Fraction of chord events with a change-point within `tolerance` of them.
        let hitRate: Double
        /// Number of chord events evaluated (events are only counted when at least one
        /// change-point exists to compare against).
        let eventCount: Int
    }

    /// - Parameters:
    ///   - chordEventTimes: persisted chord-boundary times (seconds), any order.
    ///   - changePoints: genuine harmonic change-point times from `ChromaChangePointDetector`.
    ///   - tolerance: window (seconds) within which a change-point "explains" a chord event.
    /// - Returns: `nil` when either input is empty (nothing to compare).
    static func audit(
        chordEventTimes: [TimeInterval],
        changePoints: [TimeInterval],
        tolerance: TimeInterval = 0.15
    ) -> Result? {
        guard !chordEventTimes.isEmpty, !changePoints.isEmpty else { return nil }
        let sortedChangePoints = changePoints.sorted()

        var signedErrors: [TimeInterval] = []
        var absoluteErrors: [TimeInterval] = []
        var hits = 0

        for eventTime in chordEventTimes {
            guard let nearest = nearestValue(to: eventTime, in: sortedChangePoints) else {
                continue
            }
            let signed = nearest - eventTime
            signedErrors.append(signed)
            absoluteErrors.append(abs(signed))
            if abs(signed) <= tolerance { hits += 1 }
        }
        guard !signedErrors.isEmpty else { return nil }

        return Result(
            signedMedianError: median(signedErrors),
            medianAbsoluteError: median(absoluteErrors),
            hitRate: Double(hits) / Double(signedErrors.count),
            eventCount: signedErrors.count
        )
    }

    private static func nearestValue(to time: TimeInterval, in sortedValues: [TimeInterval])
        -> TimeInterval?
    {
        guard !sortedValues.isEmpty else { return nil }
        var low = 0
        var high = sortedValues.count - 1
        if time <= sortedValues[low] { return sortedValues[low] }
        if time >= sortedValues[high] { return sortedValues[high] }
        while low <= high {
            let mid = (low + high) / 2
            let value = sortedValues[mid]
            if value == time { return value }
            if value < time { low = mid + 1 } else { high = mid - 1 }
        }
        let below = sortedValues[high]
        let above = sortedValues[low]
        return (time - below) <= (above - time) ? below : above
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sortedValues = values.sorted()
        let mid = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[mid - 1] + sortedValues[mid]) / 2
        }
        return sortedValues[mid]
    }
}
