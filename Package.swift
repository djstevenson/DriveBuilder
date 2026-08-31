// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DriveBuilder",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "DriveBuilder",
            dependencies:  [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                // .copy preserves the per-dial folder structure; .process would flatten it.
                .copy("Resources/SVG"),
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
