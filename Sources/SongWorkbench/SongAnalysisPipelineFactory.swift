import Foundation

/// Assembles a `SongAnalysisPipeline` from installed model packages.
///
/// This concentrates the "which engine implementation pairs with which installed
/// model package" knowledge that previously lived inline in `AppModel`. It
/// resolves each model package's status and returns the assembled pipeline along
/// with the statuses it observed, so the caller can publish them.
struct SongAnalysisPipelineFactory: Sendable {
    /// The native Core ML six-stem model, if this process can see one: the env override first
    /// (CLI and export testing), then the copy bundled into the macOS app. nil means the ONNX
    /// engine runs instead. macOS-only: the 7.8s FP16 forward pass is untested against the iPad
    /// memory ceiling, and iPad ships the short-segment ONNX re-export.
    static var nativeSixStemModelURL: URL? {
        #if os(macOS)
            if let override = ProcessInfo.processInfo
                .environment["SW_STEM_NATIVE_COREML_MODEL"],
                FileManager.default.fileExists(atPath: override)
            {
                return URL(fileURLWithPath: override)
            }
            return Bundle.main.url(
                forResource: "HTDemucs6S_FP16", withExtension: "mlpackage")
        #else
            return nil
        #endif
    }

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
            let nativeURL = Self.nativeSixStemModelURL
        {
            // Native Core ML six-stem engine: same model as the ONNX path, on the GPU — 37s vs
            // 49s for a full song with 54+ dB stem parity (Benchmarks/STEM_SEPARATION.md,
            // 2026-08-26). Bundled into the macOS app; the env var serves the headless CLI
            // (which has no app bundle) and export testing. ONNX below remains the fallback
            // whenever the bundled model is absent.
            stemEngine = DeferredStemSeparationEngine(
                metadata: CoreMLNativeSixStemSeparationEngine.metadata
            ) {
                try await CoreMLNativeSixStemSeparationEngine(modelURL: nativeURL)
            }
            baseStemPackage = await installedPackage(ModelCatalog.htdemucs)
        } else if capabilityProfile.stemSeparationTier == .fullSixStem
            || capabilityProfile.stemSeparationTier == .advancedDesktop,
            let stemPackage = await installedPackage(ModelCatalog.htdemucs)
        {
            baseStemPackage = stemPackage
            // Segment size is the dominant memory lever: the 7.8 s default warms the ONNX arena
            // to ~3.9 GB, which thrashes on a machine that is already swapping. See
            // `AnalysisCapabilityProfile.prefersLowMemorySeparation`.
            let segmentFrames = ONNXSixStemSeparationEngine.currentSegmentFrames
            stemEngine = DeferredStemSeparationEngine(
                metadata: ONNXSixStemSeparationEngine.metadata(
                    usesCoreML: false, segmentFrames: segmentFrames)
            ) {
                try await Task.detached(priority: .userInitiated) {
                    // CPU execution provider, and MEASURED as the right choice — do not re-try
                    // CoreML without new evidence: on a 3:36 song the CoreML/ANE provider ran the
                    // exported graph as 120 partitions of 1542 nodes and took 472 s against CPU's
                    // 49 s (2026-08-25, Benchmarks/STEM_SEPARATION.md). The karaoke BS-RoFormer
                    // failed the same way (179 partitions, SIGKILL). Any future acceleration
                    // needs a single-partition export, not a provider flag.
                    try ONNXSixStemSeparationEngine(
                        modelURL: stemPackage.entryPointURL, segmentFrames: segmentFrames)
                }.value
            }
        } else {
            stemEngine = nil
            baseStemPackage = nil
        }
        if capabilityProfile.stemSeparationTier == .advancedDesktop {
            // Populate optional refiner package status for factory assembly without
            // making these required for onboarding.
            _ = await installedPackage(ModelCatalog.drumsep)
            _ = await installedPackage(ModelCatalog.karaokeVocals)
        }
        let stemRefiners: [any StemRefinementEngine]
        if capabilityProfile.stemSeparationTier == .advancedDesktop, stemEngine != nil {
            stemRefiners = try await stemRefinementEngineFactory.engines(
                for: StemRefinementEngineFactory.Context(
                    capabilityProfile: capabilityProfile,
                    baseStemPackage: baseStemPackage,
                    modelStatuses: statuses,
                    wantsVocalVoiceSeparation: AnalysisCapabilityProfile
                        .prefersVocalVoiceSeparation,
                    wantsDrumPieceSeparation: AnalysisCapabilityProfile.prefersDrumPieceSeparation
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
        /// Which optional refiners the user actually wants. Passed in rather than read from
        /// `UserDefaults` inside the factory so the choice is visible at the call site and
        /// testable without touching global state.
        let wantsVocalVoiceSeparation: Bool
        let wantsDrumPieceSeparation: Bool

        init(
            capabilityProfile: AnalysisCapabilityProfile,
            baseStemPackage: InstalledModelPackage?,
            modelStatuses: [String: ModelPackageStatus],
            wantsVocalVoiceSeparation: Bool = true,
            wantsDrumPieceSeparation: Bool = true
        ) {
            self.capabilityProfile = capabilityProfile
            self.baseStemPackage = baseStemPackage
            self.modelStatuses = modelStatuses
            self.wantsVocalVoiceSeparation = wantsVocalVoiceSeparation
            self.wantsDrumPieceSeparation = wantsDrumPieceSeparation
        }
    }

    var makeEngines: @Sendable (Context) async throws -> [any StemRefinementEngine]

    static let empty = StemRefinementEngineFactory { _ in [] }

    /// Production desktop refiners: each optional refiner is registered only when its package is
    /// installed AND the user asked for it, because each one adds a full model pass (measured on a
    /// 3:36 song: vocals 310 s, drums 73 s). Guitar lead/rhythm remains unregistered until a
    /// verified model artifact exists.
    static let production = StemRefinementEngineFactory { context in
        guard context.capabilityProfile.stemSeparationTier == .advancedDesktop else {
            return []
        }
        #if os(macOS)
            var engines: [any StemRefinementEngine] = []
            if context.wantsDrumPieceSeparation,
                case .installed(let package) = context.modelStatuses[ModelCatalog.drumsep.id]
            {
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
            if context.wantsVocalVoiceSeparation,
                case .installed(let package) = context.modelStatuses[ModelCatalog.karaokeVocals.id]
            {
                let deferred = DeferredStemSeparationEngine(
                    metadata: ONNXKaraokeVocalSeparationEngine.metadata
                ) {
                    try ONNXKaraokeVocalSeparationEngine(modelURL: package.entryPointURL)
                }
                engines.append(
                    NativeStemRefinementEngine(
                        identifier: "karaoke-bsroformer-v1",
                        parentStemID: StemKind.vocals.id,
                        outputs: ONNXKaraokeVocalSeparationEngine.refinementOutputs,
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
