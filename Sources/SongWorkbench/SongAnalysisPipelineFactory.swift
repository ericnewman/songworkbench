import Foundation

/// Assembles a `SongAnalysisPipeline` from installed model packages.
///
/// This concentrates the "which engine implementation pairs with which installed
/// model package" knowledge that previously lived inline in `AppModel`. It
/// resolves each model package's status and returns the assembled pipeline along
/// with the statuses it observed, so the caller can publish them.
struct SongAnalysisPipelineFactory: Sendable {
    let modelPackageManager: ModelPackageManager
    let harmonyEngine: AudioFileAnalysisService
    let cache: AnalysisResultDiskCache

    struct Assembly: Sendable {
        let pipeline: SongAnalysisPipeline
        let statuses: [String: ModelPackageStatus]
    }

    func makePipeline() async throws -> Assembly {
        var statuses: [String: ModelPackageStatus] = [:]
        func installedPackage(
            _ descriptor: ModelPackageDescriptor
        ) async -> InstalledModelPackage? {
            let status = await modelPackageManager.status(for: descriptor)
            statuses[descriptor.id] = status
            guard case .installed(let package) = status else { return nil }
            return package
        }

        let stemPackage = await installedPackage(ModelCatalog.htdemucs)
        let stemEngine: (any StemSeparationEngine)?
        if let stemPackage {
            stemEngine = try await Task.detached(priority: .userInitiated) {
                try ONNXSixStemSeparationEngine(modelURL: stemPackage.entryPointURL)
            }.value
        } else {
            stemEngine = nil
        }

        let fastPackage = await installedPackage(ModelCatalog.parakeetFastDraft)
        let fastEngine: (any TranscriptionEngine)? = fastPackage.map {
            FluidAudioTranscriptionEngine(
                modelDirectory: $0.entryPointURL,
                modelSizeBytes: UInt64(max($0.sizeBytes, 0)),
                profile: .fastDraft
            )
        }
        let balancedEngine: (any TranscriptionEngine)? = fastPackage.map {
            FluidAudioTranscriptionEngine(
                modelDirectory: $0.entryPointURL,
                modelSizeBytes: UInt64(max($0.sizeBytes, 0)),
                profile: .balancedDraft
            )
        }
        let accuracyPackage = await installedPackage(ModelCatalog.whisperAccuracy)
        let accuracyEngine: (any TranscriptionEngine)? = accuracyPackage.map {
            WhisperCPPTranscriptionEngine(
                modelURL: $0.entryPointURL,
                modelSizeBytes: UInt64(max($0.sizeBytes, 0))
            )
        }

        let pipeline = SongAnalysisPipeline(
            stemEngine: stemEngine,
            fastTranscriptionEngine: fastEngine,
            balancedTranscriptionEngine: balancedEngine,
            accuracyTranscriptionEngine: accuracyEngine,
            harmonyEngine: harmonyEngine,
            cache: cache
        )
        return Assembly(pipeline: pipeline, statuses: statuses)
    }
}
