import Metal
import XCTest
@testable import Phosphor

final class MetalShaderTests: XCTestCase {
    func testBundledSourceContainsEveryEntryPoint() throws {
        let source = try ShaderLibrarySource.load()

        XCTAssertFalse(source.isEmpty)
        XCTAssertTrue(source.contains("phosphorFullscreenVertex"))
        XCTAssertTrue(source.contains("phosphorCRTFragmentNV12"))
        XCTAssertTrue(source.contains("phosphorCRTFragmentBGRA"))
    }

    func testBundledSourceCompilesAndBuildsBothPipelines() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }

        let library = try device.makeLibrary(source: ShaderLibrarySource.load(), options: nil)
        let vertex = try XCTUnwrap(library.makeFunction(name: "phosphorFullscreenVertex"))
        let fragments = [
            try XCTUnwrap(library.makeFunction(name: "phosphorCRTFragmentNV12")),
            try XCTUnwrap(library.makeFunction(name: "phosphorCRTFragmentBGRA"))
        ]

        for fragment in fragments {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

            XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: descriptor))
        }
    }

    func testZeroIntensityPreservesRawFittedCorner() throws {
        let size = 64
        let pixels = try renderSolidBGRA(
            width: size,
            height: size,
            color: (blue: 255, green: 255, red: 255, alpha: 255),
            effect: SIMD4(0, 0.25, 0, 0)
        )

        XCTAssertGreaterThan(pixels[2], 240, "Intensity zero must preserve the raw fitted corner")
    }

    func testScanlinesAlternateAtOneToOneScale() throws {
        let size = 8
        let pixels = try renderSolidBGRA(
            width: size,
            height: size,
            color: (blue: 200, green: 200, red: 200, alpha: 255),
            effect: SIMD4(1, 0, 1, 0)
        )
        let bytesPerRow = size * 4
        let upperRowRed = pixels[3 * bytesPerRow + 4 * 4 + 2]
        let lowerRowRed = pixels[4 * bytesPerRow + 4 * 4 + 2]

        XCTAssertGreaterThan(
            abs(Int(upperRowRed) - Int(lowerRowRed)),
            8,
            "Adjacent 1:1 source rows must land on different scanline phases"
        )
    }

    private func renderSolidBGRA(
        width: Int,
        height: Int,
        color: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        effect: SIMD4<Float>
    ) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this system")
        }

        let library = try device.makeLibrary(source: ShaderLibrarySource.load(), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(
            library.makeFunction(name: "phosphorFullscreenVertex")
        )
        descriptor.fragmentFunction = try XCTUnwrap(
            library.makeFunction(name: "phosphorCRTFragmentBGRA")
        )
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDescriptor))
        let pixel = [color.blue, color.green, color.red, color.alpha]
        let sourcePixels = Array(repeating: pixel, count: width * height).flatMap { $0 }
        sourcePixels.withUnsafeBytes { bytes in
            source.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4
            )
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .renderTarget
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))

        var uniforms = TestShaderUniforms(
            drawableSize: SIMD2(Float(width), Float(height)),
            sourceSize: SIMD2(Float(width), Float(height)),
            effect: effect,
            effect2: .zero,
            yuvRow0: .zero,
            yuvRow1: .zero,
            yuvRow2: .zero
        )
        XCTAssertEqual(MemoryLayout<TestShaderUniforms>.stride, 96)
        let uniformBuffer = try XCTUnwrap(device.makeBuffer(
            bytes: &uniforms,
            length: MemoryLayout<TestShaderUniforms>.stride
        ))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)

        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)
        outputPixels.withUnsafeMutableBytes { bytes in
            output.getBytes(
                bytes.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return outputPixels
    }
}

private struct TestShaderUniforms {
    var drawableSize: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var effect: SIMD4<Float>
    var effect2: SIMD4<Float>
    var yuvRow0: SIMD4<Float>
    var yuvRow1: SIMD4<Float>
    var yuvRow2: SIMD4<Float>
}
