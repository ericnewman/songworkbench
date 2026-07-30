import Foundation

/// Orchestrates a single run of the multi-stage analysis pipeline: it assembles
/// the pipeline from installed model packages, runs it while forwarding progress
/// and the observed model-package statuses, and delivers the terminal outcome —
/// all on the main actor.
///
/// The coordinator owns only the in-flight run task. The caller keeps the
/// published UI state (running flag, progress) and applies the resulting
/// document, so this stays decoupled from `AppModel`'s many `@Published`
/// properties while concentrating the run/cancel orchestration in one place.
@MainActor
final class SongAnalysisCoordinator {
    private let makePipeline: @Sendable () async throws -> SongAnalysisPipelineFactory.Assembly
    private var task: Task<Void, Never>?
    private var currentRunID: UUID?

    init(pipelineFactory: SongAnalysisPipelineFactory) {
        makePipeline = {
            try await pipelineFactory.makePipeline()
        }
    }

    init(
        makePipeline:
            @escaping @Sendable () async throws
            -> SongAnalysisPipelineFactory.Assembly
    ) {
        self.makePipeline = makePipeline
    }

    /// Cancels and drains any in-flight run, then assembles and runs the pipeline for
    /// `request`. `onStatuses`, `onProgress`, and `onFinish` are invoked on the
    /// main actor; `onFinish` is called exactly once with `.success` or
    /// `.failure` (a `CancellationError` on cancellation).
    @discardableResult
    func run(
        request: SongAnalysisPipelineRequest,
        onStatuses: @escaping @MainActor (UUID, [String: ModelPackageStatus]) -> Void,
        onProgress: @escaping @MainActor (UUID, SongAnalysisPipelineProgress) -> Void,
        onFinish: @escaping @MainActor (UUID, Result<SongAnalysisPipelineResult, Error>) -> Void
    ) -> UUID {
        let previousTask = task
        previousTask?.cancel()
        let runID = UUID()
        currentRunID = runID
        let nextTask = Task { [makePipeline] in
            // ORT and some Core ML calls are synchronous and cannot observe Swift
            // cancellation until the current inference chunk returns. Do not assemble
            // replacement models until that task has fully unwound and released them.
            if let previousTask {
                await previousTask.value
            }
            do {
                try Task.checkCancellation()
                let assembly = try await makePipeline()
                try Task.checkCancellation()
                if self.currentRunID == runID {
                    onStatuses(runID, assembly.statuses)
                }
                let result = try await assembly.pipeline.run(request) { value in
                    Task { @MainActor in
                        guard self.currentRunID == runID else { return }
                        onProgress(runID, value)
                    }
                }
                let outcome: Result<SongAnalysisPipelineResult, Error> =
                    self.currentRunID == runID
                    ? .success(result)
                    : .failure(CancellationError())
                onFinish(runID, outcome)
            } catch {
                let deliveredError: Error =
                    self.currentRunID == runID ? error : CancellationError()
                onFinish(runID, .failure(deliveredError))
            }
            if self.currentRunID == runID {
                self.currentRunID = nil
                self.task = nil
            }
        }
        task = nextTask
        return runID
    }

    func cancel() {
        task?.cancel()
    }
}
