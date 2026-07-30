import Foundation
import XCTest

@testable import SongWorkbench

final class StemSeparationTests: XCTestCase {
    func testProgressFractionIsNormalized() {
        XCTAssertEqual(progress(completed: -1, total: 10).fractionCompleted, 0)
        XCTAssertEqual(progress(completed: 5, total: 10).fractionCompleted, 0.5)
        XCTAssertEqual(progress(completed: 20, total: 10).fractionCompleted, 1)
        XCTAssertEqual(progress(completed: 0, total: 0).fractionCompleted, 0)
    }

    func testLegacyStemFilesRemainValidAndSixSourceFilesExposeNewTracks() {
        let root = URL(fileURLWithPath: "/tmp/stems")
        let files = StemFiles(
            vocals: root.appendingPathComponent("vocals.wav"),
            drums: root.appendingPathComponent("drums.wav"),
            bass: root.appendingPathComponent("bass.wav"),
            other: root.appendingPathComponent("other.wav")
        )

        XCTAssertEqual(files.availableKinds, StemKind.legacyRequired)
        XCTAssertFalse(files.isSixSource)

        let sixSource = StemFiles(
            vocals: files.vocals,
            drums: files.drums,
            bass: files.bass,
            guitar: root.appendingPathComponent("guitar.wav"),
            piano: root.appendingPathComponent("piano.wav"),
            other: files.other
        )
        XCTAssertEqual(sixSource.availableKinds, StemKind.allCases)
        XCTAssertTrue(sixSource.isSixSource)
    }

    func testLegacyStemFilesCreateStemSetManifest() {
        let root = URL(fileURLWithPath: "/tmp/stems")
        let files = StemFiles(
            vocals: root.appendingPathComponent("vocals.wav"),
            drums: root.appendingPathComponent("drums.wav"),
            bass: root.appendingPathComponent("bass.wav"),
            guitar: root.appendingPathComponent("guitar.wav"),
            piano: root.appendingPathComponent("piano.wav"),
            other: root.appendingPathComponent("other.wav")
        )

        let manifest = files.stemSetManifest

        XCTAssertEqual(manifest.descriptors.map(\.id), StemKind.allCases.map(\.id))
        XCTAssertEqual(Set(manifest.assets.map(\.id)), Set(StemKind.allCases.map(\.id)))
        XCTAssertNil(manifest.descriptors.first?.parentID)
    }

    func testStemMixGraphActiveFrontierExcludesParentWhenChildrenHaveAudio() {
        let root = URL(fileURLWithPath: "/tmp/stems")
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.drums.id, role: .source, displayName: "Drums", order: 1),
                StemDescriptor(
                    id: .drumKick,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Kick",
                    order: 2
                ),
                StemDescriptor(
                    id: .drumSnare,
                    parentID: StemKind.drums.id,
                    role: .refinement,
                    displayName: "Snare",
                    order: 3
                ),
                StemDescriptor(id: StemKind.bass.id, role: .source, displayName: "Bass", order: 4),
            ],
            assets: [
                StemAsset(
                    id: StemKind.drums.id,
                    audioURL: root.appendingPathComponent("drums.wav"),
                    producerID: "base"
                ),
                StemAsset(
                    id: .drumKick,
                    audioURL: root.appendingPathComponent("kick.wav"),
                    producerID: "drum-refiner"
                ),
                StemAsset(
                    id: .drumSnare,
                    audioURL: root.appendingPathComponent("snare.wav"),
                    producerID: "drum-refiner"
                ),
                StemAsset(
                    id: StemKind.bass.id,
                    audioURL: root.appendingPathComponent("bass.wav"),
                    producerID: "base"
                ),
            ]
        )

        XCTAssertEqual(
            StemMixGraph(manifest: manifest).activeNodes.map(\.id),
            [
                .drumKick, .drumSnare, StemKind.bass.id,
            ])
    }

    func testStoredStemSetManifestRoundTripsUnknownChildren() throws {
        let root = URL(fileURLWithPath: "/tmp/stems")
        let childID: StemID = "guitar.lead.double"
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.guitar.id, role: .source, displayName: "Guitar", order: 1),
                StemDescriptor(
                    id: childID,
                    parentID: StemKind.guitar.id,
                    role: .refinement,
                    displayName: "Lead Double",
                    order: 2
                ),
            ],
            assets: [
                StemAsset(
                    id: StemKind.guitar.id,
                    audioURL: root.appendingPathComponent("guitar.wav"),
                    producerID: "base"
                ),
                StemAsset(
                    id: childID,
                    audioURL: root.appendingPathComponent("lead-double.wav"),
                    producerID: "future-refiner"
                ),
            ]
        )

        let data = try JSONEncoder().encode(StoredStemSetManifest(manifest: manifest))
        let decoded = try JSONDecoder().decode(StoredStemSetManifest.self, from: data).resolved()

        XCTAssertEqual(decoded.descriptors.map(\.id), [StemKind.guitar.id, childID])
        XCTAssertEqual(decoded.assets.map(\.id), [StemKind.guitar.id, childID])
    }

    func testRefinementPipelineAddsChildrenAndRecipeIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = DeferredStemEngineStub()
        let refiner = StubStemRefiner(
            identifier: "drum-piece-test",
            outputStemIDs: [.drumKick, .drumSnare]
        )
        let engine = StemRefinementPipelineEngine(
            baseEngine: base,
            refiners: [refiner],
            sourceDigest: "source-digest",
            segmentConfiguration: "six-stem-test"
        )

        let result = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: root.appendingPathComponent("source.wav"),
                outputDirectory: root.appendingPathComponent("stems", isDirectory: true)
            )
        ) { _ in }

        XCTAssertEqual(result.stems.availableKinds, StemKind.allCases)
        XCTAssertEqual(result.stemSet.recipeIdentity?.sourceDigest, "source-digest")
        XCTAssertEqual(result.stemSet.recipeIdentity?.refiners, ["drum-piece-test"])
        XCTAssertEqual(result.stemSet.descriptorsByID[.drumKick]?.parentID, StemKind.drums.id)
        XCTAssertEqual(result.stemSet.descriptorsByID[.drumSnare]?.parentID, StemKind.drums.id)
        XCTAssertEqual(
            StemMixGraph(manifest: result.stemSet).activeNodes.map(\.id),
            [
                StemKind.vocals.id,
                StemKind.bass.id,
                StemKind.guitar.id,
                StemKind.piano.id,
                StemKind.other.id,
                .drumKick,
                .drumSnare,
            ])
    }

    func testRefinementPipelineFailsWhenRefinerOmitsExpectedAsset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = StemRefinementPipelineEngine(
            baseEngine: DeferredStemEngineStub(),
            refiners: [
                StubStemRefiner(
                    identifier: "bad-refiner",
                    outputStemIDs: [.drumKick],
                    producedStemIDs: []
                )
            ],
            sourceDigest: "source-digest"
        )

        do {
            _ = try await engine.separate(
                request: StemSeparationRequest(
                    inputURL: root.appendingPathComponent("source.wav"),
                    outputDirectory: root.appendingPathComponent("stems", isDirectory: true)
                )
            ) { _ in }
            XCTFail("Expected missing asset failure")
        } catch StemRefinementError.missingProducedAsset(let id) {
            XCTAssertEqual(id, .drumKick)
        }
    }

    func testNativeRefinementEngineRunsAgainstParentStemAndMapsModelOutputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drumsURL = root.appendingPathComponent("drums.wav")
        try Data("drums".utf8).write(to: drumsURL)
        let model = RecordingNativeStemEngine()
        let engine = NativeStemRefinementEngine(
            identifier: "native-drum-pieces",
            parentStemID: StemKind.drums.id,
            outputs: [
                NativeStemRefinementOutput(
                    modelOutputID: StemKind.drums.id,
                    id: .drumKick,
                    displayName: "Kick",
                    order: 100
                ),
                NativeStemRefinementOutput(
                    modelOutputID: StemKind.other.id,
                    id: .drumSnare,
                    displayName: "Snare",
                    order: 101
                ),
            ],
            engine: model
        )
        let manifest = StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.drums.id,
                    role: .source,
                    displayName: "Drums",
                    order: 1
                )
            ],
            assets: [
                StemAsset(id: StemKind.drums.id, audioURL: drumsURL, producerID: "base")
            ]
        )

        let result = try await engine.refine(
            request: StemRefinementRequest(
                inputURL: root.appendingPathComponent("source.wav"),
                outputDirectory: root.appendingPathComponent("refined", isDirectory: true),
                sourceDigest: "digest",
                manifest: manifest
            )
        )

        let recordedInputURL = await model.lastInputURL()
        XCTAssertEqual(recordedInputURL, drumsURL)
        XCTAssertEqual(result.descriptors.map(\.id), [.drumKick, .drumSnare])
        XCTAssertEqual(result.descriptors.map(\.parentID), [StemKind.drums.id, StemKind.drums.id])
        XCTAssertEqual(
            result.assets.map(\.producerID), ["native-drum-pieces", "native-drum-pieces"])
        XCTAssertTrue(engine.cacheIdentity.contains("native-test-model"))
        XCTAssertTrue(engine.cacheIdentity.contains("model-v2"))
    }

    func testNativeRefinementEngineRejectsMissingParentStem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let engine = NativeStemRefinementEngine(
            identifier: "native-vocal-parts",
            parentStemID: StemKind.vocals.id,
            outputs: [],
            engine: RecordingNativeStemEngine()
        )

        do {
            _ = try await engine.refine(
                request: StemRefinementRequest(
                    inputURL: root.appendingPathComponent("source.wav"),
                    outputDirectory: root.appendingPathComponent("refined", isDirectory: true),
                    sourceDigest: "digest",
                    manifest: StemSetManifest(descriptors: [], assets: [])
                )
            )
            XCTFail("Expected missing parent stem failure")
        } catch StemRefinementError.missingParentStem(let id) {
            XCTAssertEqual(id, StemKind.vocals.id)
        }
    }

    func testExternalRefinementEngineRunsCommandAndParsesRelativeManifestAssets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputDirectory = root.appendingPathComponent("external", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.wav")
        try Data("source".utf8).write(to: sourceURL)
        let runner = RecordingExternalStemRefinementRunner(
            tracks: [
                ExternalStemRefinementManifest.Track(
                    id: .drumKick,
                    parentID: StemKind.drums.id,
                    displayName: "Kick",
                    order: 100,
                    audioPath: "kick.wav"
                )
            ]
        )
        let engine = ExternalStemRefinementEngine(
            identifier: "external-drum-test",
            outputStemIDs: [.drumKick],
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            runner: runner
        )

        let result = try await engine.refine(
            request: StemRefinementRequest(
                inputURL: sourceURL,
                outputDirectory: outputDirectory,
                sourceDigest: "digest-123",
                manifest: StemFiles(
                    vocals: root.appendingPathComponent("vocals.wav"),
                    drums: root.appendingPathComponent("drums.wav"),
                    bass: root.appendingPathComponent("bass.wav"),
                    guitar: root.appendingPathComponent("guitar.wav"),
                    piano: root.appendingPathComponent("piano.wav"),
                    other: root.appendingPathComponent("other.wav")
                ).stemSetManifest
            )
        )

        XCTAssertEqual(result.descriptors.first?.id, .drumKick)
        XCTAssertEqual(result.descriptors.first?.parentID, StemKind.drums.id)
        XCTAssertEqual(
            result.assets.first?.audioURL,
            outputDirectory.appendingPathComponent("kick.wav")
        )
        XCTAssertEqual(result.assets.first?.producerID, "external-drum-test")
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.first?.executableURL.path, "/usr/bin/false")
        XCTAssertTrue(invocations.first?.arguments.contains("digest-123") == true)
        let requestManifestURL = outputDirectory.appendingPathComponent(
            "stem-refinement-request.json"
        )
        let savedManifest = try JSONDecoder().decode(
            StemSetManifest.self,
            from: Data(contentsOf: requestManifestURL)
        )
        XCTAssertEqual(savedManifest.descriptorsByID[StemKind.drums.id]?.displayName, "Drums")
    }

    func testExternalRefinementEngineFailsWhenCommandDoesNotWriteManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputDirectory = root.appendingPathComponent("external", isDirectory: true)
        let engine = ExternalStemRefinementEngine(
            identifier: "external-empty",
            outputStemIDs: [.drumKick],
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: RecordingExternalStemRefinementRunner(tracks: nil)
        )

        do {
            _ = try await engine.refine(
                request: StemRefinementRequest(
                    inputURL: root.appendingPathComponent("source.wav"),
                    outputDirectory: outputDirectory,
                    sourceDigest: "digest",
                    manifest: StemSetManifest(descriptors: [], assets: [])
                )
            )
            XCTFail("Expected missing external manifest failure")
        } catch StemRefinementError.externalManifestMissing(let url) {
            XCTAssertEqual(url.lastPathComponent, "stem-refinement-result.json")
        }
    }

    func testExternalRefinementEnginePropagatesCommandFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ExternalStemRefinementEngine(
            identifier: "external-failing",
            outputStemIDs: [.drumKick],
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            runner: FailingExternalStemRefinementRunner()
        )

        do {
            _ = try await engine.refine(
                request: StemRefinementRequest(
                    inputURL: root.appendingPathComponent("source.wav"),
                    outputDirectory: root.appendingPathComponent("external", isDirectory: true),
                    sourceDigest: "digest",
                    manifest: StemSetManifest(descriptors: [], assets: [])
                )
            )
            XCTFail("Expected command failure")
        } catch StemRefinementError.externalCommandFailed(let status) {
            XCTAssertEqual(status, 42)
        }
    }

    func testDeferredEngineDoesNotConstructConcreteEngineForMetadataAccess() async {
        let recorder = DeferredStemEngineFactoryRecorder()
        let metadata = StemSeparationEngineMetadata(
            engineIdentifier: "deferred-test",
            engineVersion: "1",
            modelIdentifier: "large-model",
            modelVersion: "1"
        )
        let engine = DeferredStemSeparationEngine(metadata: metadata) {
            await recorder.makeEngine()
        }

        XCTAssertEqual(engine.metadata, metadata)
        let constructionCount = await recorder.constructionCount()
        XCTAssertEqual(constructionCount, 0)
    }

    func testDeferredEngineConstructsConcreteEngineOnlyWhenSeparationRuns() async throws {
        let recorder = DeferredStemEngineFactoryRecorder()
        let engine = DeferredStemSeparationEngine(
            metadata: StemSeparationEngineMetadata(
                engineIdentifier: "deferred-test",
                engineVersion: "1",
                modelIdentifier: "large-model",
                modelVersion: "1"
            )
        ) {
            await recorder.makeEngine()
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        _ = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: root.appendingPathComponent("source.wav"),
                outputDirectory: root.appendingPathComponent("stems", isDirectory: true)
            )
        ) { _ in }

        let constructionCount = await recorder.constructionCount()
        XCTAssertEqual(constructionCount, 1)
    }

    private func progress(completed: Int, total: Int) -> StemSeparationProgress {
        StemSeparationProgress(
            phase: .separating,
            completedUnits: completed,
            totalUnits: total
        )
    }
}

private actor RecordingExternalStemRefinementRunner: ExternalStemRefinementCommandRunning {
    private let tracks: [ExternalStemRefinementManifest.Track]?
    private var recordedInvocations: [ExternalStemRefinementCommandInvocation] = []

    init(tracks: [ExternalStemRefinementManifest.Track]?) {
        self.tracks = tracks
    }

    func run(_ invocation: ExternalStemRefinementCommandInvocation) async throws {
        recordedInvocations.append(invocation)
        guard let tracks else { return }
        guard
            let responseIndex = invocation.arguments.firstIndex(of: "--response-manifest"),
            responseIndex + 1 < invocation.arguments.count,
            let outputIndex = invocation.arguments.firstIndex(of: "--output-dir"),
            outputIndex + 1 < invocation.arguments.count
        else {
            throw StemRefinementError.externalCommandFailed(2)
        }
        let outputDirectory = URL(fileURLWithPath: invocation.arguments[outputIndex + 1])
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        for track in tracks where !track.audioPath.hasPrefix("/") {
            try Data(track.id.rawValue.utf8).write(
                to: outputDirectory.appendingPathComponent(track.audioPath)
            )
        }
        let responseURL = URL(fileURLWithPath: invocation.arguments[responseIndex + 1])
        try JSONEncoder().encode(ExternalStemRefinementManifest(tracks: tracks)).write(
            to: responseURL,
            options: .atomic
        )
    }

    func invocations() -> [ExternalStemRefinementCommandInvocation] {
        recordedInvocations
    }
}

private struct FailingExternalStemRefinementRunner: ExternalStemRefinementCommandRunning {
    func run(_ invocation: ExternalStemRefinementCommandInvocation) async throws {
        throw StemRefinementError.externalCommandFailed(42)
    }
}

private actor RecordingNativeStemEngine: StemSeparationEngine {
    nonisolated let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "native-test-model",
        engineVersion: "1",
        modelIdentifier: "drum-pieces",
        modelVersion: "model-v2"
    )
    private var inputURL: URL?

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        inputURL = request.inputURL
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let files = StemFiles(
            vocals: request.outputDirectory.appendingPathComponent("vocals.wav"),
            drums: request.outputDirectory.appendingPathComponent("drums.wav"),
            bass: request.outputDirectory.appendingPathComponent("bass.wav"),
            guitar: request.outputDirectory.appendingPathComponent("guitar.wav"),
            piano: request.outputDirectory.appendingPathComponent("piano.wav"),
            other: request.outputDirectory.appendingPathComponent("other.wav")
        )
        for url in files.availableKinds.compactMap({ files[$0] }) {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        return StemSeparationResult(stems: files, processingDuration: .zero)
    }

    func lastInputURL() -> URL? {
        inputURL
    }
}

private actor DeferredStemEngineFactoryRecorder {
    private var constructions = 0

    func makeEngine() -> any StemSeparationEngine {
        constructions += 1
        return DeferredStemEngineStub()
    }

    func constructionCount() -> Int {
        constructions
    }
}

private struct DeferredStemEngineStub: StemSeparationEngine {
    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        let root = request.outputDirectory
        return StemSeparationResult(
            stems: StemFiles(
                vocals: root.appendingPathComponent("vocals.wav"),
                drums: root.appendingPathComponent("drums.wav"),
                bass: root.appendingPathComponent("bass.wav"),
                guitar: root.appendingPathComponent("guitar.wav"),
                piano: root.appendingPathComponent("piano.wav"),
                other: root.appendingPathComponent("other.wav")
            ),
            processingDuration: .zero
        )
    }
}

private struct StubStemRefiner: StemRefinementEngine {
    let identifier: String
    let outputStemIDs: [StemID]
    var producedStemIDs: [StemID]?

    func refine(request: StemRefinementRequest) async throws -> StemRefinementResult {
        guard request.manifest.assetsByID[StemKind.drums.id] != nil else {
            throw StemRefinementError.missingParentStem(StemKind.drums.id)
        }
        let ids = producedStemIDs ?? outputStemIDs
        let descriptors = ids.enumerated().map { offset, id in
            StemDescriptor(
                id: id,
                parentID: StemKind.drums.id,
                role: .refinement,
                displayName: id.rawValue,
                order: 100 + offset
            )
        }
        let assets = ids.map { id in
            let url = request.outputDirectory.appendingPathComponent("\(id.rawValue).wav")
            try? Data(id.rawValue.utf8).write(to: url)
            return StemAsset(
                id: id,
                audioURL: url,
                producerID: identifier
            )
        }
        return StemRefinementResult(descriptors: descriptors, assets: assets)
    }
}
