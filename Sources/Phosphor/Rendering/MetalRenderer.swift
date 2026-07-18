import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore

struct ShaderUniforms {
    var drawableSize: SIMD4<Float>
    var sourceSize: SIMD4<Float>
    var rasterSize: SIMD4<Float>
    var effect: SIMD4<Float>
    var effect2: SIMD4<Float>
    var guestBeam: SIMD4<Float>
    var guestLight: SIMD4<Float>
    var yuvRow0: SIMD4<Float>
    var yuvRow1: SIMD4<Float>
    var yuvRow2: SIMD4<Float>
    var frameData: SIMD4<Float>

    init(
        drawableSize: SIMD2<Float>,
        sourceSize: SIMD2<Float>,
        rasterSize: SIMD2<Float>,
        settings: ShaderSettings,
        yuvConversion: YUVConversion,
        frameCount: UInt64 = 0,
        historyIsValid: Bool = false
    ) {
        self.drawableSize = Self.sizeVector(drawableSize)
        self.sourceSize = Self.sizeVector(sourceSize)
        self.rasterSize = Self.sizeVector(rasterSize)
        effect = SIMD4(
            settings.intensity,
            settings.curvature,
            settings.scanlines,
            settings.mask
        )

        // Guest Advanced recommends larger mask pixels as physical output
        // resolution rises. These values are physical drawable pixels.
        let maskScale: Float = drawableSize.y >= 1_000 ? 2 : 1
        effect2 = SIMD4(
            settings.glow,
            settings.vignette,
            maskScale,
            0.20
        )

        // CRT-Guest-Advanced HD defaults for its beam and light response.
        guestBeam = SIMD4(6.0, 8.0, 1.20, 1.0)
        guestLight = SIMD4(0.10, 0.075, 1.40, 1.10)
        yuvRow0 = yuvConversion.red
        yuvRow1 = yuvConversion.green
        yuvRow2 = yuvConversion.blue
        frameData = SIMD4(
            Float(frameCount % 16_777_216),
            historyIsValid ? 1 : 0,
            0,
            0
        )
    }

    private static func sizeVector(_ size: SIMD2<Float>) -> SIMD4<Float> {
        SIMD4(
            size.x,
            size.y,
            1 / max(size.x, 1),
            1 / max(size.y, 1)
        )
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
    private let displayLink: CAMetalDisplayLink
    private let inFlightSemaphore = DispatchSemaphore(value: 1)

    private let bypassNV12Pipeline: any MTLRenderPipelineState
    private let bypassBGRAPipeline: any MTLRenderPipelineState
    private let decodeNV12Pipeline: any MTLRenderPipelineState
    private let decodeBGRAPipeline: any MTLRenderPipelineState
    private let afterglowPipeline: any MTLRenderPipelineState
    private let sharpenPipeline: any MTLRenderPipelineState
    private let glowHorizontalPipeline: any MTLRenderPipelineState
    private let glowVerticalPipeline: any MTLRenderPipelineState
    private let bloomHorizontalPipeline: any MTLRenderPipelineState
    private let bloomVerticalPipeline: any MTLRenderPipelineState
    private let beamPipeline: any MTLRenderPipelineState
    private let phosphorMaskPipeline: any MTLRenderPipelineState

    private var output: AVPlayerItemVideoOutput?
    private var settings = ShaderSettings.default
    private var lastPixelBuffer: CVPixelBuffer?
    private var drawableSize = SIMD2<Float>.zero
    private var renderTargets: GuestRenderTargets?
    private var frameCount: UInt64 = 0

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

        func pipeline(
            _ functionName: String,
            _ pixelFormat: MTLPixelFormat,
            _ label: String
        ) throws -> any MTLRenderPipelineState {
            let fragment = try Self.shaderFunction(named: functionName, in: library)
            return try Self.makePipeline(
                device: device,
                vertex: vertex,
                fragment: fragment,
                colorPixelFormat: pixelFormat,
                label: label
            )
        }

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        bypassNV12Pipeline = try pipeline(
            "phosphorBypassFragmentNV12",
            layer.pixelFormat,
            "Phosphor NV12 Bypass"
        )
        bypassBGRAPipeline = try pipeline(
            "phosphorBypassFragmentBGRA",
            layer.pixelFormat,
            "Phosphor BGRA Bypass"
        )
        decodeNV12Pipeline = try pipeline(
            "phosphorDecodeFragmentNV12",
            .rgba16Float,
            "Guest Decode NV12"
        )
        decodeBGRAPipeline = try pipeline(
            "phosphorDecodeFragmentBGRA",
            .rgba16Float,
            "Guest Decode BGRA"
        )
        afterglowPipeline = try pipeline(
            "guestAfterglowFragment",
            .rgba16Float,
            "Guest Afterglow"
        )
        sharpenPipeline = try pipeline(
            "guestHDSharpenFragment",
            .rgba16Float,
            "Guest HD Horizontal Reconstruction"
        )
        glowHorizontalPipeline = try pipeline(
            "guestGlowHorizontalFragment",
            .rgba16Float,
            "Guest Glow Horizontal"
        )
        glowVerticalPipeline = try pipeline(
            "guestGlowVerticalFragment",
            .rgba16Float,
            "Guest Glow Vertical"
        )
        bloomHorizontalPipeline = try pipeline(
            "guestBloomHorizontalFragment",
            .rgba16Float,
            "Guest Bloom Horizontal"
        )
        bloomVerticalPipeline = try pipeline(
            "guestBloomVerticalFragment",
            .rgba16Float,
            "Guest Bloom Vertical"
        )
        beamPipeline = try pipeline(
            "guestHDBeamFragment",
            .rgba16Float,
            "Guest HD Beam Reconstruction"
        )
        phosphorMaskPipeline = try pipeline(
            "guestPhosphorMaskFragment",
            layer.pixelFormat,
            "Guest Physical Phosphor Mask"
        )

        layer.device = device
        displayLink = CAMetalDisplayLink(metalLayer: layer)
        super.init()

        displayLink.delegate = self
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 24,
            maximum: 60,
            preferred: 60
        )
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
            renderTargets = nil
            frameCount = 0
        }
        self.output = output
        self.settings = settings
    }

    func setActive(_ isActive: Bool) {
        displayLink.isPaused = !isActive
    }

    func drawableSizeDidChange(_ size: CGSize) {
        let updatedSize = SIMD2(
            Float(max(size.width, 0)),
            Float(max(size.height, 0))
        )
        if updatedSize != drawableSize {
            renderTargets = nil
        }
        drawableSize = updatedSize
    }

    static func guestRasterSize(
        drawableSize: SIMD2<Float>,
        sourceSize: SIMD2<Float>
    ) -> SIMD2<Int> {
        guard drawableSize.x > 0,
              drawableSize.y > 0,
              sourceSize.x > 0,
              sourceSize.y > 0 else {
            return SIMD2(1, 1)
        }

        let sourceAspect = sourceSize.x / sourceSize.y
        let fittedHeight = min(drawableSize.y, drawableSize.x / sourceAspect)
        let beamHeight = min(
            Int(sourceSize.y.rounded(.down)),
            min(540, max(144, Int((fittedHeight / 2.6).rounded(.down))))
        )
        let approximateWidth = max(1, Int((Float(beamHeight) * sourceAspect).rounded()))
        let evenWidth = approximateWidth > 1
            ? approximateWidth - approximateWidth % 2
            : approximateWidth
        return SIMD2(max(evenWidth, 1), max(beamHeight, 1))
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
        commandBuffer.label = "Phosphor Guest Advanced Frame"

        let currentDrawableSize = SIMD2(
            Float(drawable.texture.width),
            Float(drawable.texture.height)
        )
        let raster = Self.guestRasterSize(
            drawableSize: currentDrawableSize,
            sourceSize: frame.sourceSize
        )
        let rasterSize = SIMD2(Float(raster.x), Float(raster.y))

        if settings.isBypassed {
            var uniforms = ShaderUniforms(
                drawableSize: currentDrawableSize,
                sourceSize: frame.sourceSize,
                rasterSize: rasterSize,
                settings: settings,
                yuvConversion: frame.yuvConversion,
                frameCount: frameCount
            )
            guard encodePass(
                commandBuffer: commandBuffer,
                pipeline: frame.bypassPipeline,
                target: drawable.texture,
                textures: frame.textures,
                uniforms: &uniforms,
                label: "Bypass"
            ) else {
                return
            }
        } else {
            guard let targets = targets(
                rasterSize: raster,
                drawableSize: SIMD2(drawable.texture.width, drawable.texture.height)
            ) else {
                return
            }

            var uniforms = ShaderUniforms(
                drawableSize: currentDrawableSize,
                sourceSize: frame.sourceSize,
                rasterSize: rasterSize,
                settings: settings,
                yuvConversion: frame.yuvConversion,
                frameCount: frameCount,
                historyIsValid: targets.historyIsValid
            )
            let historyRead = targets.history[targets.historyReadIndex]
            let historyWriteIndex = 1 - targets.historyReadIndex
            let historyWrite = targets.history[historyWriteIndex]

            guard encodePass(
                commandBuffer: commandBuffer,
                pipeline: frame.decodePipeline,
                target: targets.raw,
                textures: frame.textures,
                uniforms: &uniforms,
                label: "1 Decode and Linearize"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: afterglowPipeline,
                target: historyWrite,
                textures: [targets.raw, historyRead],
                uniforms: &uniforms,
                label: "2 Afterglow Feedback"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: sharpenPipeline,
                target: targets.sharpened,
                textures: [historyWrite],
                uniforms: &uniforms,
                label: "3 HD Horizontal Reconstruction"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: glowHorizontalPipeline,
                target: targets.glowHorizontal,
                textures: [targets.sharpened],
                uniforms: &uniforms,
                label: "4 Glow Horizontal"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: glowVerticalPipeline,
                target: targets.glow,
                textures: [targets.glowHorizontal],
                uniforms: &uniforms,
                label: "5 Glow Vertical"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: bloomHorizontalPipeline,
                target: targets.bloomHorizontal,
                textures: [targets.sharpened],
                uniforms: &uniforms,
                label: "6 Bloom Horizontal"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: bloomVerticalPipeline,
                target: targets.bloom,
                textures: [targets.bloomHorizontal],
                uniforms: &uniforms,
                label: "7 Bloom Vertical"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: beamPipeline,
                target: targets.beam,
                textures: [targets.sharpened, targets.bloom, historyWrite],
                uniforms: &uniforms,
                label: "8 Luminance-dependent Beam Reconstruction"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: phosphorMaskPipeline,
                target: drawable.texture,
                textures: [targets.beam, targets.raw, targets.glow, targets.bloom],
                uniforms: &uniforms,
                label: "9 Native-pixel Phosphor Mask"
            ) else {
                return
            }

            targets.historyReadIndex = historyWriteIndex
            targets.historyIsValid = true
        }

        let semaphore = inFlightSemaphore
        let resources = frame.resources
        commandBuffer.addCompletedHandler { _ in
            _ = resources
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        frameCount &+= 1
        mustSignalSemaphore = false
        commandBuffer.commit()
    }

    private func encodePass(
        commandBuffer: any MTLCommandBuffer,
        pipeline: any MTLRenderPipelineState,
        target: any MTLTexture,
        textures: [any MTLTexture],
        uniforms: inout ShaderUniforms,
        label: String
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            return false
        }

        encoder.label = label
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
        return true
    }

    private func targets(
        rasterSize: SIMD2<Int>,
        drawableSize: SIMD2<Int>
    ) -> GuestRenderTargets? {
        if let renderTargets,
           renderTargets.rasterSize == rasterSize,
           renderTargets.drawableSize == drawableSize {
            return renderTargets
        }

        renderTargets = GuestRenderTargets(
            device: device,
            rasterSize: rasterSize,
            drawableSize: drawableSize
        )
        return renderTargets
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
            return PreparedFrame(
                decodePipeline: decodeNV12Pipeline,
                bypassPipeline: bypassNV12Pipeline,
                textures: [lumaTexture, chromaTexture],
                sourceSize: SIMD2(
                    Float(CVPixelBufferGetWidth(pixelBuffer)),
                    Float(CVPixelBufferGetHeight(pixelBuffer))
                ),
                yuvConversion: .make(
                    matrix: matrixKind(for: pixelBuffer),
                    range: range
                ),
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
                decodePipeline: decodeBGRAPipeline,
                bypassPipeline: bypassBGRAPipeline,
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
    let decodePipeline: any MTLRenderPipelineState
    let bypassPipeline: any MTLRenderPipelineState
    let textures: [any MTLTexture]
    let sourceSize: SIMD2<Float>
    let yuvConversion: YUVConversion
    let resources: FrameResources
}

private final class GuestRenderTargets {
    let rasterSize: SIMD2<Int>
    let drawableSize: SIMD2<Int>
    let raw: any MTLTexture
    let history: [any MTLTexture]
    let sharpened: any MTLTexture
    let glowHorizontal: any MTLTexture
    let glow: any MTLTexture
    let bloomHorizontal: any MTLTexture
    let bloom: any MTLTexture
    let beam: any MTLTexture

    var historyReadIndex = 0
    var historyIsValid = false

    init?(
        device: any MTLDevice,
        rasterSize: SIMD2<Int>,
        drawableSize: SIMD2<Int>
    ) {
        func texture(
            width: Int,
            height: Int,
            label: String
        ) -> (any MTLTexture)? {
            guard width > 0, height > 0 else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            texture.label = label
            return texture
        }

        guard let raw = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest Raw Linear"
        ), let history0 = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest History A"
        ), let history1 = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest History B"
        ), let sharpened = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest Sharpened"
        ), let glowHorizontal = texture(
            width: 800,
            height: rasterSize.y,
            label: "Guest Glow Horizontal"
        ), let glow = texture(
            width: 800,
            height: 600,
            label: "Guest Glow"
        ), let bloomHorizontal = texture(
            width: 800,
            height: rasterSize.y,
            label: "Guest Bloom Horizontal"
        ), let bloom = texture(
            width: rasterSize.x,
            height: 600,
            label: "Guest Bloom"
        ), let beam = texture(
            width: drawableSize.x,
            height: drawableSize.y,
            label: "Guest Beam Reconstruction"
        ) else {
            return nil
        }

        self.rasterSize = rasterSize
        self.drawableSize = drawableSize
        self.raw = raw
        history = [history0, history1]
        self.sharpened = sharpened
        self.glowHorizontal = glowHorizontal
        self.glow = glow
        self.bloomHorizontal = bloomHorizontal
        self.bloom = bloom
        self.beam = beam
    }
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
