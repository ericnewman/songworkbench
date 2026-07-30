import CryptoKit
import Darwin
import Foundation
import os

enum AnalysisResourceLog {
    private static let logger = Logger(
        subsystem: "com.local.SongWorkbench",
        category: "analysis-performance"
    )

    static func checkpoint(
        stage: String,
        event: String,
        startedAt: ContinuousClock.Instant? = nil
    ) {
        var fields = ["stage=\(stage)", "event=\(event)"]
        if let physicalFootprintBytes {
            fields.append(
                String(
                    format: "footprint_mb=%.1f",
                    Double(physicalFootprintBytes) / 1_048_576
                )
            )
        }
        if let startedAt {
            let duration = startedAt.duration(to: .now)
            let components = duration.components
            let seconds =
                Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            fields.append(String(format: "elapsed_s=%.2f", seconds))
        }
        logger.notice("\(fields.joined(separator: " "), privacy: .public)")
    }

    private static var physicalFootprintBytes: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

enum StemKind: String, CaseIterable, Codable, Sendable {
    case vocals
    case drums
    case bass
    case guitar
    case piano
    case other

    static let legacyRequired: [StemKind] = [.vocals, .drums, .bass, .other]
}

struct StemID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
    Comparable
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    init(_ kind: StemKind) {
        self.init(rawValue: kind.rawValue)
    }

    static let vocalLead: StemID = "vocals.lead"
    static let vocalBacking: StemID = "vocals.backing"
    static let drumKick: StemID = "drums.kick"
    static let drumSnare: StemID = "drums.snare"
    static let drumToms: StemID = "drums.toms"
    static let drumCymbals: StemID = "drums.cymbals"
    static let guitarLead: StemID = "guitar.lead"
    static let guitarRhythm: StemID = "guitar.rhythm"

    var legacyKind: StemKind? {
        StemKind(rawValue: rawValue)
    }

    static func < (lhs: StemID, rhs: StemID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum StemRole: String, Codable, Sendable {
    case source
    case refinement
    case transcription
    case residual
}

struct StemDescriptor: Codable, Equatable, Sendable {
    let id: StemID
    let parentID: StemID?
    let role: StemRole
    let displayName: String
    let order: Int

    init(
        id: StemID,
        parentID: StemID? = nil,
        role: StemRole,
        displayName: String,
        order: Int
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.displayName = displayName
        self.order = order
    }
}

struct StemAsset: Codable, Equatable, Sendable {
    let id: StemID
    let audioURL: URL
    let producerID: String
}

struct StemRecipeIdentity: Codable, Equatable, Sendable {
    let sourceDigest: String
    let baseEngine: StemSeparationEngineMetadata
    let segmentConfiguration: String
    let refiners: [String]
    let taxonomyVersion: Int
    let outputFormat: String

    init(
        sourceDigest: String,
        baseEngine: StemSeparationEngineMetadata,
        segmentConfiguration: String = "default",
        refiners: [String] = [],
        taxonomyVersion: Int = 1,
        outputFormat: String = "wav"
    ) {
        self.sourceDigest = sourceDigest
        self.baseEngine = baseEngine
        self.segmentConfiguration = segmentConfiguration
        self.refiners = refiners
        self.taxonomyVersion = taxonomyVersion
        self.outputFormat = outputFormat
    }

    var cacheKey: String {
        ([
            sourceDigest,
            baseEngine.engineIdentifier,
            baseEngine.engineVersion,
            baseEngine.modelIdentifier ?? "",
            baseEngine.modelVersion ?? "",
            segmentConfiguration,
            String(taxonomyVersion),
            outputFormat,
        ] + refiners)
        .joined(separator: "|")
    }

    var stableStorageName: String {
        SHA256Digest.hexString(for: cacheKey)
    }
}

struct StemSetManifest: Codable, Equatable, Sendable {
    let descriptors: [StemDescriptor]
    let assets: [StemAsset]
    let recipeIdentity: StemRecipeIdentity?

    init(
        descriptors: [StemDescriptor],
        assets: [StemAsset],
        recipeIdentity: StemRecipeIdentity? = nil
    ) {
        self.descriptors = descriptors
        self.assets = assets
        self.recipeIdentity = recipeIdentity
    }

    var assetsByID: [StemID: StemAsset] {
        Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    }

    var descriptorsByID: [StemID: StemDescriptor] {
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    static func mergingDescriptors(
        _ existing: [StemDescriptor],
        _ additions: [StemDescriptor]
    ) -> [StemDescriptor] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for descriptor in additions {
            byID[descriptor.id] = descriptor
        }
        return byID.values.sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
    }

    static func mergingAssets(_ existing: [StemAsset], _ additions: [StemAsset]) -> [StemAsset] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for asset in additions {
            byID[asset.id] = asset
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    static func legacy(
        from files: StemFiles,
        producerID: String = "legacy-six-source",
        recipeIdentity: StemRecipeIdentity? = nil
    ) -> StemSetManifest {
        let descriptors = files.availableKinds.enumerated().map { offset, kind in
            StemDescriptor(
                id: StemID(kind),
                role: .source,
                displayName: kind.displayName,
                order: offset
            )
        }
        let assets = files.availableKinds.compactMap { kind -> StemAsset? in
            guard let url = files[kind] else { return nil }
            return StemAsset(id: StemID(kind), audioURL: url, producerID: producerID)
        }
        return StemSetManifest(
            descriptors: descriptors,
            assets: assets,
            recipeIdentity: recipeIdentity
        )
    }
}

private enum SHA256Digest {
    static func hexString(for string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
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

    var stemSetManifest: StemSetManifest {
        StemSetManifest.legacy(from: self)
    }
}

extension StemKind {
    var id: StemID {
        StemID(self)
    }

    var displayName: String {
        switch self {
        case .vocals: "Vocals"
        case .drums: "Drums"
        case .bass: "Bass"
        case .guitar: "Guitar"
        case .piano: "Piano"
        case .other: "Other"
        }
    }
}

struct StemMixGraph: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        let id: StemID
        let parentID: StemID?
        let audioURL: URL
        let order: Int
    }

    let nodes: [Node]

    init(manifest: StemSetManifest) {
        let descriptorsByID = manifest.descriptorsByID
        nodes = manifest.assets.compactMap { asset in
            guard let descriptor = descriptorsByID[asset.id] else { return nil }
            return Node(
                id: descriptor.id,
                parentID: descriptor.parentID,
                audioURL: asset.audioURL,
                order: descriptor.order
            )
        }
    }

    var activeNodes: [Node] {
        let parentIDsWithChildren = Set(nodes.compactMap(\.parentID))
        return
            nodes
            .filter { node in !parentIDsWithChildren.contains(node.id) }
            .sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
            }
    }

    var activeAudioURLsByID: [StemID: URL] {
        Dictionary(uniqueKeysWithValues: activeNodes.map { ($0.id, $0.audioURL) })
    }
}

struct StemSeparationRequest: Equatable, Sendable {
    let inputURL: URL
    let outputDirectory: URL
}

struct StemSeparationResult: Equatable, Sendable {
    let stems: StemFiles
    let stemSet: StemSetManifest
    let processingDuration: Duration

    init(
        stems: StemFiles,
        stemSet: StemSetManifest? = nil,
        processingDuration: Duration
    ) {
        self.stems = stems
        self.stemSet = stemSet ?? stems.stemSetManifest
        self.processingDuration = processingDuration
    }
}

enum StemRefinementError: LocalizedError {
    case missingParentStem(StemID)
    case missingModelOutput(StemID)
    case missingProducedAsset(StemID)
    case externalCommandUnavailable
    case externalCommandFailed(Int32)
    case externalManifestMissing(URL)

    var errorDescription: String? {
        switch self {
        case .missingParentStem(let id):
            "Cannot refine missing parent stem \(id.rawValue)."
        case .missingModelOutput(let id):
            "Refinement model did not produce mapped output \(id.rawValue)."
        case .missingProducedAsset(let id):
            "Refiner did not produce expected stem \(id.rawValue)."
        case .externalCommandUnavailable:
            "External stem refinement commands are unavailable on this platform."
        case .externalCommandFailed(let status):
            "External stem refinement command failed with status \(status)."
        case .externalManifestMissing(let url):
            "External stem refinement manifest is missing at \(url.path)."
        }
    }
}

struct StemRefinementRequest: Sendable {
    let inputURL: URL
    let outputDirectory: URL
    let sourceDigest: String
    let manifest: StemSetManifest
}

struct StemRefinementResult: Equatable, Sendable {
    let descriptors: [StemDescriptor]
    let assets: [StemAsset]
}

protocol StemRefinementEngine: Sendable {
    var identifier: String { get }
    var cacheIdentity: String { get }
    var taxonomyVersion: Int { get }
    var outputStemIDs: [StemID] { get }

    func refine(request: StemRefinementRequest) async throws -> StemRefinementResult
}

extension StemRefinementEngine {
    var cacheIdentity: String { identifier }
    var taxonomyVersion: Int { 1 }
}

struct NativeStemRefinementOutput: Equatable, Sendable {
    let modelOutputID: StemID
    let id: StemID
    let displayName: String
    let order: Int
}

/// Adapts an in-process Swift separator into a hierarchical stem refiner.
///
/// The wrapped engine can use Core ML, ONNX Runtime, or another native Swift
/// implementation. It receives only the configured parent stem, and its model
/// outputs are mapped to stable child IDs in the shared stem taxonomy.
struct NativeStemRefinementEngine: StemRefinementEngine {
    let identifier: String
    let taxonomyVersion: Int
    let parentStemID: StemID
    let outputs: [NativeStemRefinementOutput]
    let engine: any StemSeparationEngine

    var outputStemIDs: [StemID] {
        outputs.map(\.id)
    }

    var cacheIdentity: String {
        let metadata = engine.metadata
        return [
            identifier,
            metadata.engineIdentifier,
            metadata.engineVersion,
            metadata.modelIdentifier ?? "",
            metadata.modelVersion ?? "",
        ].joined(separator: "@")
    }

    init(
        identifier: String,
        taxonomyVersion: Int = 1,
        parentStemID: StemID,
        outputs: [NativeStemRefinementOutput],
        engine: any StemSeparationEngine
    ) {
        self.identifier = identifier
        self.taxonomyVersion = taxonomyVersion
        self.parentStemID = parentStemID
        self.outputs = outputs
        self.engine = engine
    }

    func refine(request: StemRefinementRequest) async throws -> StemRefinementResult {
        guard let parentAsset = request.manifest.assetsByID[parentStemID] else {
            throw StemRefinementError.missingParentStem(parentStemID)
        }
        let modelOutputDirectory = request.outputDirectory.appendingPathComponent(
            "ModelOutputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelOutputDirectory,
            withIntermediateDirectories: true
        )
        let modelResult = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: parentAsset.audioURL,
                outputDirectory: modelOutputDirectory
            )
        ) { _ in }
        let modelAssets = modelResult.stemSet.assetsByID

        var descriptors: [StemDescriptor] = []
        var assets: [StemAsset] = []
        descriptors.reserveCapacity(outputs.count)
        assets.reserveCapacity(outputs.count)
        for output in outputs {
            guard let modelAsset = modelAssets[output.modelOutputID] else {
                throw StemRefinementError.missingModelOutput(output.modelOutputID)
            }
            descriptors.append(
                StemDescriptor(
                    id: output.id,
                    parentID: parentStemID,
                    role: .refinement,
                    displayName: output.displayName,
                    order: output.order
                )
            )
            assets.append(
                StemAsset(
                    id: output.id,
                    audioURL: modelAsset.audioURL,
                    producerID: identifier
                )
            )
        }
        return StemRefinementResult(descriptors: descriptors, assets: assets)
    }
}

struct ExternalStemRefinementCommandInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

protocol ExternalStemRefinementCommandRunning: Sendable {
    func run(_ invocation: ExternalStemRefinementCommandInvocation) async throws
}

struct ProcessExternalStemRefinementCommandRunner: ExternalStemRefinementCommandRunning {
    func run(_ invocation: ExternalStemRefinementCommandInvocation) async throws {
        #if os(macOS)
            let process = Process()
            process.executableURL = invocation.executableURL
            process.arguments = invocation.arguments
            if !invocation.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(
                    invocation.environment
                ) { _, new in new }
            }
            try process.run()
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw StemRefinementError.externalCommandFailed(process.terminationStatus)
            }
        #else
            throw StemRefinementError.externalCommandUnavailable
        #endif
    }
}

struct ExternalStemRefinementManifest: Codable, Equatable, Sendable {
    struct Track: Codable, Equatable, Sendable {
        let id: StemID
        let parentID: StemID?
        let role: StemRole
        let displayName: String
        let order: Int
        let audioPath: String
        let producerID: String?

        init(
            id: StemID,
            parentID: StemID? = nil,
            role: StemRole = .refinement,
            displayName: String,
            order: Int,
            audioPath: String,
            producerID: String? = nil
        ) {
            self.id = id
            self.parentID = parentID
            self.role = role
            self.displayName = displayName
            self.order = order
            self.audioPath = audioPath
            self.producerID = producerID
        }
    }

    let tracks: [Track]
}

struct ExternalStemRefinementEngine: StemRefinementEngine {
    let identifier: String
    let taxonomyVersion: Int
    let outputStemIDs: [StemID]
    let executableURL: URL
    let argumentTemplate: [String]
    let environment: [String: String]

    private let runner: any ExternalStemRefinementCommandRunning

    init(
        identifier: String,
        taxonomyVersion: Int = 1,
        outputStemIDs: [StemID],
        executableURL: URL,
        argumentTemplate: [String] = [
            "--input", "{input}",
            "--output-dir", "{outputDirectory}",
            "--source-digest", "{sourceDigest}",
            "--request-manifest", "{requestManifest}",
            "--response-manifest", "{responseManifest}",
        ],
        environment: [String: String] = [:],
        runner: any ExternalStemRefinementCommandRunning =
            ProcessExternalStemRefinementCommandRunner()
    ) {
        self.identifier = identifier
        self.taxonomyVersion = taxonomyVersion
        self.outputStemIDs = outputStemIDs
        self.executableURL = executableURL
        self.argumentTemplate = argumentTemplate
        self.environment = environment
        self.runner = runner
    }

    func refine(request: StemRefinementRequest) async throws -> StemRefinementResult {
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let requestManifestURL = request.outputDirectory.appendingPathComponent(
            "stem-refinement-request.json"
        )
        let responseManifestURL = request.outputDirectory.appendingPathComponent(
            "stem-refinement-result.json"
        )
        try JSONEncoder().encode(request.manifest).write(to: requestManifestURL, options: .atomic)
        let invocation = ExternalStemRefinementCommandInvocation(
            executableURL: executableURL,
            arguments: argumentTemplate.map {
                expand(
                    $0,
                    request: request,
                    requestManifestURL: requestManifestURL,
                    responseManifestURL: responseManifestURL
                )
            },
            environment: environment
        )
        try await runner.run(invocation)
        guard FileManager.default.fileExists(atPath: responseManifestURL.path) else {
            throw StemRefinementError.externalManifestMissing(responseManifestURL)
        }
        let externalManifest = try JSONDecoder().decode(
            ExternalStemRefinementManifest.self,
            from: Data(contentsOf: responseManifestURL)
        )
        return StemRefinementResult(
            descriptors: externalManifest.tracks.map {
                StemDescriptor(
                    id: $0.id,
                    parentID: $0.parentID,
                    role: $0.role,
                    displayName: $0.displayName,
                    order: $0.order
                )
            },
            assets: externalManifest.tracks.map {
                StemAsset(
                    id: $0.id,
                    audioURL: resolvedAudioURL($0.audioPath, relativeTo: request.outputDirectory),
                    producerID: $0.producerID ?? identifier
                )
            }
        )
    }

    private func expand(
        _ argument: String,
        request: StemRefinementRequest,
        requestManifestURL: URL,
        responseManifestURL: URL
    ) -> String {
        argument
            .replacingOccurrences(of: "{input}", with: request.inputURL.path)
            .replacingOccurrences(of: "{outputDirectory}", with: request.outputDirectory.path)
            .replacingOccurrences(of: "{sourceDigest}", with: request.sourceDigest)
            .replacingOccurrences(of: "{requestManifest}", with: requestManifestURL.path)
            .replacingOccurrences(of: "{responseManifest}", with: responseManifestURL.path)
    }

    private func resolvedAudioURL(_ path: String, relativeTo outputDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return outputDirectory.appendingPathComponent(path)
    }
}

struct StemRefinementPipelineEngine: StemSeparationEngine {
    let baseEngine: any StemSeparationEngine
    let refiners: [any StemRefinementEngine]
    let sourceDigest: String
    let segmentConfiguration: String
    let outputFormat: String

    var metadata: StemSeparationEngineMetadata {
        guard !refiners.isEmpty else { return baseEngine.metadata }
        return StemSeparationEngineMetadata(
            engineIdentifier: baseEngine.metadata.engineIdentifier + "+refiners",
            engineVersion: baseEngine.metadata.engineVersion,
            modelIdentifier: baseEngine.metadata.modelIdentifier,
            modelVersion: baseEngine.metadata.modelVersion
        )
    }

    init(
        baseEngine: any StemSeparationEngine,
        refiners: [any StemRefinementEngine],
        sourceDigest: String,
        segmentConfiguration: String = "default",
        outputFormat: String = "wav"
    ) {
        self.baseEngine = baseEngine
        self.refiners = refiners
        self.sourceDigest = sourceDigest
        self.segmentConfiguration = segmentConfiguration
        self.outputFormat = outputFormat
    }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        let baseResult = try await baseEngine.separate(request: request, progress: progress)
        guard !refiners.isEmpty else { return baseResult }

        var manifest = baseResult.stemSet
        var descriptors = manifest.descriptors
        var assets = manifest.assets
        let fileManager = FileManager.default
        let recipe = recipeIdentity
        let refinementRoot = request.outputDirectory
            .appendingPathComponent("Refined", isDirectory: true)
            .appendingPathComponent(recipe.stableStorageName, isDirectory: true)
        try fileManager.createDirectory(at: refinementRoot, withIntermediateDirectories: true)

        for (index, refiner) in refiners.enumerated() {
            try Task.checkCancellation()
            progress(
                StemSeparationProgress(
                    phase: .refining,
                    completedUnits: index,
                    totalUnits: refiners.count
                ))
            let outputDirectory = refinementRoot.appendingPathComponent(
                refiner.identifier,
                isDirectory: true
            )
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let result = try await refiner.refine(
                request: StemRefinementRequest(
                    inputURL: request.inputURL,
                    outputDirectory: outputDirectory,
                    sourceDigest: sourceDigest,
                    manifest: StemSetManifest(
                        descriptors: descriptors,
                        assets: assets,
                        recipeIdentity: recipe
                    )
                )
            )
            for expectedID in refiner.outputStemIDs {
                guard let asset = result.assets.first(where: { $0.id == expectedID }),
                    fileManager.fileExists(atPath: asset.audioURL.path)
                else {
                    throw StemRefinementError.missingProducedAsset(expectedID)
                }
            }
            descriptors = StemSetManifest.mergingDescriptors(descriptors, result.descriptors)
            assets = StemSetManifest.mergingAssets(assets, result.assets)
        }

        manifest = StemSetManifest(
            descriptors: descriptors,
            assets: assets,
            recipeIdentity: recipe
        )
        return StemSeparationResult(
            stems: baseResult.stems,
            stemSet: manifest,
            processingDuration: baseResult.processingDuration
        )
    }

    var recipeIdentity: StemRecipeIdentity {
        StemRecipeIdentity(
            sourceDigest: sourceDigest,
            baseEngine: baseEngine.metadata,
            segmentConfiguration: segmentConfiguration,
            refiners: refiners.map(\.cacheIdentity),
            taxonomyVersion: refiners.map(\.taxonomyVersion).max() ?? 1,
            outputFormat: outputFormat
        )
    }
}

struct StemSeparationEngineMetadata: Codable, Equatable, Sendable {
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
        case refining
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

/// Publishes model metadata without constructing the heavyweight separator until
/// an uncached separation actually starts. The concrete engine is intentionally
/// local to `separate`, so its inference session cannot remain resident through
/// later transcription-only runs or after a failed/cancelled separation.
actor DeferredStemSeparationEngine: StemSeparationEngine {
    nonisolated let metadata: StemSeparationEngineMetadata

    private let makeEngine: @Sendable () async throws -> any StemSeparationEngine

    init(
        metadata: StemSeparationEngineMetadata,
        makeEngine: @escaping @Sendable () async throws -> any StemSeparationEngine
    ) {
        self.metadata = metadata
        self.makeEngine = makeEngine
    }

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        let startedAt = ContinuousClock.now
        AnalysisResourceLog.checkpoint(stage: "separation-model", event: "load-start")
        do {
            let engine = try await makeEngine()
            AnalysisResourceLog.checkpoint(
                stage: "separation-model",
                event: "load-finished",
                startedAt: startedAt
            )
            let result = try await engine.separate(request: request, progress: progress)
            AnalysisResourceLog.checkpoint(
                stage: "separation-model",
                event: "released",
                startedAt: startedAt
            )
            return result
        } catch {
            AnalysisResourceLog.checkpoint(
                stage: "separation-model",
                event: "failed-or-cancelled",
                startedAt: startedAt
            )
            throw error
        }
    }
}
