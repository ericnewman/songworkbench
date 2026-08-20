import Foundation

/// Centralizes the "separation currency / cache-hit / staleness" rules that
/// decide whether previously separated stems are still usable.
///
/// Invariant: source recordings have their separation cache keyed by engine /
/// model identity; stems load (and a cache hit is honored) only when the saved
/// separation is *current* — i.e. produced by the same engine identity as the
/// engine in use today. The same identity check drives both AppModel's playback
/// gating and the pipeline's cache-hit guard so the two never diverge.
///
/// The policy is constructed with the *current* engine's metadata so callers
/// supply their own engine (AppModel uses ONNX CPU metadata; the pipeline uses
/// its injected stem engine's metadata) and tests can vary it freely.
struct SeparationCachingPolicy: Sendable {
    let currentEngine: StemSeparationEngineMetadata

    /// True when the record is a succeeded separation whose engine identity
    /// (engineIdentifier / engineVersion / modelIdentifier) matches the current
    /// engine. Mirrors AppModel.isCurrentSeparation. Does NOT check sourceDigest.
    func isCurrentEngine(_ record: AnalysisStageRecord?) -> Bool {
        guard
            record?.state == .succeeded,
            let provenance = record?.provenance
        else { return false }
        return provenance.matchesEngine(currentEngine)
    }

    /// True when the existing separation record may be reused as a cache hit:
    /// succeeded, source digest matches, engine identity matches, the stored
    /// stems are six-source, and every available stem file exists on disk.
    /// Mirrors the inline guard in SongAnalysisPipeline.runSeparation exactly.
    func isCacheHit(
        record: AnalysisStageRecord?,
        sourceDigest: String,
        storedStems: StoredStemFiles?
    ) -> Bool {
        guard
            let storedStems,
            let record,
            record.state == .succeeded,
            record.provenance?.sourceDigest == sourceDigest,
            record.provenance?.engineIdentifier == currentEngine.engineIdentifier,
            record.provenance?.engineVersion == currentEngine.engineVersion,
            record.provenance?.modelIdentifier == currentEngine.modelIdentifier,
            record.provenance?.modelVersion == currentEngine.modelVersion,
            storedStems.resolved().isSixSource,
            storedStems.resolved().availableKinds.allSatisfy({ kind in
                guard let url = storedStems.resolved()[kind] else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            })
        else { return false }
        return true
    }

    /// True when a refined stem set can be reused for the requested recipe.
    /// Unlike the legacy alias check, this validates the manifest recipe and
    /// every asset path in the manifest so child stems cannot silently disappear.
    func isStemSetCacheHit(
        record: AnalysisStageRecord?,
        sourceDigest: String,
        storedStemSet: StoredStemSetManifest?,
        expectedRecipe: StemRecipeIdentity
    ) -> Bool {
        guard
            let storedStemSet,
            let record,
            record.state == .succeeded,
            record.provenance?.sourceDigest == sourceDigest,
            record.provenance?.matchesEngine(currentEngine) == true
        else { return false }

        let manifest = storedStemSet.resolved()
        guard manifest.recipeIdentity?.cacheKey == expectedRecipe.cacheKey else { return false }
        return manifest.assets.allSatisfy {
            FileManager.default.fileExists(atPath: $0.audioURL.path)
        }
    }

    /// Whether a record that currently carries stems should be flipped to
    /// `.stale`. Mirrors AppModel.shouldMarkSeparationStale: a missing record is
    /// stale; otherwise only when it is not already stale and not current.
    func shouldMarkStale(_ record: AnalysisStageRecord?) -> Bool {
        guard let record else { return true }
        return record.state != .stale && !isCurrentEngine(record)
    }

    /// Produces the stale separation record, preserving provenance / confidence
    /// and stamping the user-facing rerun message. Mirrors
    /// AppModel.staleSeparationRecord.
    func markStale(_ record: AnalysisStageRecord?) -> AnalysisStageRecord {
        AnalysisStageRecord(
            state: .stale,
            provenance: record?.provenance,
            confidence: record?.confidence,
            errorMessage: "Saved stems were created by an older separator. Rerun Stems."
        )
    }
}

extension AnalysisProvenance {
    /// Matches the base engine identifier, tolerating the `+refiners` suffix that
    /// `StemRefinementPipelineEngine` stamps when Advanced stem refinement is on AND a refiner
    /// package is installed.
    ///
    /// Refinement is purely ADDITIVE: it splits an existing stem into children and leaves all six
    /// base stems byte-identical, produced by the same base engine at the same version. So a
    /// refined separation is never staler than an unrefined one, and treating it as a different
    /// engine is what broke things: `AppModel`'s staleness check reads
    /// `ONNXSixStemSeparationEngine.currentPlatformMetadata`, which has no way to know whether a
    /// refiner is installed, so it always compared against the bare identifier. Every refined song
    /// then failed the check on EVERY load, flipped to `.stale`, and re-separated — turning
    /// Advanced separation into an endless re-separation loop (Eric: "continuously getting a
    /// message that stems are stale even if I re-analyze the song").
    ///
    /// This is the same class of drift the `currentPlatformMetadata` comment already records for
    /// segment frames. Tolerating the suffix here fixes it for both readers at once, rather than
    /// teaching a static property to predict which refiners a given run will have.
    func matchesEngineIdentifier(_ identifier: String) -> Bool {
        engineIdentifier == identifier
            || engineIdentifier == identifier + StemRefinementPipelineEngine.refinedSuffix
    }

    /// True when this provenance's engine identity (engineIdentifier /
    /// engineVersion / modelIdentifier / modelVersion) matches `metadata`. Refined
    /// stem recipes depend on exact model weights, so a model-version change must
    /// not reuse older audio products.
    func matchesEngine(_ metadata: StemSeparationEngineMetadata) -> Bool {
        matchesEngineIdentifier(metadata.engineIdentifier)
            && engineVersion == metadata.engineVersion
            && modelIdentifier == metadata.modelIdentifier
            && modelVersion == metadata.modelVersion
    }
}
