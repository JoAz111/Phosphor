import XCTest
@testable import Phosphor

final class MetalFrameBudgetControllerTests: XCTestCase {
    func testControllerDropsToSustainableCadenceUnderPersistentLoad() {
        let controller = MetalFrameBudgetController()
        for _ in 0 ..< 24 {
            controller.recordPresentation(
                gpuDuration: 0.008,
                displayMaximum: 120
            )
        }
        XCTAssertEqual(controller.maximumFrameRate(displayMaximum: 120), 60)
    }

    func testControllerRecoversHighRefreshAfterSustainedHeadroom() {
        let controller = MetalFrameBudgetController()
        for _ in 0 ..< 24 {
            controller.recordPresentation(
                gpuDuration: 0.008,
                displayMaximum: 120
            )
        }
        for _ in 0 ..< 240 {
            controller.recordPresentation(
                gpuDuration: 0.002,
                displayMaximum: 120
            )
        }
        XCTAssertEqual(controller.maximumFrameRate(displayMaximum: 120), 120)
    }

    func testControllerNeverExceedsPhysicalDisplayMaximum() {
        let controller = MetalFrameBudgetController()
        XCTAssertEqual(controller.maximumFrameRate(displayMaximum: 60), 60)
    }
}
