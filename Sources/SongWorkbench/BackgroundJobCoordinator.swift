import Foundation

struct BackgroundJobID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct BackgroundJobProgress: Equatable, Codable, Sendable {
    let completedUnits: Int
    let totalUnits: Int
    let message: String?

    init(completedUnits: Int, totalUnits: Int, message: String? = nil) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.message = message
    }

    var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
    }
}

enum BackgroundJobState: Equatable, Codable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed(message: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            true
        case .queued, .running, .cancelling:
            false
        }
    }
}

struct BackgroundJobSnapshot: Equatable, Codable, Sendable {
    let id: BackgroundJobID
    let state: BackgroundJobState
    let progress: BackgroundJobProgress?
}

struct BackgroundJobProgressReporter: Sendable {
    private let reportClosure: @Sendable (BackgroundJobProgress) async -> Void

    init(report: @escaping @Sendable (BackgroundJobProgress) async -> Void) {
        reportClosure = report
    }

    func report(_ progress: BackgroundJobProgress) async {
        await reportClosure(progress)
    }
}

enum BackgroundJobCoordinatorError: Error, Equatable {
    case duplicateID(BackgroundJobID)
}

actor BackgroundJobCoordinator {
    typealias Operation = @Sendable (BackgroundJobProgressReporter) async throws -> Void

    private var snapshotsByID: [BackgroundJobID: BackgroundJobSnapshot] = [:]
    private var tasksByID: [BackgroundJobID: Task<Void, Never>] = [:]

    @discardableResult
    func submit(
        id: BackgroundJobID = BackgroundJobID(),
        operation: @escaping Operation
    ) throws -> BackgroundJobID {
        guard snapshotsByID[id] == nil else {
            throw BackgroundJobCoordinatorError.duplicateID(id)
        }

        snapshotsByID[id] = BackgroundJobSnapshot(id: id, state: .queued, progress: nil)
        tasksByID[id] = Task { [weak self] in
            await self?.run(id: id, operation: operation)
        }
        return id
    }

    func snapshot(for id: BackgroundJobID) -> BackgroundJobSnapshot? {
        snapshotsByID[id]
    }

    func snapshots() -> [BackgroundJobSnapshot] {
        Array(snapshotsByID.values)
    }

    @discardableResult
    func cancel(_ id: BackgroundJobID) -> Bool {
        guard let task = tasksByID[id], let snapshot = snapshotsByID[id] else {
            return false
        }

        if !snapshot.state.isTerminal {
            updateSnapshot(id: id, state: .cancelling)
            task.cancel()
        }
        return true
    }

    func cancelAll() {
        for id in tasksByID.keys {
            cancel(id)
        }
    }

    @discardableResult
    func discard(_ id: BackgroundJobID) -> Bool {
        guard snapshotsByID[id]?.state.isTerminal == true else { return false }
        snapshotsByID[id] = nil
        tasksByID[id] = nil
        return true
    }

    private func run(id: BackgroundJobID, operation: @escaping Operation) async {
        updateSnapshot(id: id, state: .running)
        let reporter = BackgroundJobProgressReporter { [weak self] progress in
            await self?.record(progress: progress, for: id)
        }

        do {
            try Task.checkCancellation()
            try await operation(reporter)
            try Task.checkCancellation()
            updateSnapshot(id: id, state: .succeeded)
        } catch is CancellationError {
            updateSnapshot(id: id, state: .cancelled)
        } catch {
            updateSnapshot(id: id, state: .failed(message: String(describing: error)))
        }

        tasksByID[id] = nil
    }

    private func record(progress: BackgroundJobProgress, for id: BackgroundJobID) {
        guard let snapshot = snapshotsByID[id], !snapshot.state.isTerminal else { return }
        snapshotsByID[id] = BackgroundJobSnapshot(
            id: id,
            state: snapshot.state,
            progress: progress
        )
    }

    private func updateSnapshot(id: BackgroundJobID, state: BackgroundJobState) {
        guard let snapshot = snapshotsByID[id] else { return }
        snapshotsByID[id] = BackgroundJobSnapshot(
            id: id,
            state: state,
            progress: snapshot.progress
        )
    }
}
