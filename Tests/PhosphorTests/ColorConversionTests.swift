import CoreVideo
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

    func testVideoRangeChromaIsScaledForEncodedRed() {
        let conversion = YUVConversion.make(matrix: .bt601, range: .video)
        let rgb = conversion.convert(y: 81 / 255, u: 90 / 255, v: 240 / 255)

        XCTAssertEqual(rgb.x, 1, accuracy: 0.01)
        XCTAssertEqual(rgb.y, 0, accuracy: 0.01)
        XCTAssertEqual(rgb.z, 0, accuracy: 0.01)
    }

    func testTenBitVideoRangeMapsNeutralBlackAndWhite() {
        let conversion = YUVConversion.make(matrix: .bt2020, range: .video10)
        let black = conversion.convert(y: 64 / 1_023, u: 0.5, v: 0.5)
        let white = conversion.convert(y: 940 / 1_023, u: 0.5, v: 0.5)

        XCTAssertEqual(black.x, 0, accuracy: 0.001)
        XCTAssertEqual(black.y, 0, accuracy: 0.001)
        XCTAssertEqual(black.z, 0, accuracy: 0.001)
        XCTAssertEqual(white.x, 1, accuracy: 0.001)
        XCTAssertEqual(white.y, 1, accuracy: 0.001)
        XCTAssertEqual(white.z, 1, accuracy: 0.001)
    }

    func testPixelBufferHDRMetadataIsPreservedForShaderConversion() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_64RGBAHalf,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )

        XCTAssertEqual(
            VideoColorConversion.make(for: buffer),
            VideoColorConversion(
                transferFunction: .pq,
                primaries: .bt2020
            )
        )

        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65,
            .shouldPropagate
        )
        XCTAssertEqual(
            VideoColorConversion.make(for: buffer),
            VideoColorConversion(
                transferFunction: .hlg,
                primaries: .displayP3
            )
        )
    }
}
