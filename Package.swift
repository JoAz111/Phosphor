// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Phosphor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Phosphor", targets: ["Phosphor"])
    ],
    targets: [
        .executableTarget(
            name: "Phosphor",
            resources: [
                .copy("Resources/PhosphorShaders.metal")
            ]
        ),
        .testTarget(
            name: "PhosphorTests",
            dependencies: ["Phosphor"]
        )
    ]
)
