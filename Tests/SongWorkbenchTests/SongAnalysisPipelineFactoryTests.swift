import CryptoKit
import Foundation
import XCTest

@testable import SongWorkbench

final class SongAnalysisPipelineFactoryTests: XCTestCase {
    func testAdvancedDesktopFactoryInjectsRefinerRecipeIntoSeparationPipeline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.wav")
        try Data("source audio".utf8).write(to: sourceURL)
        let outputDirectory = root.appendingPathComponent("analysis", isDirectory: true)
        let modelDirectory = root.appendingPathComponent("models", isDirectory: true)
        let basePackage = try installFakeHTDemucsPackage(in: modelDirectory)
        let manager = ModelPackageManager(
            directoryURL: modelDirectory,
            downloader: EmptyModelDownloader()
        )
        guard case .installed = await manager.status(for: ModelCatalog.htdemucs) else {
            return XCTFail("Expected fake HTDemucs package to verify as installed")
        }
        let recorder = StemRefinementFactoryRecorder(
            engines: [FactoryRefiner(identifier: "factory-drum-refiner")]
        )
        var factory = SongAnalysisPipelineFactory(
            modelPackageManager: manager,
            harmonyEngine: AudioFileAnalysisService(),
            cache: AnalysisResultDiskCache(directoryURL: root.appendingPathComponent("cache"))
        )
        factory.capabilityProfile = .desktopAdvanced
        factory.stemRefinementEngineFactory = StemRefinementEngineFactory { context in
            await recorder.makeEngines(context: context)
        }
        let assembly = try await factory.makePipeline()
        let recipe = StemRecipeIdentity(
            sourceDigest: sha256Hex(try Data(contentsOf: sourceURL)),
            baseEngine: ONNXSixStemSeparationEngine.cpuMetadata,
            segmentConfiguration: "six-stem-44.1k-stereo",
            refiners: ["factory-drum-refiner"],
            outputFormat: "wav"
        )
        let kickURL = outputDirectory.appendingPathComponent("kick.wav")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        try Data("kick".utf8).write(to: kickURL)
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: .drumKick,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Kick",
                    order: 100
                )
            ],
            assets: [
                StemAsset(id: .drumKick, audioURL: kickURL, producerID: "factory-drum-refiner")
            ],
            recipeIdentity: recipe
        )
        let expectedMetadata = StemSeparationEngineMetadata(
            engineIdentifier: ONNXSixStemSeparationEngine.cpuMetadata.engineIdentifier
                + "+refiners",
            engineVersion: ONNXSixStemSeparationEngine.cpuMetadata.engineVersion,
            modelIdentifier: ONNXSixStemSeparationEngine.cpuMetadata.modelIdentifier,
            modelVersion: ONNXSixStemSeparationEngine.cpuMetadata.modelVersion
        )
        var existing = SongAnalysisDocument(stemSet: StoredStemSetManifest(manifest: manifest))
        existing.stageRecords[.separation] = AnalysisStageRecord(
            state: .succeeded,
            provenance: AnalysisProvenance(
                sourceDigest: recipe.sourceDigest,
                sourceKind: .recording,
                engineIdentifier: expectedMetadata.engineIdentifier,
                engineVersion: expectedMetadata.engineVersion,
                modelIdentifier: expectedMetadata.modelIdentifier,
                modelVersion: expectedMetadata.modelVersion,
                configurationIdentifier: "stem-recipe-\(recipe.stableStorageName)",
                resultSchemaVersion: SongAnalysisDocument.currentSchemaVersion,
                completedAt: Date(timeIntervalSince1970: 1_750_000_000),
                loadedFromCache: false
            ),
            confidence: nil,
            errorMessage: nil
        )

        let result = try await assembly.pipeline.run(
            SongAnalysisPipelineRequest(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                title: "Cached Advanced Stems",
                stages: [.separation],
                transcriptionMode: .fastDraft,
                existingDocument: existing
            )
        ) { _ in }

        let contexts = await recorder.contexts()
        XCTAssertEqual(contexts.map(\.capabilityProfile.stemSeparationTier), [.advancedDesktop])
        XCTAssertEqual(contexts.first?.baseStemPackage?.entryPointURL, basePackage.entryPointURL)
        XCTAssertEqual(
            result.document.stageRecords[.separation]?.provenance?.loadedFromCache,
            true
        )
    }

    func testDefaultDesktopAndIPadProfilesDoNotRequestStemRefiners() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelDirectory = root.appendingPathComponent("models", isDirectory: true)
        _ = try installFakeHTDemucsPackage(in: modelDirectory)

        for profile in [AnalysisCapabilityProfile.profile(for: .desktop), .profile(for: .iPad)] {
            let manager = ModelPackageManager(
                directoryURL: modelDirectory,
                downloader: EmptyModelDownloader()
            )
            _ = await manager.status(for: ModelCatalog.htdemucs)
            let recorder = StemRefinementFactoryRecorder(
                engines: [FactoryRefiner(identifier: "should-not-run")]
            )
            var factory = SongAnalysisPipelineFactory(
                modelPackageManager: manager,
                harmonyEngine: AudioFileAnalysisService(),
                cache: AnalysisResultDiskCache(
                    directoryURL: root.appendingPathComponent(UUID().uuidString))
            )
            factory.capabilityProfile = profile
            factory.stemRefinementEngineFactory = StemRefinementEngineFactory { context in
                await recorder.makeEngines(context: context)
            }

            _ = try await factory.makePipeline()

            let contextCount = await recorder.contexts().count
            XCTAssertEqual(contextCount, 0)
        }
    }

    func testProductionFactoryInjectsDrumsepRefinerWhenPackageInstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelDirectory = root.appendingPathComponent("models", isDirectory: true)
        let basePackage = try installFakeHTDemucsPackage(in: modelDirectory)
        let drumPackage = try installFakeDrumsepPackage(in: modelDirectory)
        let manager = ModelPackageManager(
            directoryURL: modelDirectory,
            downloader: EmptyModelDownloader()
        )
        guard case .installed = await manager.status(for: ModelCatalog.htdemucs),
            case .installed = await manager.status(for: ModelCatalog.drumsep)
        else {
            return XCTFail("Expected fake HTDemucs and DrumSep packages to verify as installed")
        }

        var factory = SongAnalysisPipelineFactory(
            modelPackageManager: manager,
            harmonyEngine: AudioFileAnalysisService(),
            cache: AnalysisResultDiskCache(directoryURL: root.appendingPathComponent("cache"))
        )
        factory.capabilityProfile = .desktopAdvanced
        factory.stemRefinementEngineFactory = .production
        _ = try await factory.makePipeline()

        let refiners = try await StemRefinementEngineFactory.production.engines(
            for: StemRefinementEngineFactory.Context(
                capabilityProfile: .desktopAdvanced,
                baseStemPackage: basePackage,
                modelStatuses: [
                    ModelCatalog.drumsep.id: .installed(drumPackage)
                ]
            )
        )
        XCTAssertEqual(refiners.map(\.identifier), ["drumsep-onnx-v1"])
        XCTAssertEqual(
            refiners.first?.outputStemIDs,
            [.drumKick, .drumSnare, .drumCymbals, .drumToms]
        )

        let empty = try await StemRefinementEngineFactory.production.engines(
            for: StemRefinementEngineFactory.Context(
                capabilityProfile: .profile(for: .desktop),
                baseStemPackage: basePackage,
                modelStatuses: [
                    ModelCatalog.drumsep.id: .installed(drumPackage)
                ]
            )
        )
        XCTAssertTrue(empty.isEmpty)
    }

    private func installFakeDrumsepPackage(in modelDirectory: URL) throws -> InstalledModelPackage {
        let packageDirectory =
            modelDirectory
            .appendingPathComponent(ModelCatalog.drumsep.id, isDirectory: true)
            .appendingPathComponent(ModelCatalog.drumsep.version, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageDirectory, withIntermediateDirectories: true)
        let modelURL = packageDirectory.appendingPathComponent("drumsep.onnx")
        let payload = Data("fake drumsep onnx".utf8)
        try payload.write(to: modelURL)
        let manifest = """
            {"files":[{"relativePath":"drumsep.onnx","sizeBytes":\(payload.count),"sha256":"\(sha256Hex(payload))"}]}
            """
        try Data(manifest.utf8).write(
            to: packageDirectory.appendingPathComponent(".installation-manifest.json")
        )
        return InstalledModelPackage(
            descriptorID: ModelCatalog.drumsep.id,
            version: ModelCatalog.drumsep.version,
            packageDirectoryURL: packageDirectory,
            entryPointURL: modelURL,
            sizeBytes: Int64(payload.count)
        )
    }

    private func installFakeHTDemucsPackage(in modelDirectory: URL) throws -> InstalledModelPackage
    {
        let packageDirectory =
            modelDirectory
            .appendingPathComponent(ModelCatalog.htdemucs.id, isDirectory: true)
            .appendingPathComponent(ModelCatalog.htdemucs.version, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageDirectory, withIntermediateDirectories: true)
        let modelURL = packageDirectory.appendingPathComponent("demucsv4.onnx")
        let payload = Data("fake onnx".utf8)
        try payload.write(to: modelURL)
        let manifest = """
            {"files":[{"relativePath":"demucsv4.onnx","sizeBytes":\(payload.count),"sha256":"\(sha256Hex(payload))"}]}
            """
        try Data(manifest.utf8).write(
            to: packageDirectory.appendingPathComponent(".installation-manifest.json")
        )
        return InstalledModelPackage(
            descriptorID: ModelCatalog.htdemucs.id,
            version: ModelCatalog.htdemucs.version,
            packageDirectoryURL: packageDirectory,
            entryPointURL: modelURL,
            sizeBytes: Int64(payload.count)
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private actor StemRefinementFactoryRecorder {
    private let engines: [any StemRefinementEngine]
    private var observedContexts: [StemRefinementEngineFactory.Context] = []

    init(engines: [any StemRefinementEngine]) {
        self.engines = engines
    }

    func makeEngines(
        context: StemRefinementEngineFactory.Context
    ) -> [any StemRefinementEngine] {
        observedContexts.append(context)
        return engines
    }

    func contexts() -> [StemRefinementEngineFactory.Context] {
        observedContexts
    }
}

private struct FactoryRefiner: StemRefinementEngine {
    let identifier: String
    let outputStemIDs: [StemID] = [.drumKick]

    func refine(request: StemRefinementRequest) async throws -> StemRefinementResult {
        throw CancellationError()
    }
}

private struct EmptyModelDownloader: ModelArtifactDownloading {
    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        throw CancellationError()
    }
}
