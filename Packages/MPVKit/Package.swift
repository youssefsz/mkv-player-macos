// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MPVKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MPVKit", targets: ["MPVKit"]),
    ],
    dependencies: [
        .package(path: "../PlayerCore"),
    ],
    targets: [
        .target(
            name: "CMPVShim",
            path: "Sources/CMPVShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MPVKit",
            dependencies: [
                "CMPVShim",
                .product(name: "PlayerCore", package: "PlayerCore"),
            ],
            swiftSettings: [
                // OpenGL is deliberately isolated in MPVVideoSurface until
                // libmpv exposes a supported Metal render API.
                .unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("OpenGL"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "MPVKitTests",
            dependencies: ["MPVKit"]
        ),
    ]
)
