import XCTest
@testable import Phosphor

final class ControlBindingTests: XCTestCase {
    func testPreferencesConstructClampedShaderSettings() {
        let preferences = ControlPreferences(
            savedIntensity: -1,
            curvature: 1,
            scanlines: -1,
            mask: 2,
            glow: -1,
            vignette: 2
        )

        XCTAssertEqual(
            preferences.shaderSettings,
            ShaderSettings(
                intensity: -1,
                curvature: 1,
                scanlines: -1,
                mask: 2,
                glow: -1,
                vignette: 2
            )
        )
    }

    func testBypassUsesZeroIntensityWithoutErasingSavedIntensity() {
        var preferences = ControlPreferences(savedIntensity: 0.37)

        preferences.isBypassed = true

        XCTAssertEqual(preferences.savedIntensity, 0.37)
        XCTAssertEqual(preferences.shaderSettings.intensity, 0)

        preferences.isBypassed = false

        XCTAssertEqual(preferences.savedIntensity, 0.37)
        XCTAssertEqual(preferences.shaderSettings.intensity, 0.37)
    }

    func testResetRestoresExactDefaults() {
        var preferences = ControlPreferences(
            isBypassed: true,
            savedIntensity: 0.1,
            curvature: 0.2,
            scanlines: 0.3,
            mask: 0.4,
            glow: 0.5,
            vignette: 0.6
        )

        preferences.reset()

        XCTAssertEqual(preferences, .default)
        XCTAssertEqual(preferences.shaderSettings, .default)
    }
}
