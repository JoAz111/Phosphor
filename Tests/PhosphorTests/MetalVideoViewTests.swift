import AppKit
import XCTest
@testable import Phosphor

@MainActor
final class MetalVideoViewTests: XCTestCase {
    func testMouseActivityUsesNativeAppKitTracking() throws {
        let view = MetalVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        var receivedActivity = false
        view.setMouseActivityHandler {
            receivedActivity = true
        }
        view.updateTrackingAreas()

        let area = try XCTUnwrap(view.trackingAreas.first { area in
            area.options.contains(.mouseMoved)
                && area.options.contains(.activeInKeyWindow)
                && area.options.contains(.inVisibleRect)
        })
        XCTAssertTrue(area.owner === view)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: event)
        XCTAssertTrue(receivedActivity)
    }

    func testContentViewDoesNotInstallSwiftUIContinuousHoverResponder() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appending(path: "Sources/Phosphor/Views/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".onContinuousHover"))
    }

    func testWindowNotificationsUseNonisolatedMainActorTrampolines() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appending(path: "Sources/Phosphor/Rendering/MetalVideoView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "nonisolated private func windowScreenDidChange"
        ))
        XCTAssertTrue(source.contains(
            "nonisolated private func windowOcclusionDidChange"
        ))
    }
}
