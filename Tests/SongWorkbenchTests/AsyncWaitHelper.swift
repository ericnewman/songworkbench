import XCTest

/// Polls `condition` until it returns true or `timeout` elapses, failing the test if it never
/// does. Use this in place of a fixed `Task.sleep` after triggering async/debounced `AppModel`
/// work (imports, scheduled saves, removals): `AppModel.scheduleSave` debounces ~250ms before
/// actually saving, `importSongs`'s per-file localization copy runs on its own background
/// `Task`, and a fixed sleep's margin over either isn't safe on a slower or more contended
/// machine — this exact class of bug (a fixed sleep racing debounced async work) has bitten
/// this suite before. `@MainActor`-isolated so a condition closure can read `AppModel` state
/// directly; awaiting a separate actor (e.g. a test's fake `ProjectStore`) inside the closure
/// works too via its own explicit `await`.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    pollInterval: Duration = .milliseconds(10),
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await condition() { return }
        if ContinuousClock.now >= deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try await Task.sleep(for: pollInterval)
    }
}
