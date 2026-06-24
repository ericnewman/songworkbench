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
            storedStems.resolved().isSixSource,
            storedStems.resolved().availableKinds.allSatisfy({ kind in
                guard let url = storedStems.resolved()[kind] else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            })
        else { return false }
        return true
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
    /// True when this provenance's engine identity (engineIdentifier /
    /// engineVersion / modelIdentifier) matches `metadata`. Used to decide
    /// whether a saved separation is current. Note: modelVersion is intentionally
    /// not part of the identity check (matching existing AppModel semantics).
    func matchesEngine(_ metadata: StemSeparationEngineMetadata) -> Bool {
        engineIdentifier == metadata.engineIdentifier
            && engineVersion == metadata.engineVersion
            && modelIdentifier == metadata.modelIdentifier
    }
}
