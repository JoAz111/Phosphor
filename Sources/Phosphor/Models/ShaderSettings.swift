struct ShaderSettings: Sendable, Equatable {
    var intensity: Float
    var curvature: Float
    var scanlines: Float
    var mask: Float
    var glow: Float
    var vignette: Float

    static let `default` = ShaderSettings()

    var isBypassed: Bool {
        intensity == 0
    }

    init(
        intensity: Float = 0.88,
        curvature: Float = 0.08,
        scanlines: Float = 0.72,
        mask: Float = 0.42,
        glow: Float = 0.18,
        vignette: Float = 0.28
    ) {
        self.intensity = intensity.clamped(to: 0 ... 1)
        self.curvature = curvature.clamped(to: 0 ... 0.25)
        self.scanlines = scanlines.clamped(to: 0 ... 1)
        self.mask = mask.clamped(to: 0 ... 1)
        self.glow = glow.clamped(to: 0 ... 1)
        self.vignette = vignette.clamped(to: 0 ... 1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
