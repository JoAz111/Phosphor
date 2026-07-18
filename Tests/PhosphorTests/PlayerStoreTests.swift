import XCTest
@testable import Phosphor

@MainActor
final class PlayerStoreTests: XCTestCase {
    func testEmptyStoreHasDeterministicDefaults() {
        let store = PlayerStore()

        XCTAssertFalse(store.hasMedia)
        XCTAssertEqual(store.transport, .empty)
        XCTAssertEqual(store.currentTime, 0)
        XCTAssertEqual(store.duration, 0)
        XCTAssertEqual(store.volume, 1)
        XCTAssertNil(store.videoOutput)
        XCTAssertNil(store.currentURL)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.noticeMessage)
        XCTAssertNil(store.player.currentItem)
    }

    func testVolumeIsClampedAtBothBounds() {
        let store = PlayerStore()

        store.setVolume(-1)
        XCTAssertEqual(store.volume, 0)
        XCTAssertEqual(store.player.volume, 0)

        store.setVolume(2)
        XCTAssertEqual(store.volume, 1)
        XCTAssertEqual(store.player.volume, 1)
    }

    func testTogglingWithoutMediaRemainsEmpty() {
        let store = PlayerStore()

        store.togglePlayback()

        XCTAssertEqual(store.transport, .empty)
        XCTAssertFalse(store.hasMedia)
        XCTAssertEqual(store.player.rate, 0)
    }
}
