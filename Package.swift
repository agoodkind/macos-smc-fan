// swift-tools-version: 6.0
//
//  Package.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import PackageDescription

let package = Package(
    name: "SMCFan",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "SMCFanKit", targets: ["SMCFanKit"]),
        .library(name: "SMCFanLogging", targets: ["SMCFanLogging"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/xcode-actions/json-logger.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SMCKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SMCKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SMCFanKit",
            dependencies: [
                "SMCKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SMCFanKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SMCFanLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "JSONLogger", package: "json-logger"),
            ],
            path: "Sources/SMCFanLogging",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SMCKitTests",
            dependencies: ["SMCKit"],
            path: "Tests/SMCKitTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SMCFanKitTests",
            dependencies: ["SMCFanKit"],
            path: "Tests/SMCFanKitTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "IntegrationTests",
            path: "Tests/IntegrationTests",
            exclude: ["Fixtures"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
    ]
)
