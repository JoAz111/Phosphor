import XCTest
@testable import Phosphor

final class PackageSmokeTests: XCTestCase {
    func testProductIdentity() {
        XCTAssertEqual(ProductIdentity.name, "Phosphor")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "com.joeyazizoff.Phosphor")
    }
}
