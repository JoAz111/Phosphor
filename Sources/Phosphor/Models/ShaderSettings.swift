enum PhosphorMaskPattern: Int, CaseIterable, Identifiable, Sendable {
    case apertureGrille
    case slotMask

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .apertureGrille:
            "Grille"
        case .slotMask:
            "Slot"
        }
    }
}

/// Selects the raster structure that Phosphor presents to the virtual tube.
///
/// Automatic mode preserves progressive sources and honors interlacing metadata.
/// The explicit modes let modern masters be displayed with period-correct 240p or
/// 480i timing when the file no longer contains the original field structure.
enum CRTRasterMode: Int, CaseIterable, Identifiable, Sendable {
    case automatic
    case progressive240
    case interlaced480

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            "Auto"
        case .progressive240:
            "240p"
        case .interlaced480:
            "480i"
        }
    }
}

/// Describes the analog connection feeding the simulated CRT.
///
/// RGB remains lossless. The other modes reproduce progressively stronger
/// luminance/chrominance bandwidth limits and composite encoding artifacts.
enum CRTSignalType: Int, CaseIterable, Identifiable, Sendable {
    case rgb
    case sVideo
    case compositeNTSC
    case compositePAL

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .rgb:
            "RGB"
        case .sVideo:
            "S-Video"
        case .compositeNTSC:
            "NTSC"
        case .compositePAL:
            "PAL"
        }
    }
}

/// Chooses a calibrated family of beam, mask, and faceplate characteristics.
///
/// Profiles establish physically coherent defaults while the individual controls
/// continue to scale their most visible traits.
enum CRTTubeProfile: Int, CaseIterable, Identifiable, Sendable {
    case consumerTV
    case trinitron
    case professionalMonitor

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .consumerTV:
            "Consumer TV"
        case .trinitron:
            "Trinitron"
        case .professionalMonitor:
            "PVM"
        }
    }
}

/// User-adjustable controls for the physical CRT renderer.
///
/// Values are sanitized at construction so the Metal uniform block never receives
/// nonfinite numbers or parameters outside the shader's calibrated range.
struct ShaderSettings: Sendable, Equatable {
    var intensity: Float
    var curvature: Float
    var scanlines: Float
    var mask: Float
    var maskPattern: PhosphorMaskPattern
    var glow: Float
    var vignette: Float
    var persistence: Float
    var convergence: Float
    var focus: Float
    var rasterMode: CRTRasterMode
    var signalType: CRTSignalType
    var tubeProfile: CRTTubeProfile

    static let `default` = ShaderSettings()

    var isBypassed: Bool {
        intensity == 0
    }

    init(
        intensity: Float = 0.88,
        curvature: Float = 0.08,
        scanlines: Float = 0.72,
        mask: Float = 0.42,
        maskPattern: PhosphorMaskPattern = .apertureGrille,
        glow: Float = 0.18,
        vignette: Float = 0.28,
        persistence: Float = 0.34,
        convergence: Float = 0.10,
        focus: Float = 0.12,
        rasterMode: CRTRasterMode = .automatic,
        signalType: CRTSignalType = .rgb,
        tubeProfile: CRTTubeProfile = .consumerTV
    ) {
        self.intensity = intensity.sanitized(defaultValue: 0.88, to: 0 ... 1)
        self.curvature = curvature.sanitized(defaultValue: 0.08, to: 0 ... 0.25)
        self.scanlines = scanlines.sanitized(defaultValue: 0.72, to: 0 ... 1)
        self.mask = mask.sanitized(defaultValue: 0.42, to: 0 ... 1)
        self.maskPattern = maskPattern
        self.glow = glow.sanitized(defaultValue: 0.18, to: 0 ... 1)
        self.vignette = vignette.sanitized(defaultValue: 0.28, to: 0 ... 1)
        self.persistence = persistence.sanitized(defaultValue: 0.34, to: 0 ... 1)
        self.convergence = convergence.sanitized(defaultValue: 0.10, to: 0 ... 1)
        self.focus = focus.sanitized(defaultValue: 0.12, to: 0 ... 1)
        self.rasterMode = rasterMode
        self.signalType = signalType
        self.tubeProfile = tubeProfile
    }
}

private extension Float {
    /// Replaces NaN and clamps finite or infinite values into a shader-safe range.
    ///
    /// - Parameters:
    ///   - defaultValue: Value to use when the receiver is NaN.
    ///   - range: Inclusive range accepted by the shader.
    /// - Returns: A finite-or-bounded value suitable for a Metal uniform.
    func sanitized(defaultValue: Float, to range: ClosedRange<Float>) -> Float {
        guard !isNaN else { return defaultValue }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
