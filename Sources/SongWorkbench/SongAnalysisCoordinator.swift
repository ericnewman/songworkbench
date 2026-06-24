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
    private let pipelineFactory: SongAnalysisPipelineFactory
    private var task: Task<Void, Never>?

    init(pipelineFactory: SongAnalysisPipelineFactory) {
        self.pipelineFactory = pipelineFactory
    }

    /// Cancels any in-flight run, then assembles and runs the pipeline for
    /// `request`. `onStatuses`, `onProgress`, and `onFinish` are invoked on the
    /// main actor; `onFinish` is called exactly once with `.success` or
    /// `.failure` (a `CancellationError` on cancellation).
    func run(
        request: SongAnalysisPipelineRequest,
        onStatuses: @escaping @MainActor ([String: ModelPackageStatus]) -> Void,
        onProgress: @escaping @MainActor (SongAnalysisPipelineProgress) -> Void,
        onFinish: @escaping @MainActor (Result<SongAnalysisPipelineResult, Error>) -> Void
    ) {
        task?.cancel()
        task = Task { [pipelineFactory] in
            do {
                let assembly = try await pipelineFactory.makePipeline()
                onStatuses(assembly.statuses)
                let result = try await assembly.pipeline.run(request) { value in
                    Task { @MainActor in onProgress(value) }
                }
                onFinish(.success(result))
            } catch {
                onFinish(.failure(error))
            }
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }
}
