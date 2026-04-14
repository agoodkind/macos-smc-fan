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
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "SMCFanKit", targets: ["SMCFanKit"]),
    ],
    targets: [
        .target(
            name: "SMCKit",
            path: "Sources/SMCKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "SMCFanKit",
            dependencies: ["SMCKit"],
            path: "Sources/SMCFanKit",
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
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
    ]
)
