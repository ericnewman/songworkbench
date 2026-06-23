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
        let accompanimentURL = stems.accompaniment ?? stems.other
        guard FileManager.default.fileExists(atPath: accompanimentURL.path) else {
            throw HarmonyAudioSourceError.missingAccompanimentStem
        }
        return HarmonyAudioSource(
            url: accompanimentURL,
            kind: .accompanimentStem,
            configurationIdentifier: stems.accompaniment == nil
                ? "accompaniment-other-stem" : "accompaniment-guitar-piano-other"
        )
    }
}
