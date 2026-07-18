import XCTest
@testable import Phosphor

final class RendererUniformTests: XCTestCase {
    func testRendererSkipsDuplicateFramesUnlessPresentationIsDirty() {
        XCTAssertFalse(MetalRenderer.shouldRender(
            hasNewPixelBuffer: false,
            needsRedraw: false,
            hasLastPixelBuffer: true
        ))
        XCTAssertTrue(MetalRenderer.shouldRender(
            hasNewPixelBuffer: false,
            needsRedraw: true,
            hasLastPixelBuffer: true
        ))
        XCTAssertTrue(MetalRenderer.shouldRender(
            hasNewPixelBuffer: true,
            needsRedraw: false,
            hasLastPixelBuffer: true
        ))
        XCTAssertFalse(MetalRenderer.shouldRender(
            hasNewPixelBuffer: true,
            needsRedraw: true,
            hasLastPixelBuffer: false
        ))
    }

    func testTemporalHistoryAdvancesOnlyForVideoFramesOrInitialization() {
        XCTAssertTrue(MetalRenderer.shouldAdvanceHistory(
            hasNewPixelBuffer: true,
            historyIsValid: true
        ))
        XCTAssertTrue(MetalRenderer.shouldAdvanceHistory(
            hasNewPixelBuffer: false,
            historyIsValid: false
        ))
        XCTAssertFalse(MetalRenderer.shouldAdvanceHistory(
            hasNewPixelBuffer: false,
            historyIsValid: true
        ))
    }

    func testGuestRasterUsesNativeSDLinesButResamplesHDVideo() {
        XCTAssertEqual(
            MetalRenderer.guestRasterSize(
                drawableSize: SIMD2(3_840, 2_160),
                sourceSize: SIMD2(640, 480)
            ),
            SIMD2(640, 480)
        )
        XCTAssertEqual(
            MetalRenderer.guestRasterSize(
                drawableSize: SIMD2(3_840, 2_160),
                sourceSize: SIMD2(1_920, 1_080)
            ),
            SIMD2(960, 540)
        )
    }

    func testGuestRasterKeepsEnoughPhysicalPixelsPerBeamInAWindow() {
        let raster = MetalRenderer.guestRasterSize(
            drawableSize: SIMD2(1_280, 720),
            sourceSize: SIMD2(1_920, 1_080)
        )

        XCTAssertEqual(raster.y, 276)
        XCTAssertEqual(raster.x, 490)
        XCTAssertGreaterThanOrEqual(720 / raster.y, 2)
    }

    func testShaderUniformLayoutMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.size, 176)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride, 176)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.alignment, 16)
    }

    func testSettingsMapToEffectVectors() {
        let settings = ShaderSettings(
            intensity: 0.11,
            curvature: 0.12,
            scanlines: 0.13,
            mask: 0.14,
            glow: 0.15,
            vignette: 0.16
        )

        let uniforms = ShaderUniforms(
            drawableSize: SIMD2(3_840, 2_160),
            sourceSize: SIMD2(1_920, 1_080),
            rasterSize: SIMD2(960, 540),
            settings: settings,
            yuvConversion: .make(matrix: .bt709, range: .video)
        )

        XCTAssertEqual(uniforms.drawableSize, SIMD4(3_840, 2_160, 1 / 3_840, 1 / 2_160))
        XCTAssertEqual(uniforms.sourceSize, SIMD4(1_920, 1_080, 1 / 1_920, 1 / 1_080))
        XCTAssertEqual(uniforms.rasterSize, SIMD4(960, 540, 1 / 960, 1 / 540))
        XCTAssertEqual(uniforms.effect, SIMD4(0.11, 0.12, 0.13, 0.14))
        XCTAssertEqual(uniforms.effect2, SIMD4(0.15, 0.16, 2, 0.20))
        XCTAssertEqual(uniforms.guestBeam, SIMD4(6.0, 8.0, 1.20, 1.0))
        XCTAssertEqual(uniforms.guestLight, SIMD4(0.10, 0.075, 1.40, 1.10))
    }

    func testBT601RowsMapIntoUniformFields() {
        assertConversionRowsMap(matrix: .bt601, range: .video)
    }

    func testBT709RowsMapIntoUniformFields() {
        assertConversionRowsMap(matrix: .bt709, range: .full)
    }

    private func assertConversionRowsMap(
        matrix: YUVMatrixKind,
        range: YUVRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let conversion = YUVConversion.make(matrix: matrix, range: range)
        let uniforms = ShaderUniforms(
            drawableSize: SIMD2(1, 1),
            sourceSize: SIMD2(1, 1),
            rasterSize: SIMD2(1, 1),
            settings: .default,
            yuvConversion: conversion
        )

        XCTAssertEqual(uniforms.yuvRow0, conversion.red, file: file, line: line)
        XCTAssertEqual(uniforms.yuvRow1, conversion.green, file: file, line: line)
        XCTAssertEqual(uniforms.yuvRow2, conversion.blue, file: file, line: line)
    }
}
