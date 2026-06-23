import Foundation

enum StemKind: String, CaseIterable, Codable, Sendable {
    case vocals
    case drums
    case bass
    case guitar
    case piano
    case other

    static let legacyRequired: [StemKind] = [.vocals, .drums, .bass, .other]
}

struct StemFiles: Codable, Equatable, Sendable {
    let vocals: URL
    let drums: URL
    let bass: URL
    let guitar: URL?
    let piano: URL?
    let other: URL
    let accompaniment: URL?

    init(
        vocals: URL,
        drums: URL,
        bass: URL,
        guitar: URL? = nil,
        piano: URL? = nil,
        other: URL,
        accompaniment: URL? = nil
    ) {
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.guitar = guitar
        self.piano = piano
        self.other = other
        self.accompaniment = accompaniment
    }

    subscript(kind: StemKind) -> URL? {
        switch kind {
        case .vocals: vocals
        case .drums: drums
        case .bass: bass
        case .guitar: guitar
        case .piano: piano
        case .other: other
        }
    }

    var availableKinds: [StemKind] {
        StemKind.allCases.filter { self[$0] != nil }
    }

    var isSixSource: Bool {
        guitar != nil && piano != nil
    }
}

struct StemSeparationRequest: Equatable, Sendable {
    let inputURL: URL
    let outputDirectory: URL
}

struct StemSeparationResult: Equatable, Sendable {
    let stems: StemFiles
    let processingDuration: Duration
}

struct StemSeparationEngineMetadata: Equatable, Sendable {
    let engineIdentifier: String
    let engineVersion: String
    let modelIdentifier: String?
    let modelVersion: String?
}

struct StemSeparationProgress: Equatable, Sendable {
    enum Phase: String, Sendable {
        case loadingModel
        case preparingAudio
        case separating
        case writingOutputs
    }

    let phase: Phase
    let completedUnits: Int
    let totalUnits: Int

    var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
    }
}

protocol StemSeparationEngine: Sendable {
    var metadata: StemSeparationEngineMetadata { get }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult
}

extension StemSeparationEngine {
    var metadata: StemSeparationEngineMetadata {
        StemSeparationEngineMetadata(
            engineIdentifier: "stem-separation",
            engineVersion: "1",
            modelIdentifier: nil,
            modelVersion: nil
        )
    }
}
