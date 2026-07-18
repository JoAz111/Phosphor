import XCTest
@testable import Phosphor

final class PlayerTransportTests: XCTestCase {
    func testEmptyDoesNotToggleWithoutMedia() {
        XCTAssertEqual(PlayerTransport.empty.toggled(hasMedia: false), .empty)
    }

    func testPausedTogglesToPlayingWithMedia() {
        XCTAssertEqual(PlayerTransport.paused.toggled(hasMedia: true), .playing)
    }

    func testPlayingTogglesToPausedWithMedia() {
        XCTAssertEqual(PlayerTransport.playing.toggled(hasMedia: true), .paused)
    }
}
