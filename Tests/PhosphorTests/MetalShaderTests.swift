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
            descriptor.fragmentFunction = try XCTUnwrap(
                library.makeFunction(name: entryPoint.name)
            )
            descriptor.colorAttachments[0].pixelFormat = entryPoint.pixelFormat
            XCTAssertNoThrow(
                try device.makeRenderPipelineState(descriptor: descriptor),
                entryPoint.name
            )
        }
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
        let beam = try makeSolidFloatTexture(
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
            textures: [beam, black, black, black, black, black],
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

    func testTubeGlowAddsNeutralBloomAndWarmHalation() throws {
        let size = 12
        let beam = try makeSolidFloatTexture(
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
            textures: [beam, black, bloom, black, black, black],
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
            textures: [beam, black, bloom, black, black, black],
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

    private var expectedEntryPoints: [(name: String, pixelFormat: MTLPixelFormat)] {
        [
            ("phosphorBypassFragmentNV12", .bgra8Unorm_srgb),
            ("phosphorBypassFragmentBGRA", .bgra8Unorm_srgb),
            ("phosphorDecodeFragmentNV12", .rgba16Float),
            ("phosphorDecodeFragmentBGRA", .rgba16Float),
            ("guestAfterglowFragment", .rgba16Float),
            ("guestPrepassFragment", .rgba16Float),
            ("guestLinearizeFragment", .rgba16Float),
            ("guestHDSharpenFragment", .rgba16Float),
            ("guestGlowHorizontalFragment", .rgba16Float),
            ("guestGlowVerticalFragment", .rgba16Float),
            ("guestBloomHorizontalFragment", .rgba16Float),
            ("guestBloomVerticalFragment", .rgba16Float),
            ("guestHDBeamFragment", .rgba16Float),
            ("guestPhosphorMaskFragment", .bgra8Unorm_srgb)
        ]
    }

    private func render(
        function: String,
        outputSize: SIMD2<Int>,
        outputFormat: MTLPixelFormat,
        textures: [any MTLTexture],
        sourceSize: SIMD2<Int>? = nil,
        settings: ShaderSettings
    ) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }

        let library = try device.makeLibrary(source: ShaderLibrarySource.load(), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "phosphorFullscreenVertex")
        )
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: function))
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
            yuvConversion: .make(matrix: .bt709, range: .full)
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
