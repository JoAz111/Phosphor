import Metal
import XCTest
@testable import Phosphor

final class MetalShaderTests: XCTestCase {
    func testBundledSourceContainsGuestAdvancedPassesAndLicense() throws {
        let source = try ShaderLibrarySource.load()

        XCTAssertTrue(source.contains("CRT-Guest-Advanced copyright"))
        XCTAssertTrue(source.contains("GNU General Public License"))
        for entryPoint in expectedEntryPoints.map(\.name) {
            XCTAssertTrue(source.contains(entryPoint), "Missing \(entryPoint)")
        }
    }

    func testBundledSourceCompilesAndBuildsEveryPipeline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }

        let library = try device.makeLibrary(source: ShaderLibrarySource.load(), options: nil)
        let vertex = try XCTUnwrap(library.makeFunction(name: "phosphorFullscreenVertex"))

        for entryPoint in expectedEntryPoints {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = try fragmentFunction(
                named: entryPoint.name,
                library: library,
                usesSlotMask: maskEntryPoints.contains(entryPoint.name)
                    ? false
                    : nil
            )
            for (index, pixelFormat) in entryPoint.pixelFormats.enumerated() {
                descriptor.colorAttachments[index].pixelFormat = pixelFormat
            }
            XCTAssertNoThrow(
                try device.makeRenderPipelineState(descriptor: descriptor),
                entryPoint.name
            )
        }

        let slotDescriptor = MTLRenderPipelineDescriptor()
        slotDescriptor.vertexFunction = vertex
        slotDescriptor.fragmentFunction = try fragmentFunction(
            named: "guestPhosphorMaskFragment",
            library: library,
            usesSlotMask: true
        )
        slotDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        XCTAssertNoThrow(
            try device.makeRenderPipelineState(descriptor: slotDescriptor),
            "guestPhosphorMaskFragment slot-mask specialization"
        )
    }

    func testBypassPreservesRawFittedCorner() throws {
        let size = 32
        let source = try makeSolidTexture(
            width: size,
            height: size,
            pixelFormat: .bgra8Unorm,
            color: SIMD4<UInt8>(255, 255, 255, 255)
        )
        let pixels = try render(
            function: "phosphorBypassFragmentBGRA",
            outputSize: SIMD2(size, size),
            outputFormat: .bgra8Unorm_srgb,
            textures: [source],
            settings: ShaderSettings(intensity: 0)
        )

        XCTAssertGreaterThan(pixels[2], 240)
    }

    func testGuestBeamReconstructsDistinctRasterLines() throws {
        let source = try makeSolidFloatTexture(
            width: 4,
            height: 2,
            color: SIMD4<Float>(0.35, 0.35, 0.35, 0.35)
        )
        let auxiliary = try makeSolidFloatTexture(
            width: 4,
            height: 2,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let pixels = try render(
            function: "guestHDBeamFragment",
            outputSize: SIMD2(16, 8),
            outputFormat: .rgba16Float,
            textures: [source, auxiliary, source],
            sourceSize: SIMD2(4, 2),
            settings: ShaderSettings(curvature: 0, scanlines: 1)
        )

        let rows = (0 ..< 8).map {
            halfFloatRed(pixels, width: 16, x: 8, y: $0)
        }
        XCTAssertGreaterThan(
            (rows.max() ?? 0) - (rows.min() ?? 0),
            0.02
        )
    }

    func testInterlacedBeamExcitesAlternatingFieldLines() throws {
        let source = try makeSolidFloatTexture(
            width: 4,
            height: 4,
            color: SIMD4<Float>(0.35, 0.35, 0.35, 0.35)
        )
        let auxiliary = try makeSolidFloatTexture(
            width: 4,
            height: 4,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let even = try render(
            function: "guestHDBeamFragment",
            outputSize: SIMD2(16, 16),
            outputFormat: .rgba16Float,
            textures: [source, auxiliary, source],
            sourceSize: SIMD2(4, 4),
            settings: ShaderSettings(curvature: 0, scanlines: 1),
            isInterlaced: true,
            fieldParity: 0
        )
        let odd = try render(
            function: "guestHDBeamFragment",
            outputSize: SIMD2(16, 16),
            outputFormat: .rgba16Float,
            textures: [source, auxiliary, source],
            sourceSize: SIMD2(4, 4),
            settings: ShaderSettings(curvature: 0, scanlines: 1),
            isInterlaced: true,
            fieldParity: 1
        )

        let differences = (0 ..< 16).map { row in
            halfFloatRed(even, width: 16, x: 8, y: row)
                - halfFloatRed(odd, width: 16, x: 8, y: row)
        }
        XCTAssertGreaterThan(differences.max() ?? 0, 0.005)
        XCTAssertLessThan(differences.min() ?? 0, -0.005)
    }

    func testGuestLinearizeUsesUpstreamInputGamma() throws {
        let encoded = try makeSolidFloatTexture(
            width: 4,
            height: 4,
            color: SIMD4<Float>(0.5, 0.5, 0.5, 1)
        )
        let pixels = try render(
            function: "guestLinearizeFragment",
            outputSize: SIMD2(4, 4),
            outputFormat: .rgba16Float,
            textures: [encoded],
            settings: .default
        )

        XCTAssertEqual(
            halfFloatChannel(pixels, width: 4, x: 2, y: 2, channel: 0),
            pow(0.5, 1.8),
            accuracy: 0.002
        )
    }

    func testGuestAfterglowStartsWithEmptyPersistence() throws {
        let source = try makeSolidFloatTexture(
            width: 4,
            height: 4,
            color: SIMD4<Float>(0.8, 0.4, 0.2, 1)
        )
        let feedback = try makeSolidFloatTexture(
            width: 4,
            height: 4,
            color: SIMD4<Float>(0.5, 0.5, 0.5, 1)
        )
        let pixels = try render(
            function: "guestAfterglowFragment",
            outputSize: SIMD2(4, 4),
            outputFormat: .rgba16Float,
            textures: [source, feedback],
            settings: .default
        )

        XCTAssertEqual(
            halfFloatChannel(pixels, width: 4, x: 2, y: 2, channel: 0),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            halfFloatChannel(pixels, width: 4, x: 2, y: 2, channel: 3),
            1,
            accuracy: 0.001
        )
    }

    func testFinalMaskCreatesSeparateRGBPhosphorsInPhysicalPixels() throws {
        let size = 12
        let sharpened = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0.25, 0.25, 0.25, 0.20)
        )
        let black = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let pixels = try render(
            function: "guestPhosphorMaskFragment",
            outputSize: SIMD2(size, size),
            outputFormat: .bgra8Unorm_srgb,
            textures: [sharpened, black, black, black, black],
            settings: ShaderSettings(
                intensity: 1,
                curvature: 0,
                scanlines: 1,
                mask: 1,
                glow: 0,
                vignette: 0
            )
        )

        let redPhosphor = bgraPixel(pixels, width: size, x: 3, y: 6)
        let greenPhosphor = bgraPixel(pixels, width: size, x: 4, y: 6)
        let bluePhosphor = bgraPixel(pixels, width: size, x: 5, y: 6)

        XCTAssertGreaterThan(redPhosphor.z, redPhosphor.y + 20)
        XCTAssertGreaterThan(greenPhosphor.y, greenPhosphor.z + 20)
        XCTAssertGreaterThan(bluePhosphor.x, bluePhosphor.y + 20)
    }

    func testSlotMaskCreatesDiscreteStaggeredRGBCellsAndBlackMatrix() throws {
        let size = 36
        let sharpened = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0.25, 0.25, 0.25, 0.20)
        )
        let black = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let pixels = try render(
            function: "guestPhosphorMaskFragment",
            outputSize: SIMD2(size, size),
            outputFormat: .bgra8Unorm_srgb,
            textures: [sharpened, black, black, black, black],
            settings: ShaderSettings(
                intensity: 1,
                curvature: 0,
                scanlines: 0,
                mask: 1,
                maskPattern: .slotMask,
                glow: 0,
                vignette: 0
            )
        )

        let evenRed = bgraPixel(pixels, width: size, x: 1, y: 5)
        let evenGreen = bgraPixel(pixels, width: size, x: 4, y: 5)
        let evenBlue = bgraPixel(pixels, width: size, x: 7, y: 5)
        let horizontalMatrix = bgraPixel(pixels, width: size, x: 0, y: 5)
        let evenVerticalMatrix = bgraPixel(pixels, width: size, x: 1, y: 0)
        let staggeredOddSlot = bgraPixel(pixels, width: size, x: 10, y: 0)
        let staggeredOddMatrix = bgraPixel(pixels, width: size, x: 10, y: 5)

        XCTAssertGreaterThan(evenRed.z, evenRed.y + 20)
        XCTAssertGreaterThan(evenGreen.y, evenGreen.z + 20)
        XCTAssertGreaterThan(evenBlue.x, evenBlue.y + 20)
        XCTAssertGreaterThan(evenRed.z, horizontalMatrix.z + 20)
        XCTAssertGreaterThan(evenRed.z, evenVerticalMatrix.z + 20)
        XCTAssertGreaterThan(staggeredOddSlot.z, staggeredOddMatrix.z + 20)
    }

    func testTubeGlowAddsNeutralBloomAndWarmHalation() throws {
        let size = 12
        let sharpened = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0, 0, 0, 0)
        )
        let black = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let bloom = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0.35, 0.35, 0.35, 1)
        )

        let glowOn = try render(
            function: "guestPhosphorMaskFragment",
            outputSize: SIMD2(size, size),
            outputFormat: .bgra8Unorm_srgb,
            textures: [sharpened, bloom, black, black, black],
            settings: ShaderSettings(
                intensity: 1,
                curvature: 0,
                scanlines: 1,
                mask: 0,
                glow: ShaderSettings.default.glow,
                vignette: 0
            )
        )
        let glowOff = try render(
            function: "guestPhosphorMaskFragment",
            outputSize: SIMD2(size, size),
            outputFormat: .bgra8Unorm_srgb,
            textures: [sharpened, bloom, black, black, black],
            settings: ShaderSettings(
                intensity: 1,
                curvature: 0,
                scanlines: 1,
                mask: 0,
                glow: 0,
                vignette: 0
            )
        )

        let lit = bgraPixel(glowOn, width: size, x: 6, y: 6)
        let unlit = bgraPixel(glowOff, width: size, x: 6, y: 6)
        XCTAssertGreaterThan(lit.z, unlit.z + 20)
        XCTAssertGreaterThan(lit.y, unlit.y + 20)
        XCTAssertGreaterThan(lit.x, unlit.x + 20)
        XCTAssertGreaterThan(lit.z, lit.x)
    }

    func testBloomSoftKneeKeepsDarkInputBlack() throws {
        let size = 12
        let dark = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0.05, 0.05, 0.05, 1)
        )
        let pixels = try render(
            function: "guestBloomHorizontalFragment",
            outputSize: SIMD2(size, size),
            outputFormat: .rgba16Float,
            textures: [dark],
            settings: .default
        )

        XCTAssertEqual(
            halfFloatRed(pixels, width: size, x: 6, y: 6),
            0,
            accuracy: 0.001
        )
    }

    func testTemporalPhosphorsDecayAtChannelSpecificRates() throws {
        let size = 8
        let black = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let previous = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0.5, 0.5, 0.5, 1)
        )
        let pixels = try renderTemporal(
            outputSize: SIMD2(size, size),
            textures: [black, black, black, black, black, previous],
            settings: ShaderSettings(
                intensity: 1,
                curvature: 0,
                scanlines: 0,
                mask: 0,
                glow: 0,
                vignette: 0,
                persistence: 0.5
            ),
            presentationDelta: 1 / 120,
            scanPhase: 0,
            scanSpan: 0
        )

        let red = halfFloatChannel(pixels, width: size, x: 4, y: 4, channel: 0)
        let green = halfFloatChannel(pixels, width: size, x: 4, y: 4, channel: 1)
        let blue = halfFloatChannel(pixels, width: size, x: 4, y: 4, channel: 2)
        XCTAssertGreaterThan(green, red)
        XCTAssertGreaterThan(red, blue)
        XCTAssertLessThan(green, 0.5)
        XCTAssertGreaterThan(blue, 0)
    }

    func testTemporalPresentationIntegratesRasterExposureWithoutVisibleStrobe() throws {
        let size = 8
        let current = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0.30, 0.30, 0.30, 0.30)
        )
        let black = try makeSolidFloatTexture(
            width: size,
            height: size,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        let settings = ShaderSettings(
            intensity: 1,
            curvature: 0,
            scanlines: 0,
            mask: 0,
            glow: 0,
            vignette: 0
        )
        let baseline = try render(
            function: "guestPhosphorMaskFragment",
            outputSize: SIMD2(size, size),
            outputFormat: .bgra8Unorm_srgb,
            textures: [current, black, black, black, black],
            settings: settings
        )
        let integrated = try renderTemporal(
            outputSize: SIMD2(size, size),
            textures: [current, black, black, black, black, black],
            settings: settings,
            presentationDelta: 1 / 120,
            scanPhase: 0,
            scanSpan: 0,
            readsDisplay: true
        )

        let reference = bgraPixel(baseline, width: size, x: 4, y: 4)
        let presented = bgraPixel(integrated, width: size, x: 4, y: 4)
        XCTAssertGreaterThan(reference.x, 20)
        XCTAssertLessThanOrEqual(abs(Int(reference.x) - Int(presented.x)), 3)
        XCTAssertLessThanOrEqual(abs(Int(reference.y) - Int(presented.y)), 3)
        XCTAssertLessThanOrEqual(abs(Int(reference.z) - Int(presented.z)), 3)
    }

    func testCompositeSignalHasFiniteLumaBandwidth() throws {
        let source = try makeStepTexture(width: 8, height: 4)
        let rgb = try renderPreparedRaw(
            colorTexture: source,
            settings: ShaderSettings(signalType: .rgb)
        )
        let composite = try renderPreparedRaw(
            colorTexture: source,
            settings: ShaderSettings(signalType: .compositeNTSC)
        )

        let rgbEdge = halfFloatRed(rgb, width: 8, x: 4, y: 2)
        let compositeEdge = halfFloatRed(composite, width: 8, x: 4, y: 2)
        XCTAssertGreaterThan(rgbEdge, 0.95)
        XCTAssertLessThan(compositeEdge, rgbEdge - 0.10)
        XCTAssertGreaterThan(compositeEdge, 0.45)
    }

    private var expectedEntryPoints: [(name: String, pixelFormats: [MTLPixelFormat])] {
        [
            ("phosphorBypassFragmentNV12", [.bgra8Unorm_srgb]),
            ("phosphorBypassFragmentBGRA", [.bgra8Unorm_srgb]),
            ("phosphorDecodeFragmentNV12", [.rgba16Float]),
            ("phosphorDecodeFragmentBGRA", [.rgba16Float]),
            (
                "guestPrepareFrameNV12Fragment",
                [.rgba16Float, .rgba16Float, .rgba16Float]
            ),
            (
                "guestPrepareFrameBGRAFragment",
                [.rgba16Float, .rgba16Float, .rgba16Float]
            ),
            ("guestAfterglowFragment", [.rgba16Float]),
            ("guestPrepassFragment", [.rgba16Float]),
            ("guestPrepassLinearizedFragment", [.rgba16Float]),
            ("guestLinearizeFragment", [.rgba16Float]),
            ("guestHDSharpenFragment", [.rgba16Float]),
            ("guestGlowHorizontalFragment", [.rgba16Float]),
            ("guestGlowVerticalFragment", [.rgba16Float]),
            ("guestBloomHorizontalFragment", [.rgba16Float]),
            ("guestBloomVerticalFragment", [.rgba16Float]),
            ("guestHDBeamFragment", [.rgba16Float]),
            ("guestPhosphorMaskFragment", [.bgra8Unorm_srgb]),
            (
                "guestPhosphorTemporalFragment",
                [.rgba16Float, .bgra8Unorm_srgb]
            ),
            (
                "guestPhosphorCachedTemporalFragment",
                [.rg11b10Float, .bgra8Unorm_srgb]
            )
        ]
    }

    private var maskEntryPoints: Set<String> {
        ["guestPhosphorMaskFragment", "guestPhosphorTemporalFragment"]
    }

    private func render(
        function: String,
        outputSize: SIMD2<Int>,
        outputFormat: MTLPixelFormat,
        textures: [any MTLTexture],
        sourceSize: SIMD2<Int>? = nil,
        settings: ShaderSettings,
        isInterlaced: Bool = false,
        fieldParity: Float = 0
    ) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }

        let library = try device.makeLibrary(source: ShaderLibrarySource.load(), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "phosphorFullscreenVertex")
        )
        descriptor.fragmentFunction = try fragmentFunction(
            named: function,
            library: library,
            usesSlotMask: maskEntryPoints.contains(function)
                ? settings.maskPattern == .slotMask
                : nil
        )
        descriptor.colorAttachments[0].pixelFormat = outputFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: outputFormat,
            width: outputSize.x,
            height: outputSize.y,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))

        let raster = sourceSize ?? SIMD2(textures[0].width, textures[0].height)
        var uniforms = ShaderUniforms(
            drawableSize: SIMD2(Float(outputSize.x), Float(outputSize.y)),
            sourceSize: SIMD2(Float(raster.x), Float(raster.y)),
            rasterSize: SIMD2(Float(raster.x), Float(raster.y)),
            settings: settings,
            yuvConversion: .make(matrix: .bt709, range: .full),
            isInterlaced: isInterlaced,
            fieldParity: fieldParity
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ShaderUniforms>.stride,
            index: 0
        )
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)

        let bytesPerPixel = outputFormat == .rgba16Float ? 8 : 4
        var pixels = [UInt8](
            repeating: 0,
            count: outputSize.x * outputSize.y * bytesPerPixel
        )
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(
                bytes.baseAddress!,
                bytesPerRow: outputSize.x * bytesPerPixel,
                from: MTLRegionMake2D(0, 0, outputSize.x, outputSize.y),
                mipmapLevel: 0
            )
        }
        return pixels
    }

    private func renderTemporal(
        outputSize: SIMD2<Int>,
        textures: [any MTLTexture],
        settings: ShaderSettings,
        presentationDelta: Float,
        scanPhase: Float,
        scanSpan: Float,
        readsDisplay: Bool = false
    ) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }
        let library = try device.makeLibrary(
            source: ShaderLibrarySource.load(),
            options: nil
        )
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "phosphorFullscreenVertex")
        )
        descriptor.fragmentFunction = try fragmentFunction(
            named: "guestPhosphorTemporalFragment",
            library: library,
            usesSlotMask: settings.maskPattern == .slotMask
        )
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.colorAttachments[1].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        func target(_ format: MTLPixelFormat) throws -> any MTLTexture {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: outputSize.x,
                height: outputSize.y,
                mipmapped: false
            )
            textureDescriptor.storageMode = .shared
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            return try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        }

        let excitation = try target(.rgba16Float)
        let display = try target(.bgra8Unorm_srgb)
        var uniforms = ShaderUniforms(
            drawableSize: SIMD2(Float(outputSize.x), Float(outputSize.y)),
            sourceSize: SIMD2(Float(outputSize.x), Float(outputSize.y)),
            rasterSize: SIMD2(Float(outputSize.x), Float(outputSize.y)),
            settings: settings,
            yuvConversion: .make(matrix: .bt709, range: .full),
            presentationDelta: presentationDelta,
            scanPhase: scanPhase,
            scanSpan: scanSpan,
            presentationHistoryIsValid: true
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = excitation
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = display
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].storeAction = .store
        let commandBuffer = try XCTUnwrap(
            device.makeCommandQueue()?.makeCommandBuffer()
        )
        let encoder = try XCTUnwrap(
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ShaderUniforms>.stride,
            index: 0
        )
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)

        let readTexture = readsDisplay ? display : excitation
        let bytesPerPixel = readsDisplay ? 4 : 8
        var pixels = [UInt8](
            repeating: 0,
            count: outputSize.x * outputSize.y * bytesPerPixel
        )
        pixels.withUnsafeMutableBytes { bytes in
            readTexture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: outputSize.x * bytesPerPixel,
                from: MTLRegionMake2D(0, 0, outputSize.x, outputSize.y),
                mipmapLevel: 0
            )
        }
        return pixels
    }

    private func renderPreparedRaw(
        colorTexture: any MTLTexture,
        settings: ShaderSettings
    ) throws -> [UInt8] {
        let device = colorTexture.device
        let library = try device.makeLibrary(
            source: ShaderLibrarySource.load(),
            options: nil
        )
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "phosphorFullscreenVertex")
        )
        descriptor.fragmentFunction = try XCTUnwrap(
            library.makeFunction(name: "guestPrepareFrameBGRAFragment")
        )
        for index in 0 ..< 3 {
            descriptor.colorAttachments[index].pixelFormat = .rgba16Float
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        func target() throws -> any MTLTexture {
            let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: colorTexture.width,
                height: colorTexture.height,
                mipmapped: false
            )
            targetDescriptor.storageMode = .shared
            targetDescriptor.usage = [.renderTarget, .shaderRead]
            return try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        }

        let raw = try target()
        let history = try target()
        let prepass = try target()
        let black = try makeSolidFloatTexture(
            width: colorTexture.width,
            height: colorTexture.height,
            color: SIMD4<Float>(0, 0, 0, 1)
        )
        var uniforms = ShaderUniforms(
            drawableSize: SIMD2(Float(colorTexture.width), Float(colorTexture.height)),
            sourceSize: SIMD2(Float(colorTexture.width), Float(colorTexture.height)),
            rasterSize: SIMD2(Float(colorTexture.width), Float(colorTexture.height)),
            settings: settings,
            yuvConversion: .make(matrix: .bt709, range: .full)
        )
        let pass = MTLRenderPassDescriptor()
        for (index, texture) in [raw, history, prepass].enumerated() {
            pass.colorAttachments[index].texture = texture
            pass.colorAttachments[index].loadAction = .clear
            pass.colorAttachments[index].storeAction = .store
        }
        let commandBuffer = try XCTUnwrap(
            device.makeCommandQueue()?.makeCommandBuffer()
        )
        let encoder = try XCTUnwrap(
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ShaderUniforms>.stride,
            index: 0
        )
        encoder.setFragmentTexture(colorTexture, index: 0)
        encoder.setFragmentTexture(black, index: 1)
        encoder.setFragmentTexture(black, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)

        var pixels = [UInt8](
            repeating: 0,
            count: colorTexture.width * colorTexture.height * 8
        )
        pixels.withUnsafeMutableBytes { bytes in
            raw.getBytes(
                bytes.baseAddress!,
                bytesPerRow: colorTexture.width * 8,
                from: MTLRegionMake2D(
                    0,
                    0,
                    colorTexture.width,
                    colorTexture.height
                ),
                mipmapLevel: 0
            )
        }
        return pixels
    }

    private func fragmentFunction(
        named name: String,
        library: any MTLLibrary,
        usesSlotMask: Bool?
    ) throws -> any MTLFunction {
        guard let usesSlotMask else {
            return try XCTUnwrap(library.makeFunction(name: name))
        }

        let constants = MTLFunctionConstantValues()
        var specializedSlotMask = usesSlotMask
        constants.setConstantValue(
            &specializedSlotMask,
            type: .bool,
            index: 0
        )
        return try library.makeFunction(
            name: name,
            constantValues: constants
        )
    }

    private func makeSolidTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        color: SIMD4<UInt8>
    ) throws -> any MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels = Array(repeating: color, count: width * height)
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    private func makeStepTexture(
        width: Int,
        height: Int
    ) throws -> any MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels = (0 ..< width * height).map { index in
            index % width < width / 2
                ? SIMD4<UInt8>(0, 0, 0, 255)
                : SIMD4<UInt8>(255, 255, 255, 255)
        }
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    private func makeSolidFloatTexture(
        width: Int,
        height: Int,
        color: SIMD4<Float>
    ) throws -> any MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let halfColor = SIMD4<UInt16>(
            Float16(color.x).bitPattern,
            Float16(color.y).bitPattern,
            Float16(color.z).bitPattern,
            Float16(color.w).bitPattern
        )
        let pixels = Array(repeating: halfColor, count: width * height)
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 8
            )
        }
        return texture
    }

    private func bgraPixel(
        _ pixels: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> SIMD4<UInt8> {
        let offset = (y * width + x) * 4
        return SIMD4(
            pixels[offset],
            pixels[offset + 1],
            pixels[offset + 2],
            pixels[offset + 3]
        )
    }

    private func halfFloatRed(
        _ pixels: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> Float {
        halfFloatChannel(pixels, width: width, x: x, y: y, channel: 0)
    }

    private func halfFloatChannel(
        _ pixels: [UInt8],
        width: Int,
        x: Int,
        y: Int,
        channel: Int
    ) -> Float {
        let offset = (y * width + x) * 8 + channel * 2
        let bits = UInt16(pixels[offset]) | UInt16(pixels[offset + 1]) << 8
        return Float(Float16(bitPattern: bits))
    }
}
