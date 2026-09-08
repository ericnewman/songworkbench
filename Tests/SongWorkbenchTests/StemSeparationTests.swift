import AVFoundation
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

    func testONNXThreadCountDefaultsLeaveHeadroomAndCanBeOverridden() {
        #if os(macOS)
            XCTAssertEqual(
                ONNXSixStemChunkPredictor.resolvedIntraOpThreadCount(
                    activeProcessorCount: 12,
                    environment: [:],
                    userDefaultValue: nil
                ),
                6
            )
        #else
            XCTAssertEqual(
                ONNXSixStemChunkPredictor.resolvedIntraOpThreadCount(
                    activeProcessorCount: 8,
                    environment: [:],
                    userDefaultValue: nil
                ),
                4
            )
        #endif
        XCTAssertEqual(
            ONNXSixStemChunkPredictor.resolvedIntraOpThreadCount(
                activeProcessorCount: 12,
                environment: [ONNXSixStemChunkPredictor.threadCountEnvironmentKey: "3"],
                userDefaultValue: 5
            ),
            3
        )
        XCTAssertEqual(
            ONNXSixStemChunkPredictor.resolvedIntraOpThreadCount(
                activeProcessorCount: 4,
                environment: [ONNXSixStemChunkPredictor.threadCountEnvironmentKey: "99"],
                userDefaultValue: nil
            ),
            3
        )
        XCTAssertEqual(
            ONNXSixStemChunkPredictor.resolvedIntraOpThreadCount(
                activeProcessorCount: 8,
                environment: [:],
                userDefaultValue: 2
            ),
            2
        )
    }

    func testKaraokeThreadCountDefaultsToLowerCapAndCanBeOverridden() {
        // macOS caps at the performance-core count (8): measured 1.53x faster than 4 on a 3:36
        // song. iOS stays at 4 for thermals and the smaller memory budget.
        #if os(macOS)
            let defaultCap: Int32 = 8
        #else
            let defaultCap: Int32 = 4
        #endif
        XCTAssertEqual(
            ONNXKaraokeChunkPredictor.resolvedIntraOpThreadCount(
                activeProcessorCount: 12,
                environment: [:],
                userDefaultValue: nil
            ),
            defaultCap
        )
        XCTAssertEqual(
            ONNXKaraokeChunkPredictor.resolvedIntraOpThreadCount(
                activeProcessorCount: 12,
                environment: [ONNXKaraokeChunkPredictor.threadCountEnvironmentKey: "2"],
                userDefaultValue: 5
            ),
            2
        )
        XCTAssertEqual(
            ONNXKaraokeChunkPredictor.resolvedIntraOpThreadCount(
                activeProcessorCount: 4,
                environment: [ONNXKaraokeChunkPredictor.threadCountEnvironmentKey: "99"],
                userDefaultValue: nil
            ),
            3
        )
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

    func testVocalSplitGateRejectsGhostLeadAndParentCopyBacking() {
        // Eight Miles High karaoke outputs: lead energy 0.5% of parent, backing 97.6%.
        XCTAssertFalse(
            VocalSplitQualityGate.keepsChildren(
                leadParentEnergyRatio: 0.005,
                backingParentEnergyRatio: 0.976
            ))
        XCTAssertFalse(
            VocalSplitQualityGate.keepsChildren(
                leadParentEnergyRatio: 0.93,
                backingParentEnergyRatio: 0.02
            ))
    }

    func testVocalSplitGateKeepsARealEnergySplit() {
        XCTAssertTrue(
            VocalSplitQualityGate.keepsChildren(
                leadParentEnergyRatio: 0.28,
                backingParentEnergyRatio: 0.72
            ))
        XCTAssertTrue(
            VocalSplitQualityGate.keepsChildren(
                leadParentEnergyRatio: 0.946,
                backingParentEnergyRatio: 0.100
            ))
    }

    func testMDXKaraokeSpectrogramMatchesPythonPackingAndRoundtrips() throws {
        let chunk = MDXNetKaraokeSpectrogram.chunkSamples
        let left = (0..<chunk).map { index -> Float in
            0.2 * sin(2 * Float.pi * 440 * Float(index) / 44_100)
        }
        let right = (0..<chunk).map { index -> Float in
            0.1 * sin(2 * Float.pi * 660 * Float(index) / 44_100)
        }
        let packed = try MDXNetKaraokeSpectrogram.pack(left: left, right: right)
        XCTAssertEqual(packed.count, MDXNetKaraokeSpectrogram.packedFloatCount)
        let t0 = packed[MDXNetKaraokeSpectrogram.index(pair: 0, freq: 0, time: 0)]
        XCTAssertEqual(t0, 3.189303, accuracy: 0.002)
        let recon = try MDXNetKaraokeSpectrogram.unpack(packed)
        var err: Float = 0
        var energy: Float = 0
        for i in 0..<chunk {
            let d = recon[0][i] - left[i]
            err += d * d
            energy += left[i] * left[i]
        }
        XCTAssertGreaterThan(energy, 0)
        XCTAssertLessThan(err / energy, 1e-4)
    }

    func testKaraokeRefinerSeparatesTheOriginalMixThenSubtractsLeadFromVocals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mixURL = root.appendingPathComponent("mix.wav")
        let vocalsURL = root.appendingPathComponent("vocals.wav")
        try writeConstantWAV(to: mixURL, value: 0.5, frames: 2_048)
        try writeConstantWAV(to: vocalsURL, value: 0.4, frames: 2_048)
        let engine = MixRecordingStemEngine()
        let refiner = KaraokeVocalRefinementEngine(
            identifier: "karaoke-test",
            engine: engine
        )
        let result = try await refiner.refine(
            request: StemRefinementRequest(
                inputURL: mixURL,
                outputDirectory: root.appendingPathComponent("refined", isDirectory: true),
                sourceDigest: "digest",
                manifest: StemSetManifest(
                    descriptors: [
                        StemDescriptor(
                            id: StemKind.vocals.id,
                            role: .source,
                            displayName: "Vocals",
                            order: 0
                        )
                    ],
                    assets: [
                        StemAsset(
                            id: StemKind.vocals.id, audioURL: vocalsURL, producerID: "base")
                    ]
                )
            )
        )
        let recordedInputURL = await engine.lastInputURL()
        XCTAssertEqual(recordedInputURL?.lastPathComponent, "mix.wav")
        XCTAssertEqual(result.descriptors.map(\.id), [.vocalLead, .vocalBacking])
        let backing = try KaraokeBackingResidual.loadStereo(
            result.assets.first { $0.id == .vocalBacking }!.audioURL)
        XCTAssertEqual(backing[0][0], 0.4 - 0.25, accuracy: 0.0001)
    }

    func testVocalSplitGateCollapsesFailedChildrenOffThePlayingFrontier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parentURL = root.appendingPathComponent("vocals.wav")
        let leadURL = root.appendingPathComponent("lead.wav")
        let backingURL = root.appendingPathComponent("backing.wav")
        try writeConstantWAV(to: parentURL, value: 1.0, frames: 2_048)
        try writeConstantWAV(to: leadURL, value: 0.05, frames: 2_048)
        try writeConstantWAV(to: backingURL, value: 0.99, frames: 2_048)

        let collapsed = VocalSplitQualityGate.collapsingFailedSplit(
            in: vocalManifest(parent: parentURL, lead: leadURL, backing: backingURL)
        )
        XCTAssertEqual(collapsed.descriptors.map(\.id), [StemKind.vocals.id])
        XCTAssertEqual(collapsed.assets.map(\.id), [StemKind.vocals.id])
        XCTAssertEqual(
            StemMixGraph(manifest: collapsed).activeNodes.map(\.id),
            [StemKind.vocals.id]
        )
    }

    func testVocalSplitGateKeepsAudibleLeadAndBacking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parentURL = root.appendingPathComponent("vocals.wav")
        let leadURL = root.appendingPathComponent("lead.wav")
        let backingURL = root.appendingPathComponent("backing.wav")
        try writeConstantWAV(to: parentURL, value: 1.0, frames: 2_048)
        try writeConstantWAV(to: leadURL, value: 0.5, frames: 2_048)
        try writeConstantWAV(to: backingURL, value: 0.4, frames: 2_048)

        let kept = VocalSplitQualityGate.collapsingFailedSplit(
            in: vocalManifest(parent: parentURL, lead: leadURL, backing: backingURL)
        )
        XCTAssertEqual(
            Set(kept.descriptors.map(\.id)),
            [StemKind.vocals.id, .vocalLead, .vocalBacking]
        )
    }

    func testVocalSplitGateLeavesDrumChildrenAndUnreadablePlaceholdersAlone() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vocalsURL = root.appendingPathComponent("vocals.wav")
        let leadURL = root.appendingPathComponent("lead.wav")
        let backingURL = root.appendingPathComponent("backing.wav")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data("not-audio".utf8).write(to: vocalsURL)
        try? Data("not-audio".utf8).write(to: leadURL)
        try? Data("not-audio".utf8).write(to: backingURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = vocalManifest(parent: vocalsURL, lead: leadURL, backing: backingURL)
        let unchanged = VocalSplitQualityGate.collapsingFailedSplit(in: manifest)
        XCTAssertEqual(unchanged.descriptors.map(\.id), manifest.descriptors.map(\.id))
        XCTAssertEqual(unchanged.assets.map(\.id), manifest.assets.map(\.id))
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

    func testRefinementPipelineReportsWholeCascadeDuration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = StemRefinementPipelineEngine(
            baseEngine: DeferredStemEngineStub(processingDuration: .seconds(123)),
            refiners: [
                StubStemRefiner(
                    identifier: "timed-refiner",
                    outputStemIDs: [.drumKick],
                    delayNanoseconds: 1_000_000
                )
            ],
            sourceDigest: "source-digest"
        )

        let result = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: root.appendingPathComponent("source.wav"),
                outputDirectory: root.appendingPathComponent("stems", isDirectory: true)
            )
        ) { _ in }

        XCTAssertNotEqual(result.processingDuration, .seconds(123))
        XCTAssertGreaterThan(result.processingDuration, .zero)
    }

    func testRefinementPipelineReservesProgressForRefiners() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = StemSeparationProgressRecorder()
        let engine = StemRefinementPipelineEngine(
            baseEngine: DeferredStemEngineStub(),
            refiners: [
                StubStemRefiner(
                    identifier: "progress-refiner",
                    outputStemIDs: [.drumKick]
                )
            ],
            sourceDigest: "source-digest"
        )

        _ = try await engine.separate(
            request: StemSeparationRequest(
                inputURL: root.appendingPathComponent("source.wav"),
                outputDirectory: root.appendingPathComponent("stems", isDirectory: true)
            ),
            progress: { recorder.record($0) }
        )

        let values = recorder.values()
        XCTAssertTrue(
            values.contains(
                StemSeparationProgress(
                    phase: .writingOutputs,
                    completedUnits: 700,
                    totalUnits: 1_000
                )))
        XCTAssertTrue(
            values.contains(
                StemSeparationProgress(
                    phase: .refining,
                    completedUnits: 850,
                    totalUnits: 1_000
                )))
        XCTAssertEqual(
            values.last,
            StemSeparationProgress(
                phase: .writingOutputs,
                completedUnits: 1_000,
                totalUnits: 1_000
            ))
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

    func testNativeRefinementEngineForwardsModelProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vocalsURL = root.appendingPathComponent("vocals.wav")
        try Data("vocals".utf8).write(to: vocalsURL)
        let model = RecordingNativeStemEngine()
        let engine = NativeStemRefinementEngine(
            identifier: "native-vocal-parts",
            parentStemID: StemKind.vocals.id,
            outputs: [
                NativeStemRefinementOutput(
                    modelOutputID: StemKind.vocals.id,
                    id: .vocalLead,
                    displayName: "Lead",
                    order: 100
                )
            ],
            engine: model
        )
        let recorder = StemSeparationProgressRecorder()

        _ = try await engine.refine(
            request: StemRefinementRequest(
                inputURL: root.appendingPathComponent("source.wav"),
                outputDirectory: root.appendingPathComponent("refined", isDirectory: true),
                sourceDigest: "digest",
                manifest: StemSetManifest(
                    descriptors: [
                        StemDescriptor(
                            id: StemKind.vocals.id,
                            role: .source,
                            displayName: "Vocals",
                            order: 0
                        )
                    ],
                    assets: [
                        StemAsset(id: StemKind.vocals.id, audioURL: vocalsURL, producerID: "base")
                    ]
                )
            ),
            progress: { recorder.record($0) }
        )

        XCTAssertTrue(recorder.values().contains(progress(completed: 2, total: 4)))
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

/// Writes a constant lead WAV so karaoke residual math can be asserted.
private actor MixRecordingStemEngine: StemSeparationEngine {
    nonisolated let metadata = StemSeparationEngineMetadata(
        engineIdentifier: "mix-test-model",
        engineVersion: "1",
        modelIdentifier: "kara-test",
        modelVersion: "1"
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
        let vocalsURL = request.outputDirectory.appendingPathComponent("vocals.wav")
        let otherURL = request.outputDirectory.appendingPathComponent("other.wav")
        try Self.writeConstantWAV(to: vocalsURL, value: 0.25, frames: 2_048)
        try Self.writeConstantWAV(to: otherURL, value: 0.1, frames: 2_048)
        return StemSeparationResult(
            stems: StemFiles(
                vocals: vocalsURL,
                drums: request.outputDirectory.appendingPathComponent("drums.wav"),
                bass: request.outputDirectory.appendingPathComponent("bass.wav"),
                guitar: request.outputDirectory.appendingPathComponent("guitar.wav"),
                piano: request.outputDirectory.appendingPathComponent("piano.wav"),
                other: otherURL
            ),
            processingDuration: .zero
        )
    }

    func lastInputURL() -> URL? { inputURL }

    private static func writeConstantWAV(
        to url: URL,
        value: Float,
        frames: AVAudioFrameCount
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = value
        }
        try file.write(from: buffer)
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
        progress(
            StemSeparationProgress(
                phase: .separating,
                completedUnits: 2,
                totalUnits: 4
            ))
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
    var processingDuration: Duration = .zero

    func separate(
        request: StemSeparationRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemSeparationResult {
        let root = request.outputDirectory
        progress(
            StemSeparationProgress(
                phase: .writingOutputs,
                completedUnits: 1,
                totalUnits: 1
            ))
        return StemSeparationResult(
            stems: StemFiles(
                vocals: root.appendingPathComponent("vocals.wav"),
                drums: root.appendingPathComponent("drums.wav"),
                bass: root.appendingPathComponent("bass.wav"),
                guitar: root.appendingPathComponent("guitar.wav"),
                piano: root.appendingPathComponent("piano.wav"),
                other: root.appendingPathComponent("other.wav")
            ),
            processingDuration: processingDuration
        )
    }
}

private final class StemSeparationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StemSeparationProgress] = []

    func record(_ value: StemSeparationProgress) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    func values() -> [StemSeparationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private struct StubStemRefiner: StemRefinementEngine {
    let identifier: String
    let outputStemIDs: [StemID]
    var producedStemIDs: [StemID]?
    var delayNanoseconds: UInt64 = 0

    func refine(
        request: StemRefinementRequest,
        progress: @escaping @Sendable (StemSeparationProgress) -> Void
    ) async throws -> StemRefinementResult {
        progress(
            StemSeparationProgress(
                phase: .separating,
                completedUnits: 1,
                totalUnits: 2
            ))
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
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

extension StemSeparationTests {
    fileprivate func vocalManifest(parent: URL, lead: URL, backing: URL) -> StemSetManifest {
        StemSetManifest(
            descriptors: [
                StemDescriptor(
                    id: StemKind.vocals.id,
                    role: .source,
                    displayName: "Vocals",
                    order: 0
                ),
                StemDescriptor(
                    id: .vocalLead,
                    parentID: StemKind.vocals.id,
                    role: .refinement,
                    displayName: "Lead Vocals",
                    order: 200
                ),
                StemDescriptor(
                    id: .vocalBacking,
                    parentID: StemKind.vocals.id,
                    role: .refinement,
                    displayName: "Backing Vocals",
                    order: 201
                ),
            ],
            assets: [
                StemAsset(id: StemKind.vocals.id, audioURL: parent, producerID: "base"),
                StemAsset(id: .vocalLead, audioURL: lead, producerID: "karaoke"),
                StemAsset(id: .vocalBacking, audioURL: backing, producerID: "karaoke"),
            ]
        )
    }

    fileprivate func writeConstantWAV(
        to url: URL,
        value: Float,
        frames: AVAudioFrameCount,
        sampleRate: Double = 44_100
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = value
        }
        try file.write(from: buffer)
    }
}
