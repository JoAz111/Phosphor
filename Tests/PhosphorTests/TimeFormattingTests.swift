import XCTest
@testable import Phosphor

final class TimeFormattingTests: XCTestCase {
    func testMinutesAndSeconds() {
        XCTAssertEqual(TimeFormatting.playerTime(0), "0:00")
        XCTAssertEqual(TimeFormatting.playerTime(65), "1:05")
    }

    func testHoursAreIncludedWhenNeeded() {
        XCTAssertEqual(TimeFormatting.playerTime(3661), "1:01:01")
    }

    func testNegativeAndNonfiniteValuesUseZero() {
        XCTAssertEqual(TimeFormatting.playerTime(-1), "0:00")
        XCTAssertEqual(TimeFormatting.playerTime(.infinity), "0:00")
        XCTAssertEqual(TimeFormatting.playerTime(.nan), "0:00")
    }

    func testIntegerBoundaryUsesZero() {
        let boundary = TimeInterval(Int.max)

        XCTAssertEqual(TimeFormatting.playerTime(boundary), "0:00")
        XCTAssertEqual(TimeFormatting.playerTime(boundary.nextUp), "0:00")
    }
}
