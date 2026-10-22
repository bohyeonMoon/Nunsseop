// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nunsseop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nunsseop", targets: ["Nunsseop"]),
        .library(name: "NowPlayingHelper", type: .dynamic, targets: ["NowPlayingHelper"]),
    ],
    dependencies: [
        // Updates for copies installed from the DMG (see UpdateMethod.swift). 2.9.6 is the oldest without known advisories.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Nunsseop",
            dependencies: ["NunsseopAtomics", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Nunsseop"
        ),
        // Lock-free values for the per-app volume audio thread.
        .target(name: "NunsseopAtomics", path: "Sources/NunsseopAtomics"),
        // Loaded into /usr/bin/perl at runtime; see Resources/nowplaying.pl.
        .target(
            name: "NowPlayingHelper",
            path: "Sources/NowPlayingHelper",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "NunsseopTests",
            dependencies: ["Nunsseop"],
            path: "Tests/NunsseopTests"
        ),
    ]
)
