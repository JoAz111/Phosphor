import XCTest
@testable import Phosphor

final class ControlBindingTests: XCTestCase {
    func testFullScreenPresentationUsesTruthfulToggleLabel() {
        XCTAssertEqual(
            ControlPresentation.fullScreenActionLabel,
            "Toggle Full Screen"
        )
    }

    func testPreferencesConstructClampedShaderSettings() {
        let preferences = ControlPreferences(
            savedIntensity: -1,
            curvature: 1,
            scanlines: -1,
            mask: 2,
            maskPattern: .slotMask,
            glow: -1,
            vignette: 2,
            persistence: -1,
            convergence: 2,
            focus: -1,
            rasterMode: .interlaced480,
            signalType: .compositePAL,
            compositeDecoder: .notch,
            temporalMode: .lowPersistence,
            tubeProfile: .professionalMonitor
        )

        XCTAssertEqual(
            preferences.shaderSettings,
            ShaderSettings(
                intensity: -1,
                curvature: 1,
                scanlines: -1,
                mask: 2,
                maskPattern: .slotMask,
                glow: -1,
                vignette: 2,
                persistence: -1,
                convergence: 2,
                focus: -1,
                rasterMode: .interlaced480,
                signalType: .compositePAL,
                compositeDecoder: .notch,
                temporalMode: .lowPersistence,
                tubeProfile: .professionalMonitor
            )
        )
        XCTAssertTrue(preferences.edrPhosphors)
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
            maskPattern: .slotMask,
            glow: 0.5,
            vignette: 0.6,
            persistence: 0.7,
            convergence: 0.8,
            focus: 0.9,
            rasterMode: .interlaced480,
            signalType: .compositeNTSC,
            compositeDecoder: .notch,
            temporalMode: .lowPersistence,
            tubeProfile: .professionalMonitor,
            edrPhosphors: false
        )

        preferences.reset()

        XCTAssertEqual(preferences, .default)
        XCTAssertEqual(preferences.shaderSettings, .default)
    }
}
