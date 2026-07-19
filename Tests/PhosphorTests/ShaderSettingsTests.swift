import XCTest
@testable import Phosphor

final class ShaderSettingsTests: XCTestCase {
    func testDefaultValues() {
        let settings = ShaderSettings.default

        XCTAssertEqual(settings.intensity, 0.88)
        XCTAssertEqual(settings.curvature, 0.08)
        XCTAssertEqual(settings.scanlines, 0.72)
        XCTAssertEqual(settings.mask, 0.42)
        XCTAssertEqual(settings.maskPattern, .apertureGrille)
        XCTAssertEqual(settings.glow, 0.18)
        XCTAssertEqual(settings.vignette, 0.28)
        XCTAssertEqual(settings.persistence, 0.34)
        XCTAssertEqual(settings.convergence, 0.10)
        XCTAssertEqual(settings.focus, 0.12)
        XCTAssertEqual(settings.rasterMode, .automatic)
        XCTAssertEqual(settings.signalType, .rgb)
        XCTAssertEqual(settings.tubeProfile, .consumerTV)
    }

    func testInitializerClampsAtBothBounds() {
        let settings = ShaderSettings(
            intensity: -1,
            curvature: 1,
            scanlines: -1,
            mask: 2,
            glow: -1,
            vignette: 2,
            persistence: -1,
            convergence: 2,
            focus: -1
        )

        XCTAssertEqual(settings.intensity, 0)
        XCTAssertEqual(settings.curvature, 0.25)
        XCTAssertEqual(settings.scanlines, 0)
        XCTAssertEqual(settings.mask, 1)
        XCTAssertEqual(settings.glow, 0)
        XCTAssertEqual(settings.vignette, 1)
        XCTAssertEqual(settings.persistence, 0)
        XCTAssertEqual(settings.convergence, 1)
        XCTAssertEqual(settings.focus, 0)
    }

    func testInitializerSanitizesNonfiniteValues() {
        let settings = ShaderSettings(
            intensity: .nan,
            curvature: .infinity,
            scanlines: -.infinity,
            mask: .nan,
            glow: .infinity,
            vignette: -.infinity,
            persistence: .nan,
            convergence: .infinity,
            focus: -.infinity
        )

        XCTAssertEqual(settings.intensity, 0.88)
        XCTAssertEqual(settings.curvature, 0.25)
        XCTAssertEqual(settings.scanlines, 0)
        XCTAssertEqual(settings.mask, 0.42)
        XCTAssertEqual(settings.glow, 1)
        XCTAssertEqual(settings.vignette, 0)
        XCTAssertEqual(settings.persistence, 0.34)
        XCTAssertEqual(settings.convergence, 1)
        XCTAssertEqual(settings.focus, 0)
    }

    func testZeroIntensityBypassesShader() {
        let settings = ShaderSettings(intensity: 0)

        XCTAssertTrue(settings.isBypassed)
    }

    func testResetEqualsDefault() {
        XCTAssertEqual(ShaderSettings(), .default)
    }
}
