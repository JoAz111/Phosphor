import XCTest
@testable import Phosphor

final class RendererUniformTests: XCTestCase {
    func testGPUClockSpanConversionProducesMilliseconds() {
        XCTAssertEqual(
            MetalFrameDiagnostics.milliseconds(
                gpuDelta: 250,
                gpuClockSpan: 1_000,
                cpuClockSpan: 8_000_000
            ),
            2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MetalFrameDiagnostics.milliseconds(
                gpuDelta: 1,
                gpuClockSpan: 0,
                cpuClockSpan: 1
            ),
            0
        )
    }

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
        XCTAssertTrue(MetalRenderer.shouldRender(
            hasNewPixelBuffer: false,
            needsRedraw: false,
            hasLastPixelBuffer: true,
            simulatesCRT: true
        ))
    }

    func testDisplayCadenceTracksVideoAndFallsBackToSixtyHertz() throws {
        let film = MetalRenderer.preferredFrameRateRange(
            nominalFrameRate: 23.976
        )
        XCTAssertEqual(film.minimum, 23.976, accuracy: 0.001)
        XCTAssertEqual(film.maximum, 60)
        XCTAssertEqual(
            try XCTUnwrap(film.preferred),
            23.976,
            accuracy: 0.001
        )

        let fallback = MetalRenderer.preferredFrameRateRange(
            nominalFrameRate: .nan
        )
        XCTAssertEqual(fallback.minimum, 24)
        XCTAssertEqual(fallback.maximum, 60)
        XCTAssertEqual(try XCTUnwrap(fallback.preferred), 60)

        let crt = MetalRenderer.preferredFrameRateRange(
            nominalFrameRate: 23.976,
            maximumDisplayFrameRate: 120,
            simulatesCRT: true
        )
        XCTAssertEqual(crt.minimum, 60)
        XCTAssertEqual(crt.maximum, 120)
        XCTAssertEqual(try XCTUnwrap(crt.preferred), 120)
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
                sourceSize: SIMD2(320, 240)
            ),
            SIMD2(320, 240)
        )
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

    func testExplicitRasterModesProducePeriodCorrectLineCounts() {
        XCTAssertEqual(
            MetalRenderer.guestRasterSize(
                drawableSize: SIMD2(3_840, 2_160),
                sourceSize: SIMD2(1_920, 1_080),
                rasterMode: .progressive240
            ).y,
            240
        )
        XCTAssertEqual(
            MetalRenderer.guestRasterSize(
                drawableSize: SIMD2(3_840, 2_160),
                sourceSize: SIMD2(1_920, 1_080),
                rasterMode: .interlaced480
            ).y,
            480
        )
    }

    func testInterlaceModeHonorsSourceMetadataAndOverrides() {
        let interlaced = VideoScanMetadata(fieldOrder: .topFirst)
        XCTAssertTrue(MetalRenderer.isInterlaced(
            rasterMode: .automatic,
            scanMetadata: interlaced
        ))
        XCTAssertFalse(MetalRenderer.isInterlaced(
            rasterMode: .progressive240,
            scanMetadata: interlaced
        ))
        XCTAssertTrue(MetalRenderer.isInterlaced(
            rasterMode: .interlaced480,
            scanMetadata: .progressive
        ))
    }

    func testRasterRefreshRateTracksPALAndInterlacedMetadata() {
        XCTAssertEqual(MetalRenderer.rasterRefreshRate(
            signalType: .compositePAL,
            isInterlaced: false,
            nominalFrameRate: 60
        ), 50)
        XCTAssertEqual(MetalRenderer.rasterRefreshRate(
            signalType: .rgb,
            isInterlaced: true,
            nominalFrameRate: 29.97
        ), 59.94, accuracy: 0.001)
        XCTAssertEqual(MetalRenderer.rasterRefreshRate(
            signalType: .rgb,
            isInterlaced: false,
            nominalFrameRate: 24
        ), 60)
    }

    func testShaderUniformLayoutMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.size, 272)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride, 272)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.alignment, 16)
    }

    func testSettingsMapToEffectVectors() {
        let settings = ShaderSettings(
            intensity: 0.11,
            curvature: 0.12,
            scanlines: 0.13,
            mask: 0.14,
            maskPattern: .slotMask,
            glow: 0.15,
            vignette: 0.16,
            persistence: 0.17,
            convergence: 0.18,
            focus: 0.19,
            rasterMode: .interlaced480,
            signalType: .compositeNTSC,
            tubeProfile: .professionalMonitor
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
        XCTAssertEqual(uniforms.effect2, SIMD4(0.15, 0.16, 3, 1))
        XCTAssertEqual(uniforms.guestBeam, SIMD4(7.2, 9.0, 1.02, 0.88))
        XCTAssertEqual(uniforms.guestLight, SIMD4(0.22, 0.045, 1.25, 1.05))
        XCTAssertEqual(uniforms.guestColor, SIMD4(1.86, 1.78, 0.14, 0.46))
        XCTAssertEqual(uniforms.guestScan, SIMD4(0.68, 0.62, 1.0, 2.30))
        XCTAssertEqual(uniforms.guestMask, SIMD4(6.0, 1.06, 2.30, 1.0))
        XCTAssertEqual(uniforms.frameData.z, 1)
        XCTAssertEqual(uniforms.tubeData, SIMD4(0.17, 0.18, 0.19, 2))
        XCTAssertEqual(uniforms.videoData.z, 2)
    }

    func testEDRHeadroomIsClampedWithoutChangingUniformLayout() {
        let conversion = YUVConversion.make(matrix: .bt709, range: .video)

        let edr = ShaderUniforms(
            drawableSize: SIMD2(1, 1),
            sourceSize: SIMD2(1, 1),
            rasterSize: SIMD2(1, 1),
            settings: .default,
            yuvConversion: conversion,
            edrHeadroom: 8
        )
        let invalid = ShaderUniforms(
            drawableSize: SIMD2(1, 1),
            sourceSize: SIMD2(1, 1),
            rasterSize: SIMD2(1, 1),
            settings: .default,
            yuvConversion: conversion,
            edrHeadroom: .nan
        )

        XCTAssertEqual(edr.frameData.z, 2)
        XCTAssertEqual(invalid.frameData.z, 1)
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
