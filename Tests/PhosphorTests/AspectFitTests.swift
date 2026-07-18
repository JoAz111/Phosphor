import CoreGraphics
import XCTest
@testable import Phosphor

final class AspectFitTests: XCTestCase {
    func testWideSourceInNarrowDestination() {
        let rect = AspectFit.normalizedRect(
            source: CGSize(width: 16, height: 9),
            destination: CGSize(width: 4, height: 3)
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 0.125, width: 1, height: 0.75))
    }

    func testNarrowSourceInWideDestination() {
        let rect = AspectFit.normalizedRect(
            source: CGSize(width: 4, height: 3),
            destination: CGSize(width: 16, height: 9)
        )

        XCTAssertEqual(rect, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
    }

    func testZeroSizedInputsReturnZero() {
        XCTAssertEqual(
            AspectFit.normalizedRect(source: .zero, destination: CGSize(width: 16, height: 9)),
            .zero
        )
        XCTAssertEqual(
            AspectFit.normalizedRect(source: CGSize(width: 16, height: 9), destination: .zero),
            .zero
        )
    }
}
