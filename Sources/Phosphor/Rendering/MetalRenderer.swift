import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore

struct ShaderUniforms {
    var drawableSize: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var effect: SIMD4<Float>
    var effect2: SIMD4<Float>
    var yuvRow0: SIMD4<Float>
    var yuvRow1: SIMD4<Float>
    var yuvRow2: SIMD4<Float>

    init(
        drawableSize: SIMD2<Float>,
        sourceSize: SIMD2<Float>,
        settings: ShaderSettings,
        yuvConversion: YUVConversion
    ) {
        self.drawableSize = drawableSize
        self.sourceSize = sourceSize
        effect = SIMD4(
            settings.intensity,
            settings.curvature,
            settings.scanlines,
            settings.mask
        )
        effect2 = SIMD4(settings.glow, settings.vignette, 0, 0)
        yuvRow0 = yuvConversion.red
        yuvRow1 = yuvConversion.green
        yuvRow2 = yuvConversion.blue
    }
}

final class MetalRenderer: NSObject {
    enum InitializationError: Error {
        case metalUnavailable
        case commandQueueUnavailable
        case textureCacheUnavailable(CVReturn)
        case shaderFunctionMissing(String)
    }

    let device: any MTLDevice

    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let nv12Pipeline: any MTLRenderPipelineState
    private let bgraPipeline: any MTLRenderPipelineState
    private let displayLink: CAMetalDisplayLink
    private let inFlightSemaphore = DispatchSemaphore(value: 3)

    private var output: AVPlayerItemVideoOutput?
    private var settings = ShaderSettings.default
    private var lastPixelBuffer: CVPixelBuffer?
    private var drawableSize = SIMD2<Float>.zero

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw InitializationError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw InitializationError.commandQueueUnavailable
        }

        var textureCache: CVMetalTextureCache?
        let textureCacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard textureCacheStatus == kCVReturnSuccess,
              let textureCache else {
            throw InitializationError.textureCacheUnavailable(textureCacheStatus)
        }

        let library = try device.makeLibrary(
            source: ShaderLibrarySource.load(),
            options: nil
        )
        let vertex = try Self.shaderFunction(
            named: "phosphorFullscreenVertex",
            in: library
        )
        let nv12Fragment = try Self.shaderFunction(
            named: "phosphorCRTFragmentNV12",
            in: library
        )
        let bgraFragment = try Self.shaderFunction(
            named: "phosphorCRTFragmentBGRA",
            in: library
        )

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        nv12Pipeline = try Self.makePipeline(
            device: device,
            vertex: vertex,
            fragment: nv12Fragment,
            colorPixelFormat: layer.pixelFormat,
            label: "Phosphor NV12 Pipeline"
        )
        bgraPipeline = try Self.makePipeline(
            device: device,
            vertex: vertex,
            fragment: bgraFragment,
            colorPixelFormat: layer.pixelFormat,
            label: "Phosphor BGRA Pipeline"
        )

        layer.device = device
        displayLink = CAMetalDisplayLink(metalLayer: layer)
        super.init()

        displayLink.delegate = self
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    deinit {
        displayLink.invalidate()
    }

    func configure(
        output: AVPlayerItemVideoOutput?,
        settings: ShaderSettings
    ) {
        if self.output !== output {
            lastPixelBuffer = nil
        }
        self.output = output
        self.settings = settings
    }

    func setActive(_ isActive: Bool) {
        displayLink.isPaused = !isActive
    }

    func drawableSizeDidChange(_ size: CGSize) {
        drawableSize = SIMD2(
            Float(max(size.width, 0)),
            Float(max(size.height, 0))
        )
    }

    private static func shaderFunction(
        named name: String,
        in library: any MTLLibrary
    ) throws -> any MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw InitializationError.shaderFunctionMissing(name)
        }
        return function
    }

    private static func makePipeline(
        device: any MTLDevice,
        vertex: any MTLFunction,
        fragment: any MTLFunction,
        colorPixelFormat: MTLPixelFormat,
        label: String
    ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func render(_ update: CAMetalDisplayLink.Update) {
        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            return
        }

        var mustSignalSemaphore = true
        defer {
            if mustSignalSemaphore {
                inFlightSemaphore.signal()
            }
        }

        guard let pixelBuffer = pixelBuffer(
            forHostTime: update.targetPresentationTimestamp
        ), let frame = makeFrame(from: pixelBuffer) else {
            return
        }

        let drawable = update.drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            return
        }

        let currentDrawableSize = drawableSize.x > 0 && drawableSize.y > 0
            ? drawableSize
            : SIMD2(
                Float(drawable.texture.width),
                Float(drawable.texture.height)
            )
        var uniforms = ShaderUniforms(
            drawableSize: currentDrawableSize,
            sourceSize: frame.sourceSize,
            settings: settings,
            yuvConversion: frame.yuvConversion
        )

        encoder.label = "Phosphor CRT Render Encoder"
        encoder.setRenderPipelineState(frame.pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ShaderUniforms>.stride,
            index: 0
        )
        for (index, texture) in frame.textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        // Sampling is declared constexpr in the compiled Metal shader.
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        encoder.endEncoding()

        let semaphore = inFlightSemaphore
        let resources = frame.resources
        commandBuffer.addCompletedHandler { _ in
            _ = resources
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        mustSignalSemaphore = false
        commandBuffer.commit()
    }

    private func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
        guard let output else {
            return lastPixelBuffer
        }

        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = output.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            lastPixelBuffer = pixelBuffer
        }
        return lastPixelBuffer
    }

    private func makeFrame(from pixelBuffer: CVPixelBuffer) -> PreparedFrame? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferIsPlanar(pixelBuffer),
                  CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
                  let luma = makeTexture(
                      from: pixelBuffer,
                      pixelFormat: .r8Unorm,
                      width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                      height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                      planeIndex: 0
                  ), let chroma = makeTexture(
                      from: pixelBuffer,
                      pixelFormat: .rg8Unorm,
                      width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                      height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                      planeIndex: 1
                  ), let lumaTexture = CVMetalTextureGetTexture(luma),
                  let chromaTexture = CVMetalTextureGetTexture(chroma) else {
                return nil
            }

            let range: YUVRange = format
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ? .full
                : .video
            let conversion = YUVConversion.make(
                matrix: matrixKind(for: pixelBuffer),
                range: range
            )
            return PreparedFrame(
                pipeline: nv12Pipeline,
                textures: [lumaTexture, chromaTexture],
                sourceSize: SIMD2(
                    Float(CVPixelBufferGetWidth(pixelBuffer)),
                    Float(CVPixelBufferGetHeight(pixelBuffer))
                ),
                yuvConversion: conversion,
                resources: FrameResources(
                    pixelBuffer: pixelBuffer,
                    textureWrappers: [luma, chroma]
                )
            )

        case kCVPixelFormatType_32BGRA:
            guard !CVPixelBufferIsPlanar(pixelBuffer),
                  let wrapper = makeTexture(
                      from: pixelBuffer,
                      pixelFormat: .bgra8Unorm,
                      width: CVPixelBufferGetWidth(pixelBuffer),
                      height: CVPixelBufferGetHeight(pixelBuffer),
                      planeIndex: 0
                  ), let texture = CVMetalTextureGetTexture(wrapper) else {
                return nil
            }

            return PreparedFrame(
                pipeline: bgraPipeline,
                textures: [texture],
                sourceSize: SIMD2(
                    Float(CVPixelBufferGetWidth(pixelBuffer)),
                    Float(CVPixelBufferGetHeight(pixelBuffer))
                ),
                yuvConversion: .make(matrix: .bt709, range: .full),
                resources: FrameResources(
                    pixelBuffer: pixelBuffer,
                    textureWrappers: [wrapper]
                )
            )

        default:
            return nil
        }
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) -> CVMetalTexture? {
        guard width > 0, height > 0 else {
            return nil
        }

        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &texture
        )
        guard status == kCVReturnSuccess else {
            return nil
        }
        return texture
    }

    private func matrixKind(for pixelBuffer: CVPixelBuffer) -> YUVMatrixKind {
        guard let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil
        ) else {
            return .bt709
        }

        if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            return .bt601
        }
        return .bt709
    }
}

extension MetalRenderer: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        render(update)
    }
}

private struct PreparedFrame {
    let pipeline: any MTLRenderPipelineState
    let textures: [any MTLTexture]
    let sourceSize: SIMD2<Float>
    let yuvConversion: YUVConversion
    let resources: FrameResources
}

private final class FrameResources: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let textureWrappers: [CVMetalTexture]

    init(
        pixelBuffer: CVPixelBuffer,
        textureWrappers: [CVMetalTexture]
    ) {
        self.pixelBuffer = pixelBuffer
        self.textureWrappers = textureWrappers
    }
}
