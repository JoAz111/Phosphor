// swift-tools-version: 6.0

import PackageDescription
import Foundation

let ffmpegPrefix = ProcessInfo.processInfo.environment["PHOSPHOR_FFMPEG_PREFIX"]
    ?? "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "Phosphor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Phosphor", targets: ["Phosphor"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .target(
            name: "CPhosphorFFmpeg",
            path: "Sources/CPhosphorFFmpeg",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(ffmpegPrefix)/include"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ffmpegPrefix)/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedLibrary("avformat"),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
                .linkedLibrary("swresample"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .executableTarget(
            name: "Phosphor",
            dependencies: [
                "CPhosphorFFmpeg",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .copy("Resources/Phosphor.icns"),
                .copy("Resources/PhosphorShaders.metal")
            ]
        ),
        .testTarget(
            name: "PhosphorTests",
            dependencies: ["Phosphor", "CPhosphorFFmpeg"],
            linkerSettings: [
                // SwiftPM stages binary frameworks beside the test bundle.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../.."
                ])
            ]
        )
    ]
)
