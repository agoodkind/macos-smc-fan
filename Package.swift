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
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "smcfan", targets: ["smcfan"]),
        .executable(name: "smcfanhelper", targets: ["smcfanhelper"]),
        .executable(name: "installer", targets: ["installer"])
    ],
    dependencies: [
        .package(url: "https://github.com/cpisciotta/xcbeautify", from: "3.0.0")
    ],
    targets: [
        // Common Swift protocol and types
        .target(
            name: "SMCCommon",
            dependencies: [],
            path: "Sources/common",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // CLI tool (XPC client)
        .executableTarget(
            name: "smcfan",
            dependencies: ["SMCCommon"],
            path: "Sources/smcfan",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // XPC helper daemon (privileged service)
        // Note: Pure Swift SMC implementation - no C dependency required
        .executableTarget(
            name: "smcfanhelper",
            dependencies: ["SMCCommon"],
            path: "Sources/smcfanhelper",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // SMJobBless installer
        .executableTarget(
            name: "installer",
            dependencies: ["SMCCommon"],
            path: "Sources/installer",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),

        // Tests
        .testTarget(
            name: "SMCFanTests",
            dependencies: [],
            path: "Tests/SMCFanTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
