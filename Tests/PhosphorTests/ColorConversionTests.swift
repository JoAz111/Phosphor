import XCTest
@testable import Phosphor

final class ColorConversionTests: XCTestCase {
    func testVideoRangeNeutralBlackMapsNearZero() {
        let conversion = YUVConversion.make(matrix: .bt709, range: .video)
        let rgb = conversion.convert(y: 16 / 255, u: 0.5, v: 0.5)

        XCTAssertEqual(rgb.x, 0, accuracy: 0.001)
        XCTAssertEqual(rgb.y, 0, accuracy: 0.001)
        XCTAssertEqual(rgb.z, 0, accuracy: 0.001)
    }

    func testVideoRangeNeutralWhiteMapsNearOne() {
        let conversion = YUVConversion.make(matrix: .bt709, range: .video)
        let rgb = conversion.convert(y: 235 / 255, u: 0.5, v: 0.5)

        XCTAssertEqual(rgb.x, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.y, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.z, 1, accuracy: 0.001)
    }

    func testNeutralChromaRemainsGray() {
        let conversion = YUVConversion.make(matrix: .bt601, range: .full)
        let rgb = conversion.convert(y: 0.6, u: 0.5, v: 0.5)

        XCTAssertEqual(rgb.x, rgb.y, accuracy: 0.0001)
        XCTAssertEqual(rgb.y, rgb.z, accuracy: 0.0001)
    }

    func testMatricesProduceDifferentRedForSameChroma() {
        let sample = (y: Float(0.6), u: Float(0.4), v: Float(0.8))
        let bt601 = YUVConversion.make(matrix: .bt601, range: .full)
        let bt709 = YUVConversion.make(matrix: .bt709, range: .full)

        XCTAssertNotEqual(
            bt601.convert(y: sample.y, u: sample.u, v: sample.v).x,
            bt709.convert(y: sample.y, u: sample.u, v: sample.v).x
        )
    }
}
