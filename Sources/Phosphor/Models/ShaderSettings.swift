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
        self.intensity = intensity.sanitized(defaultValue: 0.88, to: 0 ... 1)
        self.curvature = curvature.sanitized(defaultValue: 0.08, to: 0 ... 0.25)
        self.scanlines = scanlines.sanitized(defaultValue: 0.72, to: 0 ... 1)
        self.mask = mask.sanitized(defaultValue: 0.42, to: 0 ... 1)
        self.glow = glow.sanitized(defaultValue: 0.18, to: 0 ... 1)
        self.vignette = vignette.sanitized(defaultValue: 0.28, to: 0 ... 1)
    }
}

private extension Float {
    func sanitized(defaultValue: Float, to range: ClosedRange<Float>) -> Float {
        guard !isNaN else { return defaultValue }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
