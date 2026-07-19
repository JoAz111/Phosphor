import AppKit
import AVFoundation
import CoreGraphics
import Metal
import QuartzCore

@MainActor
final class MetalVideoView: NSView {
    private var renderer: MetalRenderer?
    private var requestedActive = false
    private var configuredSource: (any VideoFrameSource)?
    private var configuredSettings = ShaderSettings.default
    private var configuredPresentationTime: TimeInterval = 0
    private var configuredNominalFrameRate: Float = 0
    private var configuredScanMetadata = VideoScanMetadata.progressive
    private var requestsEDRPhosphors = true
    private var displayConfiguration: DisplayConfiguration?
    private var mouseActivityHandler: (() -> Void)?
    private var mouseTrackingArea: NSTrackingArea?

    private struct DisplayConfiguration: Equatable {
        let usesEDR: Bool
        let headroom: Float
        let maximumFrameRate: Float

        var pixelFormat: MTLPixelFormat {
            usesEDR ? .rgba16Float : .bgra8Unorm_srgb
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpMetalLayer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayConfigurationIfNeeded()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateDisplayConfigurationIfNeeded()
        updateDisplayLinkState()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let updatedTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(updatedTrackingArea)
        mouseTrackingArea = updatedTrackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        mouseActivityHandler?()
    }

    func configure(
        source: (any VideoFrameSource)?,
        settings: ShaderSettings,
        presentationTime: TimeInterval,
        nominalFrameRate: Float,
        scanMetadata: VideoScanMetadata,
        edrPhosphors: Bool
    ) {
        configuredSource = source
        configuredSettings = settings
        configuredPresentationTime = presentationTime
        configuredNominalFrameRate = nominalFrameRate
        configuredScanMetadata = scanMetadata
        requestsEDRPhosphors = edrPhosphors
        updateDisplayConfigurationIfNeeded()
        renderer?.configure(
            source: source,
            settings: settings,
            edrHeadroom: displayConfiguration?.headroom ?? 1,
            nominalFrameRate: nominalFrameRate,
            scanMetadata: scanMetadata,
            maximumDisplayFrameRate: displayConfiguration?.maximumFrameRate ?? 60
        )
        renderer?.requestPresentation(at: presentationTime)
    }

    func setActive(_ isActive: Bool) {
        requestedActive = isActive
        updateDisplayLinkState()
    }

    func setMouseActivityHandler(_ handler: (() -> Void)?) {
        mouseActivityHandler = handler
    }

    private func setUpMetalLayer() {
        wantsLayer = true
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }

        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowScreenDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        updateDisplayConfigurationIfNeeded()
        updateDrawableSize()
    }

    @objc
    nonisolated private func windowScreenDidChange(_ notification: Notification) {
        guard let source = notification.object as AnyObject? else { return }
        let sourceID = ObjectIdentifier(source)
        Task { @MainActor [weak self] in
            guard let self,
                  let window = self.window,
                  ObjectIdentifier(window) == sourceID else { return }
            self.updateDisplayConfigurationIfNeeded()
        }
    }

    @objc
    nonisolated private func windowOcclusionDidChange(_ notification: Notification) {
        guard let source = notification.object as AnyObject? else { return }
        let sourceID = ObjectIdentifier(source)
        Task { @MainActor [weak self] in
            guard let self,
                  let window = self.window,
                  ObjectIdentifier(window) == sourceID else { return }
            self.updateDisplayLinkState()
        }
    }

    /// Stops display-rate CRT work when SwiftUI dismantles this presentation.
    func stopPresentation() {
        requestedActive = false
        renderer?.setActive(false, isVisible: false)
    }

    private func updateDisplayConfigurationIfNeeded() {
        guard let metalLayer = layer as? CAMetalLayer else { return }

        let potentialHeadroom = Float(
            window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue
                ?? 1
        )
        let usesEDR = requestsEDRPhosphors && potentialHeadroom > 1
        let updatedConfiguration = DisplayConfiguration(
            usesEDR: usesEDR,
            headroom: usesEDR ? min(max(potentialHeadroom, 1), 16) : 1,
            maximumFrameRate: Float(window?.screen?.maximumFramesPerSecond ?? 60)
        )
        guard displayConfiguration != updatedConfiguration else { return }

        renderer?.setActive(false)
        renderer = nil
        displayConfiguration = updatedConfiguration

        metalLayer.pixelFormat = updatedConfiguration.pixelFormat
        metalLayer.colorspace = CGColorSpace(
            name: usesEDR
                ? CGColorSpace.extendedLinearSRGB
                : CGColorSpace.sRGB
        )
        metalLayer.wantsExtendedDynamicRangeContent = usesEDR
        metalLayer.edrMetadata = nil

        renderer = try? MetalRenderer(layer: metalLayer)
        renderer?.configure(
            source: configuredSource,
            settings: configuredSettings,
            edrHeadroom: updatedConfiguration.headroom,
            nominalFrameRate: configuredNominalFrameRate,
            scanMetadata: configuredScanMetadata,
            maximumDisplayFrameRate: updatedConfiguration.maximumFrameRate
        )
        renderer?.requestPresentation(at: configuredPresentationTime)
        updateDrawableSize()
        updateDisplayLinkState()
    }

    private func updateDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }

        let backingBounds = convertToBacking(bounds)
        let size = CGSize(
            width: max(backingBounds.width.rounded(.up), 0),
            height: max(backingBounds.height.rounded(.up), 0)
        )
        metalLayer.contentsScale = window?.backingScaleFactor ?? 1

        if metalLayer.drawableSize != size {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.drawableSize = size
            CATransaction.commit()
        }
        renderer?.drawableSizeDidChange(size)
    }

    private func updateDisplayLinkState() {
        let isVisible = window?.occlusionState.contains(.visible) == true
        renderer?.setActive(requestedActive, isVisible: isVisible)
    }
}
