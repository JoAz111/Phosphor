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
    var guestColor: SIMD4<Float>
    var guestScan: SIMD4<Float>
    var guestMask: SIMD4<Float>
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
        historyIsValid: Bool = false,
        edrHeadroom: Float = 1
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
            Float(settings.maskPattern.rawValue)
        )

        // CRT-Guest-Advanced HD beam defaults with a Phosphor product preset
        // for visible neutral bloom and warm faceplate halation. The final
        // shader scales both light terms perceptually with the Tube Glow control.
        guestBeam = SIMD4(6.0, 8.0, 1.20, 1.0)
        guestLight = SIMD4(0.34, 0.12, 1.40, 1.10)
        guestColor = SIMD4(1.80, 1.75, 0.20, 0.50)
        guestScan = SIMD4(0.60, 0.75, 1.0, 2.40)
        guestMask = SIMD4(6.0, 1.10, 2.40, 1.0)
        yuvRow0 = yuvConversion.red
        yuvRow1 = yuvConversion.green
        yuvRow2 = yuvConversion.blue
        frameData = SIMD4(
            Float(frameCount % 16_777_216),
            historyIsValid ? 1 : 0,
            edrHeadroom.isFinite ? min(max(edrHeadroom, 1), 2) : 1,
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
    private let diagnostics: MetalFrameDiagnostics?
    private let inFlightSemaphore = DispatchSemaphore(value: 1)

    private let bypassNV12Pipeline: any MTLRenderPipelineState
    private let bypassBGRAPipeline: any MTLRenderPipelineState
    private let prepareNV12Pipeline: any MTLRenderPipelineState
    private let prepareBGRAPipeline: any MTLRenderPipelineState
    private let prepassLinearizedPipeline: any MTLRenderPipelineState
    private let sharpenPipeline: any MTLRenderPipelineState
    private let glowHorizontalPipeline: any MTLRenderPipelineState
    private let glowVerticalPipeline: any MTLRenderPipelineState
    private let bloomHorizontalPipeline: any MTLRenderPipelineState
    private let bloomVerticalPipeline: any MTLRenderPipelineState
    private let apertureMaskPipeline: any MTLRenderPipelineState
    private let slotMaskPipeline: any MTLRenderPipelineState

    private var output: AVPlayerItemVideoOutput?
    private var settings = ShaderSettings.default
    private var lastPixelBuffer: CVPixelBuffer?
    private var drawableSize = SIMD2<Float>.zero
    private var renderTargets: GuestRenderTargets?
    private var frameCount: UInt64 = 0
    private var edrHeadroom: Float = 1
    private var isPlaybackActive = false
    private var needsRedraw = false
    private var requestedPresentationTime: TimeInterval?
    private var awaitingRequestedFrame = false

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

        let library = try ShaderLibrarySource.makeLibrary(device: device)
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

        func multiTargetPipeline(
            _ functionName: String,
            _ pixelFormats: [MTLPixelFormat],
            _ label: String
        ) throws -> any MTLRenderPipelineState {
            let fragment = try Self.shaderFunction(named: functionName, in: library)
            return try Self.makePipeline(
                device: device,
                vertex: vertex,
                fragment: fragment,
                colorPixelFormats: pixelFormats,
                label: label
            )
        }

        func maskPipeline(
            usesSlotMask: Bool,
            label: String
        ) throws -> any MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues()
            var specializedSlotMask = usesSlotMask
            constants.setConstantValue(
                &specializedSlotMask,
                type: .bool,
                index: 0
            )
            let fragment = try library.makeFunction(
                name: "guestPhosphorMaskFragment",
                constantValues: constants
            )
            return try Self.makePipeline(
                device: device,
                vertex: vertex,
                fragment: fragment,
                colorPixelFormat: layer.pixelFormat,
                label: label
            )
        }

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        diagnostics = MetalFrameDiagnostics.makeIfRequested(device: device)
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
        prepareNV12Pipeline = try multiTargetPipeline(
            "guestPrepareFrameNV12Fragment",
            [.rgba16Float, .rgba16Float, .rgba16Float],
            "Guest NV12 Decode, History, and Linearized Prepass"
        )
        prepareBGRAPipeline = try multiTargetPipeline(
            "guestPrepareFrameBGRAFragment",
            [.rgba16Float, .rgba16Float, .rgba16Float],
            "Guest BGRA Decode, History, and Linearized Prepass"
        )
        prepassLinearizedPipeline = try pipeline(
            "guestPrepassLinearizedFragment",
            .rgba16Float,
            "Guest Linearized Color and Afterglow Prepass"
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
        apertureMaskPipeline = try maskPipeline(
            usesSlotMask: false,
            label: "Guest Aperture Grille"
        )
        slotMaskPipeline = try maskPipeline(
            usesSlotMask: true,
            label: "Guest Slot Mask"
        )

        layer.device = device
        displayLink = CAMetalDisplayLink(metalLayer: layer)
        super.init()

        displayLink.delegate = self
        displayLink.preferredFrameLatency = 1
        displayLink.preferredFrameRateRange = Self.preferredFrameRateRange(
            nominalFrameRate: 0
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    deinit {
        displayLink.invalidate()
    }

    func configure(
        output: AVPlayerItemVideoOutput?,
        settings: ShaderSettings,
        edrHeadroom: Float,
        nominalFrameRate: Float
    ) {
        if self.output !== output {
            lastPixelBuffer = nil
            renderTargets = nil
            frameCount = 0
            needsRedraw = output != nil
            awaitingRequestedFrame = false
        }
        if self.settings != settings {
            needsRedraw = output != nil
            if self.settings.isBypassed != settings.isBypassed {
                renderTargets = nil
            }
        }
        let sanitizedHeadroom = edrHeadroom.isFinite
            ? min(max(edrHeadroom, 1), 2)
            : 1
        if self.edrHeadroom != sanitizedHeadroom {
            self.edrHeadroom = sanitizedHeadroom
            needsRedraw = output != nil
        }
        self.output = output
        self.settings = settings
        displayLink.preferredFrameRateRange = Self.preferredFrameRateRange(
            nominalFrameRate: nominalFrameRate
        )
        updateDisplayLinkState()
    }

    static func preferredFrameRateRange(
        nominalFrameRate: Float
    ) -> CAFrameRateRange {
        let preferred = nominalFrameRate.isFinite
            && nominalFrameRate >= 1
            && nominalFrameRate <= 240
            ? nominalFrameRate
            : 60
        return CAFrameRateRange(
            minimum: min(preferred, 24),
            maximum: max(preferred, 60),
            preferred: preferred
        )
    }

    func setActive(_ isActive: Bool) {
        isPlaybackActive = isActive
        if isActive {
            awaitingRequestedFrame = false
        }
        updateDisplayLinkState()
    }

    func requestPresentation(at time: TimeInterval) {
        let sanitized = time.isFinite ? max(time, 0) : 0
        guard requestedPresentationTime != sanitized else { return }
        requestedPresentationTime = sanitized
        if !isPlaybackActive, output != nil {
            needsRedraw = true
            awaitingRequestedFrame = true
            updateDisplayLinkState()
        }
    }

    func drawableSizeDidChange(_ size: CGSize) {
        let updatedSize = SIMD2(
            Float(max(size.width, 0)),
            Float(max(size.height, 0))
        )
        if updatedSize != drawableSize {
            renderTargets = nil
            needsRedraw = output != nil
        }
        drawableSize = updatedSize
        updateDisplayLinkState()
    }

    static func shouldRender(
        hasNewPixelBuffer: Bool,
        needsRedraw: Bool,
        hasLastPixelBuffer: Bool
    ) -> Bool {
        hasLastPixelBuffer && (hasNewPixelBuffer || needsRedraw)
    }

    static func shouldAdvanceHistory(
        hasNewPixelBuffer: Bool,
        historyIsValid: Bool
    ) -> Bool {
        hasNewPixelBuffer || !historyIsValid
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
        try makePipeline(
            device: device,
            vertex: vertex,
            fragment: fragment,
            colorPixelFormats: [colorPixelFormat],
            label: label
        )
    }

    private static func makePipeline(
        device: any MTLDevice,
        vertex: any MTLFunction,
        fragment: any MTLFunction,
        colorPixelFormats: [MTLPixelFormat],
        label: String
    ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        for (index, pixelFormat) in colorPixelFormats.enumerated() {
            descriptor.colorAttachments[index].pixelFormat = pixelFormat
        }
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

        guard let frameUpdate = pixelBuffer(
            forHostTime: update.targetPresentationTimestamp
        ) else {
            return
        }
        guard Self.shouldRender(
            hasNewPixelBuffer: frameUpdate.isNew,
            needsRedraw: needsRedraw,
            hasLastPixelBuffer: true
        ) else {
            updateDisplayLinkState()
            return
        }

        guard let frame = makeFrame(from: frameUpdate.pixelBuffer) else {
            return
        }

        let drawable = update.drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        commandBuffer.label = "Phosphor Guest Advanced Frame"
        diagnostics?.beginFrame()

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
                frameCount: frameCount,
                edrHeadroom: edrHeadroom
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
            guard let targets = targets(rasterSize: raster) else {
                return
            }

            var uniforms = ShaderUniforms(
                drawableSize: currentDrawableSize,
                sourceSize: frame.sourceSize,
                rasterSize: rasterSize,
                settings: settings,
                yuvConversion: frame.yuvConversion,
                frameCount: frameCount,
                historyIsValid: targets.historyIsValid,
                edrHeadroom: edrHeadroom
            )
            let historyRead = targets.history[targets.historyReadIndex]
            let historyWriteIndex = 1 - targets.historyReadIndex
            let historyWrite = targets.history[historyWriteIndex]
            let advancesHistory = Self.shouldAdvanceHistory(
                hasNewPixelBuffer: frameUpdate.isNew,
                historyIsValid: targets.historyIsValid
            )
            let decodesSource = frameUpdate.isNew || !targets.rawIsValid
            let rawWriteIndex = decodesSource
                ? 1 - targets.rawReadIndex
                : targets.rawReadIndex
            let currentRaw = targets.raw[rawWriteIndex]
            let previousRaw = targets.raw[targets.rawReadIndex]
            let preparesFreshFrame = decodesSource && advancesHistory

            if preparesFreshFrame {
                guard encodePass(
                    commandBuffer: commandBuffer,
                    pipeline: frame.preparePipeline,
                    targets: [
                        currentRaw,
                        historyWrite,
                        targets.prepassLinearized
                    ],
                    textures: frame.textures + [previousRaw, historyRead],
                    uniforms: &uniforms,
                    label: "1 Decode, History, and Linearized Prepass"
                ) else {
                    return
                }
            } else {
                guard encodePass(
                    commandBuffer: commandBuffer,
                    pipeline: prepassLinearizedPipeline,
                    target: targets.prepassLinearized,
                    textures: [currentRaw, historyRead],
                    uniforms: &uniforms,
                    label: "1 Linearized Color and Persistence Prepass"
                ) else {
                    return
                }
            }

            guard encodePass(
                commandBuffer: commandBuffer,
                pipeline: sharpenPipeline,
                target: targets.sharpened,
                textures: [targets.prepassLinearized],
                uniforms: &uniforms,
                label: "2 HD Horizontal Reconstruction"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: glowHorizontalPipeline,
                target: targets.lightHorizontal,
                textures: [targets.prepassLinearized],
                uniforms: &uniforms,
                label: "3 Glow Horizontal"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: glowVerticalPipeline,
                target: targets.glow,
                textures: [targets.lightHorizontal],
                uniforms: &uniforms,
                label: "4 Glow Vertical"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: bloomHorizontalPipeline,
                target: targets.lightHorizontal,
                textures: [targets.prepassLinearized],
                uniforms: &uniforms,
                label: "5 Bloom Horizontal"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: bloomVerticalPipeline,
                target: targets.bloom,
                textures: [targets.lightHorizontal],
                uniforms: &uniforms,
                label: "6 Bloom Vertical"
            ), encodePass(
                commandBuffer: commandBuffer,
                pipeline: settings.maskPattern == .slotMask
                    ? slotMaskPipeline
                    : apertureMaskPipeline,
                target: drawable.texture,
                textures: [
                    targets.sharpened,
                    targets.bloom,
                    targets.prepassLinearized,
                    targets.glow,
                    currentRaw
                ],
                uniforms: &uniforms,
                label: "7 Beam, Native-pixel Phosphor Mask, and Glass"
            ) else {
                return
            }

            if advancesHistory {
                targets.historyReadIndex = historyWriteIndex
                targets.historyIsValid = true
            }
            if decodesSource {
                targets.rawReadIndex = rawWriteIndex
                targets.rawIsValid = true
            }
        }

        let semaphore = inFlightSemaphore
        let resources = frame.resources
        let diagnostics = diagnostics
        commandBuffer.addCompletedHandler { completedBuffer in
            _ = resources
            diagnostics?.completeFrame(commandBuffer: completedBuffer)
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        needsRedraw = false
        if frameUpdate.isNew {
            frameCount &+= 1
        }
        updateDisplayLinkState()
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
        encodePass(
            commandBuffer: commandBuffer,
            pipeline: pipeline,
            targets: [target],
            textures: textures,
            uniforms: &uniforms,
            label: label
        )
    }

    private func encodePass(
        commandBuffer: any MTLCommandBuffer,
        pipeline: any MTLRenderPipelineState,
        targets: [any MTLTexture],
        textures: [any MTLTexture],
        uniforms: inout ShaderUniforms,
        label: String
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        for (index, target) in targets.enumerated() {
            pass.colorAttachments[index].texture = target
            pass.colorAttachments[index].loadAction = .dontCare
            pass.colorAttachments[index].storeAction = .store
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            return false
        }

        encoder.label = label
        diagnostics?.beginPass(label, encoder: encoder)
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
        diagnostics?.endPass(encoder: encoder)
        encoder.endEncoding()
        return true
    }

    private func targets(rasterSize: SIMD2<Int>) -> GuestRenderTargets? {
        if let renderTargets,
           renderTargets.rasterSize == rasterSize {
            return renderTargets
        }

        renderTargets = GuestRenderTargets(
            device: device,
            rasterSize: rasterSize
        )
        return renderTargets
    }

    private func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> VideoFrameUpdate? {
        guard let output else {
            guard let lastPixelBuffer else { return nil }
            return VideoFrameUpdate(pixelBuffer: lastPixelBuffer, isNew: false)
        }

        let usesRequestedTime = !isPlaybackActive && requestedPresentationTime != nil
        let itemTime = usesRequestedTime
            ? CMTime(
                seconds: requestedPresentationTime ?? 0,
                preferredTimescale: 600
            )
            : output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = output.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            lastPixelBuffer = pixelBuffer
            awaitingRequestedFrame = false
            return VideoFrameUpdate(pixelBuffer: pixelBuffer, isNew: true)
        }
        if usesRequestedTime, awaitingRequestedFrame {
            return nil
        }
        guard let lastPixelBuffer else { return nil }
        return VideoFrameUpdate(pixelBuffer: lastPixelBuffer, isNew: false)
    }

    private func updateDisplayLinkState() {
        displayLink.isPaused = !(isPlaybackActive || needsRedraw)
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
                preparePipeline: prepareNV12Pipeline,
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
                preparePipeline: prepareBGRAPipeline,
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

private struct VideoFrameUpdate {
    let pixelBuffer: CVPixelBuffer
    let isNew: Bool
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
    let preparePipeline: any MTLRenderPipelineState
    let bypassPipeline: any MTLRenderPipelineState
    let textures: [any MTLTexture]
    let sourceSize: SIMD2<Float>
    let yuvConversion: YUVConversion
    let resources: FrameResources
}

private final class GuestRenderTargets {
    let rasterSize: SIMD2<Int>
    let raw: [any MTLTexture]
    let history: [any MTLTexture]
    let prepassLinearized: any MTLTexture
    let sharpened: any MTLTexture
    let lightHorizontal: any MTLTexture
    let glow: any MTLTexture
    let bloom: any MTLTexture

    var rawReadIndex = 0
    var rawIsValid = false
    var historyReadIndex = 0
    var historyIsValid = false

    init?(
        device: any MTLDevice,
        rasterSize: SIMD2<Int>
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

        guard let raw0 = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest Encoded Source A"
        ), let raw1 = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest Encoded Source B"
        ), let history0 = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest History A"
        ), let history1 = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest History B"
        ), let prepassLinearized = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest Linearized Color Prepass"
        ), let sharpened = texture(
            width: rasterSize.x,
            height: rasterSize.y,
            label: "Guest Sharpened"
        ), let lightHorizontal = texture(
            width: 800,
            height: rasterSize.y,
            label: "Guest Horizontal Light Scratch"
        ), let glow = texture(
            width: 800,
            height: 600,
            label: "Guest Glow"
        ), let bloom = texture(
            width: rasterSize.x,
            height: 600,
            label: "Guest Bloom"
        ) else {
            return nil
        }

        self.rasterSize = rasterSize
        raw = [raw0, raw1]
        history = [history0, history1]
        self.prepassLinearized = prepassLinearized
        self.sharpened = sharpened
        self.lightHorizontal = lightHorizontal
        self.glow = glow
        self.bloom = bloom
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
