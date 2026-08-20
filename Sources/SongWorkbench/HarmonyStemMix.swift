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
