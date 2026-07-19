import AVFoundation
import XCTest
@testable import Phosphor

final class VideoColorMetadataTests: XCTestCase {
    func testSDRCharacteristicsDoNotProduceNotice() {
        let metadata = VideoColorMetadata(
            mediaCharacteristics: [.visual]
        )

        XCTAssertFalse(metadata.containsHDRVideo)
        XCTAssertNil(metadata.playbackNotice)
    }

    func testHDRCharacteristicsProduceColorManagedNotice() {
        let metadata = VideoColorMetadata(
            mediaCharacteristics: [.visual, .containsHDRVideo]
        )

        XCTAssertTrue(metadata.containsHDRVideo)
        XCTAssertEqual(
            metadata.playbackNotice,
            "HDR source is color-managed through the CRT tube model."
        )
    }
}
