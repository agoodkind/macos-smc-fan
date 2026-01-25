// swift-tools-version: 5.9
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
        .executable(name: "installer", targets: ["installer"]),
    ],
    targets: [
        // Common Swift protocol and types
        .target(
            name: "SMCCommon",
            dependencies: [],
            path: "Sources/common"
        ),

        // CLI tool (XPC client)
        .executableTarget(
            name: "smcfan",
            dependencies: ["SMCCommon"],
            path: "Sources/smcfan"
        ),

        // XPC helper daemon (privileged service)
        // Note: Pure Swift SMC implementation - no C dependency required
        .executableTarget(
            name: "smcfanhelper",
            dependencies: ["SMCCommon"],
            path: "Sources/smcfanhelper"
        ),

        // SMJobBless installer
        .executableTarget(
            name: "installer",
            dependencies: ["SMCCommon"],
            path: "Sources/installer"
        ),

        // Tests
        .testTarget(
            name: "SMCFanTests",
            dependencies: [],
            path: "Tests/SMCFanTests"
        ),
    ]
)
