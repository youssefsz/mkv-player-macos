// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PlayerCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PlayerCore", targets: ["PlayerCore"])
    ],
    targets: [
        .target(name: "PlayerCore"),
        .testTarget(
            name: "PlayerCoreTests",
            dependencies: ["PlayerCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
