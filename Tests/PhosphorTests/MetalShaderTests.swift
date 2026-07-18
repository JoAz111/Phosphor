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
}
