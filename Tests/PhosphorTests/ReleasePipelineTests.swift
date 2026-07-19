import Foundation
import XCTest

final class ReleasePipelineTests: XCTestCase {
    func testSparkleIsPinnedAndConfiguredForGitHubReleases() throws {
        let package = try source("Package.swift")
        let app = try source("Sources/Phosphor/App/PhosphorApp.swift")
        let builder = try source("script/build_and_run.sh")

        XCTAssertTrue(package.contains("exact: \"2.9.4\""))
        XCTAssertTrue(package.contains(".product(name: \"Sparkle\""))
        XCTAssertTrue(app.contains("SPUStandardUpdaterController"))
        XCTAssertTrue(app.contains("Check for Updates…"))
        XCTAssertTrue(builder.contains("SUFeedURL"))
        XCTAssertTrue(builder.contains("SUPublicEDKey"))
        XCTAssertTrue(
            builder.contains(
                "releases/latest/download/appcast.xml"
            )
        )
    }

    func testReleasePipelineSignsInsideOutAndPublishesDMGWithAppcast() throws {
        let builder = try source("script/build_and_run.sh")
        let release = try source("script/build_release.sh")
        let publisher = try source("script/publish_release.sh")

        XCTAssertTrue(builder.contains("XPCServices/Installer.xpc"))
        XCTAssertTrue(builder.contains("XPCServices/Downloader.xpc"))
        XCTAssertTrue(builder.contains("SPARKLE_VERSION_DIR/Autoupdate"))
        XCTAssertFalse(builder.contains("codesign --deep"))
        XCTAssertTrue(release.contains("-format ULFO"))
        XCTAssertTrue(release.contains("notarytool submit"))
        XCTAssertTrue(release.contains("stapler staple"))
        XCTAssertTrue(release.contains("generate_appcast"))
        XCTAssertTrue(publisher.contains("release create"))
        XCTAssertTrue(publisher.contains("APPCAST_PATH#Sparkle appcast"))
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repository = testsDirectory.deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
