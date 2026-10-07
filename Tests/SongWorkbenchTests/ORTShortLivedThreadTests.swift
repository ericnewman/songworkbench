import Foundation
import XCTest

@testable import SongWorkbench

final class ORTShortLivedThreadTests: XCTestCase {
    func testRunsTheBodyOnAnotherThreadAndReturnsItsValue() throws {
        let caller = Thread.current
        let ranElsewhere = try ORTShortLivedThread.run { Thread.current !== caller }
        XCTAssertTrue(ranElsewhere)
    }

    func testRethrowsTheBodyError() {
        XCTAssertThrowsError(
            try ORTShortLivedThread.run { throw CoreMLStemSeparationError.invalidPrediction }
        )
    }
}
