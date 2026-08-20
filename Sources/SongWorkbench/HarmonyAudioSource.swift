import Foundation

struct HarmonyAudioSource: Equatable, Sendable {
    /// The stem whose digest identifies this analysis in the cache. Always the highest-priority
    /// contributor that exists — every other contributor comes from the same separation of the
    /// same recording, so this one file identifies the whole set.
    let url: URL
    let kind: AnalysisSourceKind
    let configurationIdentifier: String
    /// Additional stems mixed in behind `url`, with their weights, highest first. Empty when
    /// chord detection is listening to a single file (the full-mix fallback, or a separation that
    /// produced only one usable harmonic stem).
    let additional: [(url: URL, weight: Float, label: String)]

    /// Every contributor in priority order, `url` first at its own weight.
    var weightedURLs: [(url: URL, weight: Float, label: String)] {
        [(url, primaryWeight, primaryLabel)] + additional
    }

    let primaryWeight: Float
    let primaryLabel: String

    init(
        url: URL,
        kind: AnalysisSourceKind,
        configurationIdentifier: String,
        primaryWeight: Float = 1,
        primaryLabel: String = "primary",
        additional: [(url: URL, weight: Float, label: String)] = []
    ) {
        self.url = url
        self.kind = kind
        self.configurationIdentifier = configurationIdentifier
        self.primaryWeight = primaryWeight
        self.primaryLabel = primaryLabel
        self.additional = additional
    }

    static func == (lhs: HarmonyAudioSource, rhs: HarmonyAudioSource) -> Bool {
        lhs.url == rhs.url
            && lhs.kind == rhs.kind
            && lhs.configurationIdentifier == rhs.configurationIdentifier
            && lhs.primaryWeight == rhs.primaryWeight
            && lhs.additional.count == rhs.additional.count
            && lhs.primaryLabel == rhs.primaryLabel
            && zip(lhs.additional, rhs.additional).allSatisfy {
                $0.url == $1.url && $0.weight == $1.weight && $0.label == $1.label
            }
    }
}

enum HarmonyAudioSourceError: LocalizedError, Equatable {
    case missingAccompanimentStem

    var errorDescription: String? {
        "The accompaniment stem is missing; rerun stem separation before chord analysis."
    }
}

struct HarmonyAudioSourceSelector: Sendable {
    /// Stems chord detection may listen to, in priority order. Vocals and drums are absent by
    /// design, not by omission: a sung third flips a power chord to major, and drums contribute
    /// only broadband noise to the chroma. See `HarmonyStemMix.defaultWeights` for why bass is
    /// present at weight 0 rather than simply left out.
    var weights: [(kind: StemKind, weight: Float)] = HarmonyStemMix.defaultWeights

    func select(
        recordingURL: URL,
        stems: StemFiles?,
        allowsRecordingFallback: Bool
    ) throws -> HarmonyAudioSource {
        guard let stems else {
            guard allowsRecordingFallback else {
                throw HarmonyAudioSourceError.missingAccompanimentStem
            }
            // Last resort only. The full mix is every instrument's opinion averaged together and
            // cannot be attributed to any player — vocals and bass included, which is exactly the
            // contamination stem separation exists to remove.
            return HarmonyAudioSource(
                url: recordingURL,
                kind: .recording,
                configurationIdentifier: "full-mix-fallback"
            )
        }

        var contributors: [(url: URL, weight: Float, kind: StemKind)] = []
        for entry in weights where entry.weight > 0 {
            guard let url = stems[entry.kind], FileManager.default.fileExists(atPath: url.path)
            else { continue }
            contributors.append((url, entry.weight, entry.kind))
        }

        if let primary = contributors.first {
            let identifier =
                "harmony-mix-" + contributors.map { $0.kind.rawValue }.joined(separator: "+")
            return HarmonyAudioSource(
                url: primary.url,
                kind: .accompanimentStem,
                configurationIdentifier: identifier,
                primaryWeight: primary.weight,
                primaryLabel: primary.kind.rawValue,
                additional: contributors.dropFirst().map {
                    ($0.url, $0.weight, $0.kind.rawValue)
                }
            )
        }

        // No weighted stem is present (a legacy four-stem separation with no guitar/piano split).
        // Fall back to the broadest vocal-free stem available rather than to the full mix.
        let fallbacks: [(URL?, String)] = [
            (stems.accompaniment, "harmony-accompaniment-stem"),
            (stems.other, "harmony-other-stem"),
        ]
        for (url, configurationIdentifier) in fallbacks {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            return HarmonyAudioSource(
                url: url,
                kind: .accompanimentStem,
                configurationIdentifier: configurationIdentifier
            )
        }
        throw HarmonyAudioSourceError.missingAccompanimentStem
    }
}
