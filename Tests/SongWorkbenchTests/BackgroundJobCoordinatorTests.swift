import Foundation
import XCTest

@testable import SongWorkbench

final class BackgroundJobCoordinatorTests: XCTestCase {
    func testJobRetainsStableIDAndPublishesProgressThroughCompletion() async throws {
        let coordinator = BackgroundJobCoordinator()
        let id = BackgroundJobID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)

        let submittedID = try await coordinator.submit(id: id) { reporter in
            await reporter.report(
                BackgroundJobProgress(completedUnits: 1, totalUnits: 4, message: "Analyzing")
            )
        }

        XCTAssertEqual(submittedID, id)
        let snapshot = try await waitForTerminalSnapshot(id: id, coordinator: coordinator)
        XCTAssertEqual(snapshot.id, id)
        XCTAssertEqual(snapshot.state, .succeeded)
        XCTAssertEqual(snapshot.progress?.fractionCompleted, 0.25)
        XCTAssertEqual(snapshot.progress?.message, "Analyzing")
    }

    func testCancelStopsOnlySelectedJob() async throws {
        let coordinator = BackgroundJobCoordinator()
        let cancelledID = try await coordinator.submit { _ in
            try await Task.sleep(for: .seconds(10))
        }
        let successfulID = try await coordinator.submit { _ in }

        let didCancel = await coordinator.cancel(cancelledID)
        XCTAssertTrue(didCancel)

        let cancelled = try await waitForTerminalSnapshot(id: cancelledID, coordinator: coordinator)
        let successful = try await waitForTerminalSnapshot(
            id: successfulID, coordinator: coordinator)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(successful.state, .succeeded)
    }

    func testCancelAllCancelsEveryRunningJob() async throws {
        let coordinator = BackgroundJobCoordinator()
        let ids = try await (0..<3).asyncMap { _ in
            try await coordinator.submit { _ in
                try await Task.sleep(for: .seconds(10))
            }
        }

        await coordinator.cancelAll()

        for id in ids {
            let snapshot = try await waitForTerminalSnapshot(id: id, coordinator: coordinator)
            XCTAssertEqual(snapshot.state, .cancelled)
        }
    }

    func testDuplicateIDIsRejected() async throws {
        let coordinator = BackgroundJobCoordinator()
        let id = BackgroundJobID()
        _ = try await coordinator.submit(id: id) { _ in }

        do {
            _ = try await coordinator.submit(id: id) { _ in }
            XCTFail("Expected duplicate ID error")
        } catch {
            XCTAssertEqual(error as? BackgroundJobCoordinatorError, .duplicateID(id))
        }
    }

    func testThrownErrorIsCapturedInFailedSnapshot() async throws {
        let coordinator = BackgroundJobCoordinator()
        let id = try await coordinator.submit { _ in
            throw TestFailure.expected
        }

        let snapshot = try await waitForTerminalSnapshot(id: id, coordinator: coordinator)
        XCTAssertEqual(snapshot.state, .failed(message: "expected"))
    }

    private func waitForTerminalSnapshot(
        id: BackgroundJobID,
        coordinator: BackgroundJobCoordinator
    ) async throws -> BackgroundJobSnapshot {
        for _ in 0..<200 {
            if let snapshot = await coordinator.snapshot(for: id), snapshot.state.isTerminal {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TimeoutError()
    }
}

private struct TimeoutError: Error {}

private enum TestFailure: Error {
    case expected
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}
