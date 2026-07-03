import Foundation

struct HarmonyAudioSource: Equatable, Sendable {
    let url: URL
    let kind: AnalysisSourceKind
    let configurationIdentifier: String
}

enum HarmonyAudioSourceError: LocalizedError, Equatable {
    case missingAccompanimentStem

    var errorDescription: String? {
        "The accompaniment stem is missing; rerun stem separation before chord analysis."
    }
}

struct HarmonyAudioSourceSelector: Sendable {
    func select(
        recordingURL: URL,
        stems: StemFiles?,
        allowsRecordingFallback: Bool
    ) throws -> HarmonyAudioSource {
        guard let stems else {
            guard allowsRecordingFallback else {
                throw HarmonyAudioSourceError.missingAccompanimentStem
            }
            return HarmonyAudioSource(
                url: recordingURL,
                kind: .recording,
                configurationIdentifier: "full-mix-fallback"
            )
        }

        // Prefer the stem with the clearest harmonic content for chroma analysis.
        let candidates: [(URL?, String)] = [
            (stems.guitar, "harmony-guitar-stem"),
            (stems.piano, "harmony-piano-stem"),
            (stems.accompaniment, "harmony-accompaniment-stem"),
            (stems.other, "harmony-other-stem"),
        ]
        for (url, configurationIdentifier) in candidates {
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
