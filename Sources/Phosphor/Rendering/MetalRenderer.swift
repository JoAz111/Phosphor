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
    var temporalData: SIMD4<Float>
    var temporalResponse: SIMD4<Float>
    var tubeData: SIMD4<Float>
    var videoData: SIMD4<Float>

    init(
        drawableSize: SIMD2<Float>,
        sourceSize: SIMD2<Float>,
        rasterSize: SIMD2<Float>,
        settings: ShaderSettings,
        yuvConversion: YUVConversion,
        frameCount: UInt64 = 0,
        historyIsValid: Bool = false,
        edrHeadroom: Float = 1,
        presentationTimestamp: TimeInterval = 0,
        presentationDelta: Float = 1 / 60,
        scanPhase: Float = 0,
        scanSpan: Float = 1,
        presentationHistoryIsValid: Bool = false,
        isInterlaced: Bool = false,
        fieldParity: Float = 0
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

        // A slot cell needs at least three native pixels across to represent a
        // bright phosphor center and its surrounding black matrix. Aperture
        // stripes can remain finer because they are continuous vertically.
        let maskScale: Float = settings.maskPattern == .slotMask
            ? 3
            : (drawableSize.y >= 1_000 ? 2 : 1)
        effect2 = SIMD4(
            settings.glow,
            settings.vignette,
            maskScale,
            Float(settings.maskPattern.rawValue)
        )

        // Each tube family uses a coherent optical/beam preset rather than a
        // cosmetic color grade. Individual controls scale these calibrations.
        switch settings.tubeProfile {
        case .consumerTV:
            guestBeam = SIMD4(6.0, 8.0, 1.20, 1.0)
            guestLight = SIMD4(0.34, 0.12, 1.40, 1.10)
            guestColor = SIMD4(1.80, 1.75, 0.20, 0.50)
            guestScan = SIMD4(0.60, 0.75, 1.0, 2.40)
            guestMask = SIMD4(6.0, 1.10, 2.40, 1.0)
        case .trinitron:
            guestBeam = SIMD4(6.4, 8.4, 1.12, 0.94)
            guestLight = SIMD4(0.30, 0.075, 1.34, 1.08)
            guestColor = SIMD4(1.82, 1.76, 0.18, 0.48)
            guestScan = SIMD4(0.64, 0.70, 1.0, 2.35)
            guestMask = SIMD4(6.0, 1.08, 2.35, 1.0)
        case .professionalMonitor:
            guestBeam = SIMD4(7.2, 9.0, 1.02, 0.88)
            guestLight = SIMD4(0.22, 0.045, 1.25, 1.05)
            guestColor = SIMD4(1.86, 1.78, 0.14, 0.46)
            guestScan = SIMD4(0.68, 0.62, 1.0, 2.30)
            guestMask = SIMD4(6.0, 1.06, 2.30, 1.0)
        }
        yuvRow0 = yuvConversion.red
        yuvRow1 = yuvConversion.green
        yuvRow2 = yuvConversion.blue
        frameData = SIMD4(
            Float(frameCount % 16_777_216),
            historyIsValid ? 1 : 0,
            edrHeadroom.isFinite ? min(max(edrHeadroom, 1), 2) : 1,
            0
        )
        let timestamp = presentationTimestamp.isFinite
            ? Float(presentationTimestamp.truncatingRemainder(dividingBy: 1_024))
            : 0
        temporalData = SIMD4(
            timestamp,
            presentationDelta.isFinite ? min(max(presentationDelta, 1 / 1_000), 0.1) : 1 / 60,
            scanPhase.isFinite ? scanPhase - floor(scanPhase) : 0,
            scanSpan.isFinite ? min(max(scanSpan, 0), 1) : 1
        )
        let persistence = settings.persistence
        let lifetime = SIMD3<Float>(
            0.010 + (0.030 - 0.010) * persistence,
            0.014 + (0.050 - 0.014) * persistence,
            0.008 + (0.022 - 0.008) * persistence
        )
        let delta = temporalData.y
        temporalResponse = SIMD4(
            exp(-delta / lifetime.x),
            exp(-delta / lifetime.y),
            exp(-delta / lifetime.z),
            0.985 + (0.998 - 0.985) * persistence
        )
        tubeData = SIMD4(
            settings.persistence,
            settings.convergence,
            settings.focus,
            Float(settings.tubeProfile.rawValue)
        )
        videoData = SIMD4(
            isInterlaced ? 1 : 0,
            fieldParity >= 0.5 ? 1 : 0,
            Float(settings.signalType.rawValue),
            presentationHistoryIsValid ? 1 : 0
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
    private let frameBudgetController = MetalFrameBudgetController()
    private let inFlightSemaphore = DispatchSemaphore(value: 1)
    private let statePixelFormat: MTLPixelFormat

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
    private let apertureEmissionPipeline: any MTLRenderPipelineState
    private let slotEmissionPipeline: any MTLRenderPipelineState
    private let cachedTemporalPipeline: any MTLRenderPipelineState

    private var videoSource: (any VideoFrameSource)?
    private var settings = ShaderSettings.default
    private var lastPixelBuffer: CVPixelBuffer?
    private var cachedFrame: PreparedFrame?
    private var drawableSize = SIMD2<Float>.zero
    private var renderTargets: GuestRenderTargets?
    private var frameCount: UInt64 = 0
    private var edrHeadroom: Float = 1
    private var isPlaybackActive = false
    private var isPresentationVisible = false
    private var needsRedraw = false
    private var needsSourceReconstruction = false
    private var requestedPresentationTime: TimeInterval?
    private var awaitingRequestedFrame = false
    private var scanMetadata = VideoScanMetadata.progressive
    private var nominalFrameRate: Float = 0
    private var maximumDisplayFrameRate: Float = 60
    private var appliedMaximumFrameRate: Float = 60
    private var lastPresentationTimestamp: CFTimeInterval?

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

        func emissionPipeline(
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
                colorPixelFormat: .rgba16Float,
                label: label
            )
        }

        let statePixelFormat: MTLPixelFormat = device.supportsFamily(.apple1)
            ? .rg11b10Float
            : .rgba16Float

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.statePixelFormat = statePixelFormat
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
        apertureEmissionPipeline = try emissionPipeline(
            usesSlotMask: false,
            label: "Guest Aperture Grille Tube Emission"
        )
        slotEmissionPipeline = try emissionPipeline(
            usesSlotMask: true,
            label: "Guest Slot Mask Tube Emission"
        )
        cachedTemporalPipeline = try multiTargetPipeline(
            "guestPhosphorCachedTemporalFragment",
            [statePixelFormat, layer.pixelFormat],
            "Guest Cached Temporal Presentation"
        )

        layer.device = device
        displayLink = CAMetalDisplayLink(metalLayer: layer)
        super.init()

        displayLink.delegate = self
        displayLink.preferredFrameLatency = 1
        displayLink.preferredFrameRateRange = Self.preferredFrameRateRange(
            nominalFrameRate: 0,
            maximumDisplayFrameRate: 60,
            simulatesCRT: true
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    deinit {
        displayLink.invalidate()
    }

    func configure(
        source: (any VideoFrameSource)?,
        settings: ShaderSettings,
        edrHeadroom: Float,
        nominalFrameRate: Float,
        scanMetadata: VideoScanMetadata,
        maximumDisplayFrameRate: Float
    ) {
        if self.videoSource !== source {
            frameBudgetController.reset()
            lastPixelBuffer = nil
            cachedFrame = nil
            renderTargets = nil
            frameCount = 0
            needsRedraw = source != nil
            needsSourceReconstruction = source != nil
            awaitingRequestedFrame = false
            lastPresentationTimestamp = nil
        }
        if self.settings != settings {
            needsRedraw = source != nil
            needsSourceReconstruction = source != nil
            if self.settings.isBypassed != settings.isBypassed
                || self.settings.rasterMode != settings.rasterMode {
                renderTargets = nil
            }
        }
        if self.scanMetadata != scanMetadata {
            self.scanMetadata = scanMetadata
            needsRedraw = source != nil
            needsSourceReconstruction = source != nil
            renderTargets = nil
        }
        let sanitizedHeadroom = edrHeadroom.isFinite
            ? min(max(edrHeadroom, 1), 2)
            : 1
        if self.edrHeadroom != sanitizedHeadroom {
            self.edrHeadroom = sanitizedHeadroom
            needsRedraw = source != nil
            needsSourceReconstruction = source != nil
        }
        self.videoSource = source
        self.settings = settings
        self.nominalFrameRate = nominalFrameRate
        self.maximumDisplayFrameRate = Self.sanitizedMaximumFrameRate(
            maximumDisplayFrameRate
        )
        applyAdaptiveFrameRate(force: true)
        updateDisplayLinkState()
    }

    static func preferredFrameRateRange(
        nominalFrameRate: Float,
        maximumDisplayFrameRate: Float = 60,
        simulatesCRT: Bool = false
    ) -> CAFrameRateRange {
        let displayMaximum = sanitizedMaximumFrameRate(maximumDisplayFrameRate)
        if simulatesCRT {
            return CAFrameRateRange(
                minimum: min(displayMaximum, 60),
                maximum: displayMaximum,
                preferred: displayMaximum
            )
        }
        let preferred = nominalFrameRate.isFinite
            && nominalFrameRate >= 1
            && nominalFrameRate <= 240
            ? min(nominalFrameRate, displayMaximum)
            : min(60, displayMaximum)
        return CAFrameRateRange(
            minimum: min(preferred, 24),
            maximum: displayMaximum,
            preferred: preferred
        )
    }

    /// Clamps screen-reported refresh rates into CAMetalDisplayLink's useful range.
    private static func sanitizedMaximumFrameRate(_ value: Float) -> Float {
        guard value.isFinite, value >= 24 else { return 60 }
        return min(value, 240)
    }

    func setActive(_ isActive: Bool, isVisible: Bool = true) {
        isPlaybackActive = isActive
        isPresentationVisible = isVisible
        if isActive {
            awaitingRequestedFrame = false
        }
        updateDisplayLinkState()
    }

    func requestPresentation(at time: TimeInterval) {
        let sanitized = time.isFinite ? max(time, 0) : 0
        guard requestedPresentationTime != sanitized else { return }
        requestedPresentationTime = sanitized
        if !isPlaybackActive, videoSource != nil {
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
            needsRedraw = videoSource != nil
        }
        drawableSize = updatedSize
        updateDisplayLinkState()
    }

    static func shouldRender(
        hasNewPixelBuffer: Bool,
        needsRedraw: Bool,
        hasLastPixelBuffer: Bool,
        simulatesCRT: Bool = false
    ) -> Bool {
        hasLastPixelBuffer && (simulatesCRT || hasNewPixelBuffer || needsRedraw)
    }

    static func shouldAdvanceHistory(
        hasNewPixelBuffer: Bool,
        historyIsValid: Bool
    ) -> Bool {
        hasNewPixelBuffer || !historyIsValid
    }

    static func guestRasterSize(
        drawableSize: SIMD2<Float>,
        sourceSize: SIMD2<Float>,
        rasterMode: CRTRasterMode = .automatic
    ) -> SIMD2<Int> {
        guard drawableSize.x > 0,
              drawableSize.y > 0,
              sourceSize.x > 0,
              sourceSize.y > 0 else {
            return SIMD2(1, 1)
        }

        let sourceAspect = sourceSize.x / sourceSize.y
        let fittedHeight = min(drawableSize.y, drawableSize.x / sourceAspect)
        let sourceHeight = Int(sourceSize.y.rounded(.down))
        let beamHeight: Int
        switch rasterMode {
        case .automatic:
            beamHeight = min(
                sourceHeight,
                min(540, max(144, Int((fittedHeight / 2.6).rounded(.down))))
            )
        case .progressive240:
            beamHeight = min(sourceHeight, 240)
        case .interlaced480:
            beamHeight = min(sourceHeight, 480)
        }
        let approximateWidth = max(1, Int((Float(beamHeight) * sourceAspect).rounded()))
        let evenWidth = approximateWidth > 1
            ? approximateWidth - approximateWidth % 2
            : approximateWidth
        return SIMD2(max(evenWidth, 1), max(beamHeight, 1))
    }

    /// Resolves whether the virtual tube should alternate fields for this asset.
    static func isInterlaced(
        rasterMode: CRTRasterMode,
        scanMetadata: VideoScanMetadata
    ) -> Bool {
        switch rasterMode {
        case .automatic:
            scanMetadata.fieldOrder.isInterlaced
        case .progressive240:
            false
        case .interlaced480:
            true
        }
    }

    /// Returns the vertical scan frequency for the selected analog system.
    static func rasterRefreshRate(
        signalType: CRTSignalType,
        isInterlaced: Bool,
        nominalFrameRate: Float
    ) -> Float {
        if signalType == .compositePAL {
            return 50
        }
        if isInterlaced,
           nominalFrameRate.isFinite,
           nominalFrameRate >= 24,
           nominalFrameRate <= 30.5 {
            return nominalFrameRate * 2
        }
        return 60
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

    /// Encodes one display presentation, refreshing expensive source passes only when needed.
    private func render(_ update: CAMetalDisplayLink.Update) {
        applyAdaptiveFrameRate()
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
            hasLastPixelBuffer: true,
            simulatesCRT: !settings.isBypassed
        ) else {
            updateDisplayLinkState()
            return
        }

        guard let frame = preparedFrame(for: frameUpdate) else {
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
            sourceSize: frame.sourceSize,
            rasterMode: settings.rasterMode
        )
        let rasterSize = SIMD2(Float(raster.x), Float(raster.y))
        let timestamp = update.targetPresentationTimestamp
        let fallbackDelta = 1 / max(maximumDisplayFrameRate, 60)
        let presentationDelta = lastPresentationTimestamp.map {
            Float(max(timestamp - $0, 1 / 1_000))
        } ?? fallbackDelta
        let interlaced = Self.isInterlaced(
            rasterMode: settings.rasterMode,
            scanMetadata: scanMetadata
        )
        let rasterRefreshRate = Self.rasterRefreshRate(
            signalType: settings.signalType,
            isInterlaced: interlaced,
            nominalFrameRate: nominalFrameRate
        )
        let scanPhase = Float(
            (timestamp * Double(rasterRefreshRate))
                .truncatingRemainder(dividingBy: 1)
        )
        let scanSpan = min(
            max(
                presentationDelta * rasterRefreshRate,
                1 / max(currentDrawableSize.y, 1)
            ),
            1
        )
        var fieldParity = Float(
            Int(floor(timestamp * Double(rasterRefreshRate))) & 1
        )
        if scanMetadata.fieldOrder == .bottomFirst {
            fieldParity = 1 - fieldParity
        }

        var measuresPresentationOnly = false
        if settings.isBypassed {
            var uniforms = ShaderUniforms(
                drawableSize: currentDrawableSize,
                sourceSize: frame.sourceSize,
                rasterSize: rasterSize,
                settings: settings,
                yuvConversion: frame.yuvConversion,
                frameCount: frameCount,
                edrHeadroom: edrHeadroom,
                presentationTimestamp: timestamp,
                presentationDelta: presentationDelta,
                scanPhase: scanPhase,
                scanSpan: scanSpan,
                isInterlaced: interlaced,
                fieldParity: fieldParity
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
            let physicalDrawableSize = SIMD2(
                drawable.texture.width,
                drawable.texture.height
            )
            guard let targets = targets(
                rasterSize: raster,
                drawableSize: physicalDrawableSize
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
                historyIsValid: targets.historyIsValid,
                edrHeadroom: edrHeadroom,
                presentationTimestamp: timestamp,
                presentationDelta: presentationDelta,
                scanPhase: scanPhase,
                scanSpan: scanSpan,
                presentationHistoryIsValid: targets.presentationIsValid,
                isInterlaced: interlaced,
                fieldParity: fieldParity
            )
            let historyRead = targets.history[targets.historyReadIndex]
            let historyWriteIndex = 1 - targets.historyReadIndex
            let historyWrite = targets.history[historyWriteIndex]
            let reconstructsSource = frameUpdate.isNew
                || needsSourceReconstruction
                || !targets.sourceIsValid
            measuresPresentationOnly = !reconstructsSource
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

            if reconstructsSource, preparesFreshFrame {
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
            } else if reconstructsSource {
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

            if reconstructsSource {
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
                ) else {
                    return
                }

                let emissionPipeline = settings.maskPattern == .slotMask
                    ? slotEmissionPipeline
                    : apertureEmissionPipeline
                var evenUniforms = uniforms
                evenUniforms.videoData.y = 0
                guard encodePass(
                    commandBuffer: commandBuffer,
                    pipeline: emissionPipeline,
                    target: targets.tubeEmission[0],
                    textures: [
                        targets.sharpened,
                        targets.bloom,
                        targets.prepassLinearized,
                        targets.glow,
                        currentRaw
                    ],
                    uniforms: &evenUniforms,
                    label: "7 Cache Native Tube Emission"
                ) else {
                    return
                }
                if interlaced {
                    var oddUniforms = uniforms
                    oddUniforms.videoData.y = 1
                    guard encodePass(
                        commandBuffer: commandBuffer,
                        pipeline: emissionPipeline,
                        target: targets.tubeEmission[1],
                        textures: [
                            targets.sharpened,
                            targets.bloom,
                            targets.prepassLinearized,
                            targets.glow,
                            currentRaw
                        ],
                        uniforms: &oddUniforms,
                        label: "7b Cache Odd-field Tube Emission"
                    ) else {
                        return
                    }
                }
                targets.sourceIsValid = true
            }

            let presentationWriteIndex = 1 - targets.presentationReadIndex
            let emissionIndex = interlaced && fieldParity >= 0.5 ? 1 : 0
            guard encodePass(
                commandBuffer: commandBuffer,
                pipeline: cachedTemporalPipeline,
                targets: [
                    targets.presentation[presentationWriteIndex],
                    drawable.texture
                ],
                textures: [
                    targets.tubeEmission[emissionIndex],
                    targets.presentation[targets.presentationReadIndex]
                ],
                uniforms: &uniforms,
                label: "8 Display-rate Beam Sweep and Phosphor State"
            ) else {
                return
            }
            targets.presentationReadIndex = presentationWriteIndex
            targets.presentationIsValid = true

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
        let frameBudgetController = frameBudgetController
        let measuredDisplayMaximum = maximumDisplayFrameRate
        let shouldMeasurePresentation = measuresPresentationOnly
        commandBuffer.addCompletedHandler { completedBuffer in
            _ = resources
            diagnostics?.completeFrame(commandBuffer: completedBuffer)
            if shouldMeasurePresentation,
               completedBuffer.gpuEndTime > completedBuffer.gpuStartTime {
                frameBudgetController.recordPresentation(
                    gpuDuration: completedBuffer.gpuEndTime - completedBuffer.gpuStartTime,
                    displayMaximum: measuredDisplayMaximum
                )
            }
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        needsRedraw = false
        needsSourceReconstruction = false
        lastPresentationTimestamp = timestamp
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

    /// Reuses source- and presentation-sized private render targets until geometry changes.
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
            drawableSize: drawableSize,
            statePixelFormat: statePixelFormat,
            usesSeparateFields: Self.isInterlaced(
                rasterMode: settings.rasterMode,
                scanMetadata: scanMetadata
            )
        )
        return renderTargets
    }

    private func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> VideoFrameUpdate? {
        guard let videoSource else {
            guard let lastPixelBuffer else { return nil }
            return VideoFrameUpdate(pixelBuffer: lastPixelBuffer, isNew: false)
        }

        let usesRequestedTime = !isPlaybackActive && requestedPresentationTime != nil
        if let update = videoSource.frame(
            forHostTime: hostTime,
            requestedTime: usesRequestedTime ? requestedPresentationTime : nil,
            isPlaying: isPlaybackActive
        ) {
            lastPixelBuffer = update.pixelBuffer
            awaitingRequestedFrame = false
            return update
        }
        if usesRequestedTime, awaitingRequestedFrame {
            return nil
        }
        guard let lastPixelBuffer else { return nil }
        return VideoFrameUpdate(pixelBuffer: lastPixelBuffer, isNew: false)
    }

    /// Pauses duplicate presentations only when no virtual CRT is visible.
    private func updateDisplayLinkState() {
        let needsContinuousCRT = !settings.isBypassed
            && isPresentationVisible
            && videoSource != nil
        displayLink.isPaused = !(needsContinuousCRT || isPlaybackActive || needsRedraw)
    }

    private func applyAdaptiveFrameRate(force: Bool = false) {
        let adaptiveMaximum = frameBudgetController.maximumFrameRate(
            displayMaximum: maximumDisplayFrameRate
        )
        guard force || adaptiveMaximum != appliedMaximumFrameRate else { return }
        appliedMaximumFrameRate = adaptiveMaximum
        displayLink.preferredFrameRateRange = Self.preferredFrameRateRange(
            nominalFrameRate: nominalFrameRate,
            maximumDisplayFrameRate: adaptiveMaximum,
            simulatesCRT: !settings.isBypassed
        )
    }

    /// Keeps the Core Video-to-Metal wrappers for the current decoded frame alive.
    private func preparedFrame(for update: VideoFrameUpdate) -> PreparedFrame? {
        if update.isNew || cachedFrame == nil {
            cachedFrame = makeFrame(from: update.pixelBuffer)
        }
        return cachedFrame
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
    let drawableSize: SIMD2<Int>
    let raw: [any MTLTexture]
    let history: [any MTLTexture]
    let presentation: [any MTLTexture]
    let prepassLinearized: any MTLTexture
    let sharpened: any MTLTexture
    let lightHorizontal: any MTLTexture
    let glow: any MTLTexture
    let bloom: any MTLTexture
    let tubeEmission: [any MTLTexture]

    var rawReadIndex = 0
    var rawIsValid = false
    var historyReadIndex = 0
    var historyIsValid = false
    var sourceIsValid = false
    var presentationReadIndex = 0
    var presentationIsValid = false

    init?(
        device: any MTLDevice,
        rasterSize: SIMD2<Int>,
        drawableSize: SIMD2<Int>,
        statePixelFormat: MTLPixelFormat,
        usesSeparateFields: Bool
    ) {
        func texture(
            width: Int,
            height: Int,
            label: String,
            pixelFormat: MTLPixelFormat = .rgba16Float
        ) -> (any MTLTexture)? {
            guard width > 0, height > 0 else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
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
        ), let tubeEmission0 = texture(
            width: drawableSize.x,
            height: drawableSize.y,
            label: "Cached Tube Emission Even"
        ), let presentation0 = texture(
            width: drawableSize.x,
            height: drawableSize.y,
            label: "Phosphor Excitation A",
            pixelFormat: statePixelFormat
        ), let presentation1 = texture(
            width: drawableSize.x,
            height: drawableSize.y,
            label: "Phosphor Excitation B",
            pixelFormat: statePixelFormat
        ) else {
            return nil
        }

        let tubeEmission1: any MTLTexture
        if usesSeparateFields {
            guard let separateOddEmission = texture(
                width: drawableSize.x,
                height: drawableSize.y,
                label: "Cached Tube Emission Odd"
            ) else {
                return nil
            }
            tubeEmission1 = separateOddEmission
        } else {
            // Progressive sources share one immutable emission solution. At 4K
            // this avoids a redundant 64 MiB RGBA16Float texture.
            tubeEmission1 = tubeEmission0
        }

        self.rasterSize = rasterSize
        self.drawableSize = drawableSize
        raw = [raw0, raw1]
        history = [history0, history1]
        presentation = [presentation0, presentation1]
        self.prepassLinearized = prepassLinearized
        self.sharpened = sharpened
        self.lightHorizontal = lightHorizontal
        self.glow = glow
        self.bloom = bloom
        tubeEmission = [tubeEmission0, tubeEmission1]
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
