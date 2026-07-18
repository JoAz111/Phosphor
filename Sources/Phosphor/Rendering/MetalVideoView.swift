import AppKit
import AVFoundation
import CoreGraphics
import Metal
import QuartzCore

@MainActor
final class MetalVideoView: NSView {
    private var renderer: MetalRenderer?
    private var requestedActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpMetalLayer()
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
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLinkState()
        needsLayout = true
    }

    func configure(
        output: AVPlayerItemVideoOutput?,
        settings: ShaderSettings,
        presentationTime: TimeInterval
    ) {
        renderer?.configure(output: output, settings: settings)
        renderer?.requestPresentation(at: presentationTime)
    }

    func setActive(_ isActive: Bool) {
        requestedActive = isActive
        updateDisplayLinkState()
    }

    private func setUpMetalLayer() {
        wantsLayer = true
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }

        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        renderer = try? MetalRenderer(layer: metalLayer)
        updateDrawableSize()
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
        renderer?.setActive(requestedActive && window != nil)
    }
}
