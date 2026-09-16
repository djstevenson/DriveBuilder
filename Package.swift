// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DriveBuilder",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        // Keeps the CLI binary named DriveBuilder (`swift run DriveBuilder ...`)
        // even though the command definitions now live in the library target.
        .executable(name: "DriveBuilder", targets: ["DriveBuilderCLI"]),
        .executable(name: "DriveBuilderStudio", targets: ["DriveBuilderStudio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // The models, renderers, resources, and CLI command definitions,
        // shared by the two front ends: the CLI executable and the Studio
        // GUI. Cross-target API is marked `package`.
        .target(
            name: "DriveBuilder",
            dependencies:  [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                // .copy preserves the per-dial folder structure; .process would flatten it.
                .copy("Resources/SVG"),
                // Bitmap artwork, e.g. the intro/outro background image.
                .copy("Resources/Images"),
                // The one telemetry database for every journey, checked into the
                // repo rather than passed in on the command line.
                .copy("Resources/telemetry.sqlite3"),

                // OS Resources
                .copy("Resources/oproad_gb.gpkg"),
                .copy("Resources/opname_gb.gpkg"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        // Thin entry point so the package can also vend the library above.
        .executableTarget(
            name: "DriveBuilderCLI",
            dependencies: ["DriveBuilder"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        // The SwiftUI GUI: browse journeys and render their video components.
        .executableTarget(
            name: "DriveBuilderStudio",
            dependencies: ["DriveBuilder"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "DriveBuilderTests",
            dependencies: ["DriveBuilder"],
            resources: [
                .copy("Fixtures/A338 Northbound"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
