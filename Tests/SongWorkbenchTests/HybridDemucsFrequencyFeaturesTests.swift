import XCTest

@testable import SongWorkbench

final class HybridDemucsFrequencyFeaturesTests: XCTestCase {
    func testTrainingWindowProducesExpectedFeatureFrames() {
        XCTAssertEqual(
            HybridDemucsFrequencyFeatures.frameCount(
                forSampleCount: ONNXDrumPieceSeparationEngine.segmentFrames
            ),
            1_723
        )
        XCTAssertEqual(HybridDemucsFrequencyFeatures.frequencyBins, 2_048)
    }

    func testComplexChannelFeaturesMatchExpectedShape() throws {
        let sampleCount = 8_192
        let left = (0..<sampleCount).map { Float(sin(Double($0) * 0.01)) }
        let right = (0..<sampleCount).map { Float(cos(Double($0) * 0.013)) }
        let features = try HybridDemucsFrequencyFeatures.complexChannelFeatures(
            left: left,
            right: right
        )
        let frames = HybridDemucsFrequencyFeatures.frameCount(forSampleCount: sampleCount)
        XCTAssertEqual(features.count, 4)
        XCTAssertEqual(features[0].count, HybridDemucsFrequencyFeatures.frequencyBins)
        XCTAssertEqual(features[0][0].count, frames)
        XCTAssertTrue(features.flatMap { $0.flatMap(\.self) }.allSatisfy(\.isFinite))
    }
}
