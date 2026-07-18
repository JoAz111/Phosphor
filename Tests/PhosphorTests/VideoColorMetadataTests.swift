import AVFoundation
import XCTest
@testable import Phosphor

final class VideoColorMetadataTests: XCTestCase {
    func testSDRCharacteristicsDoNotProduceNotice() {
        let metadata = VideoColorMetadata(
            mediaCharacteristics: [.visual]
        )

        XCTAssertFalse(metadata.containsHDRVideo)
        XCTAssertNil(metadata.sdrPathNotice)
    }

    func testHDRCharacteristicsProduceSDRPathNotice() {
        let metadata = VideoColorMetadata(
            mediaCharacteristics: [.visual, .containsHDRVideo]
        )

        XCTAssertTrue(metadata.containsHDRVideo)
        XCTAssertEqual(
            metadata.sdrPathNotice,
            "HDR video is rendered through the SDR path."
        )
    }
}
