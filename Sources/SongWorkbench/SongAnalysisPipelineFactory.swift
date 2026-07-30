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
    var capabilityProfile: AnalysisCapabilityProfile = .current
    var stemRefinementEngineFactory: StemRefinementEngineFactory = .empty

    struct Assembly: Sendable {
        let pipeline: SongAnalysisPipeline
        let statuses: [String: ModelPackageStatus]
        let capabilityProfile: AnalysisCapabilityProfile
    }

    func makePipeline() async throws -> Assembly {
        var statuses: [String: ModelPackageStatus] = [:]
        func installedPackage(
            _ descriptor: ModelPackageDescriptor
        ) async -> InstalledModelPackage? {
            let status = await modelPackageManager.statusForAnalysis(for: descriptor)
            statuses[descriptor.id] = status
            guard case .installed(let package) = status else { return nil }
            return package
        }

        let stemEngine: (any StemSeparationEngine)?
        let baseStemPackage: InstalledModelPackage?
        if capabilityProfile.stemSeparationTier == .reducedSixStem,
            ModelCatalog.htdemucs.isBundledOnCurrentPlatform,
            let bundledURL = ModelCatalog.htdemucs.bundledResourceURL
        {
            // iPad: the shorter-segment 6-stem model ships in the app bundle (the full 7.8s
            // model OOMs). Use it directly and publish htdemucs as installed so nothing waits
            // on a download for it.
            let size = Int64(
                (try? FileManager.default.attributesOfItem(atPath: bundledURL.path)[.size]
                    as? Int) ?? 0)
            statuses[ModelCatalog.htdemucs.id] = .installed(
                InstalledModelPackage(
                    descriptorID: ModelCatalog.htdemucs.id,
                    version: ModelCatalog.htdemucs.version,
                    packageDirectoryURL: bundledURL.deletingLastPathComponent(),
                    entryPointURL: bundledURL,
                    sizeBytes: size
                ))
            let segmentFrames = ONNXSixStemSeparationEngine.iPadSegmentFrames
            stemEngine = DeferredStemSeparationEngine(
                metadata: ONNXSixStemSeparationEngine.metadata(
                    usesCoreML: false,
                    segmentFrames: segmentFrames
                )
            ) {
                try await Task.detached(priority: .userInitiated) {
                    try ONNXSixStemSeparationEngine(
                        modelURL: bundledURL,
                        segmentFrames: segmentFrames
                    )
                }.value
            }
            baseStemPackage = nil
        } else if capabilityProfile.stemSeparationTier == .fullSixStem
            || capabilityProfile.stemSeparationTier == .advancedDesktop,
            let stemPackage = await installedPackage(ModelCatalog.htdemucs)
        {
            baseStemPackage = stemPackage
            stemEngine = DeferredStemSeparationEngine(
                metadata: ONNXSixStemSeparationEngine.cpuMetadata
            ) {
                try await Task.detached(priority: .userInitiated) {
                    // CPU execution provider (known-good). The CoreML/ANE provider was tried for
                    // speed but reverted until it can be verified not to break separation output.
                    try ONNXSixStemSeparationEngine(modelURL: stemPackage.entryPointURL)
                }.value
            }
        } else {
            stemEngine = nil
            baseStemPackage = nil
        }
        if capabilityProfile.stemSeparationTier == .advancedDesktop {
            // Populate optional refiner package status for factory assembly without
            // making DrumSep required for onboarding.
            _ = await installedPackage(ModelCatalog.drumsep)
        }
        let stemRefiners: [any StemRefinementEngine]
        if capabilityProfile.stemSeparationTier == .advancedDesktop, stemEngine != nil {
            stemRefiners = try await stemRefinementEngineFactory.engines(
                for: StemRefinementEngineFactory.Context(
                    capabilityProfile: capabilityProfile,
                    baseStemPackage: baseStemPackage,
                    modelStatuses: statuses
                )
            )
        } else {
            stemRefiners = []
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
        let accuracyEngine: (any TranscriptionEngine)?
        if capabilityProfile.allowsTranscriptionMode(.accuracy) {
            let accuracyPackage = await installedPackage(ModelCatalog.whisperAccuracy)
            accuracyEngine = accuracyPackage.map {
                WhisperCPPTranscriptionEngine(
                    modelURL: $0.entryPointURL,
                    modelSizeBytes: UInt64(max($0.sizeBytes, 0))
                )
            }
        } else {
            accuracyEngine = nil
        }

        let pipeline = SongAnalysisPipeline(
            stemEngine: stemEngine,
            stemRefiners: stemRefiners,
            transcriptionEngineFactory: TranscriptionEngineFactory(
                fast: fastEngine,
                balanced: balancedEngine,
                accuracy: accuracyEngine
            ).filtered(to: capabilityProfile),
            harmonyEngine: harmonyEngine,
            cache: cache,
            executionPolicy: capabilityProfile.executionPolicy
        )
        return Assembly(
            pipeline: pipeline,
            statuses: statuses,
            capabilityProfile: capabilityProfile
        )
    }
}

struct StemRefinementEngineFactory: Sendable {
    struct Context: Sendable {
        let capabilityProfile: AnalysisCapabilityProfile
        let baseStemPackage: InstalledModelPackage?
        let modelStatuses: [String: ModelPackageStatus]
    }

    var makeEngines: @Sendable (Context) async throws -> [any StemRefinementEngine]

    static let empty = StemRefinementEngineFactory { _ in [] }

    /// Production desktop refiners. Currently registers DrumSep when its package is installed;
    /// guitar lead/rhythm remains unregistered until a verified model artifact exists.
    static let production = StemRefinementEngineFactory { context in
        guard context.capabilityProfile.stemSeparationTier == .advancedDesktop else {
            return []
        }
        #if os(macOS)
            var engines: [any StemRefinementEngine] = []
            if case .installed(let package) = context.modelStatuses[ModelCatalog.drumsep.id] {
                let deferred = DeferredStemSeparationEngine(
                    metadata: ONNXDrumPieceSeparationEngine.metadata
                ) {
                    try ONNXDrumPieceSeparationEngine(modelURL: package.entryPointURL)
                }
                engines.append(
                    NativeStemRefinementEngine(
                        identifier: "drumsep-onnx-v1",
                        parentStemID: StemKind.drums.id,
                        outputs: ONNXDrumPieceSeparationEngine.refinementOutputs,
                        engine: deferred
                    )
                )
            }
            return engines
        #else
            return []
        #endif
    }

    func engines(for context: Context) async throws -> [any StemRefinementEngine] {
        try await makeEngines(context)
    }
}
