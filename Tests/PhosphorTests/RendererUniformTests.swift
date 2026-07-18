import XCTest
@testable import Phosphor

final class RendererUniformTests: XCTestCase {
    func testShaderUniformLayoutMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.size, 96)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride, 96)
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
            settings: settings,
            yuvConversion: .make(matrix: .bt709, range: .video)
        )

        XCTAssertEqual(uniforms.drawableSize, SIMD2(3_840, 2_160))
        XCTAssertEqual(uniforms.sourceSize, SIMD2(1_920, 1_080))
        XCTAssertEqual(uniforms.effect, SIMD4(0.11, 0.12, 0.13, 0.14))
        XCTAssertEqual(uniforms.effect2, SIMD4(0.15, 0.16, 0, 0))
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
            settings: .default,
            yuvConversion: conversion
        )

        XCTAssertEqual(uniforms.yuvRow0, conversion.red, file: file, line: line)
        XCTAssertEqual(uniforms.yuvRow1, conversion.green, file: file, line: line)
        XCTAssertEqual(uniforms.yuvRow2, conversion.blue, file: file, line: line)
    }
}
