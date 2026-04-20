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
    .library(name: "AppLog", targets: ["AppLog"]),
    .library(name: "SMCFanProtocol", targets: ["SMCFanProtocol"]),
    .library(name: "SMCFanXPCClient", targets: ["SMCFanXPCClient"]),
    .executable(name: "smcfan", targets: ["smcfan"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
  ],
  targets: [
    .target(
      name: "AppLog",
      dependencies: [
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Sources/AppLog",
      exclude: ["expected-categories.txt"],
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .target(
      name: "SMCKit",
      dependencies: [
        "AppLog",
      ],
      path: "Sources/SMCKit",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .target(
      name: "SMCFanKit",
      dependencies: [
        "SMCKit",
        "AppLog",
      ],
      path: "Sources/SMCFanKit",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .target(
      name: "SMCFanProtocol",
      dependencies: [],
      path: "Sources/Common",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .target(
      name: "SMCFanXPCClient",
      dependencies: [
        "AppLog",
        "SMCFanProtocol",
      ],
      path: "Sources/SMCFanXPCClient",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .executableTarget(
      name: "smcfan",
      dependencies: [
        "AppLog",
        "SMCFanKit",
        "SMCFanProtocol",
        "SMCFanXPCClient",
      ],
      path: "Sources/CLI",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .testTarget(
      name: "AppLogTests",
      dependencies: ["AppLog"],
      path: "Tests/AppLogTests",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .testTarget(
      name: "SMCKitTests",
      dependencies: ["SMCKit"],
      path: "Tests/SMCKitTests",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .testTarget(
      name: "SMCFanKitTests",
      dependencies: ["SMCFanKit"],
      path: "Tests/SMCFanKitTests",
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
    .testTarget(
      name: "IntegrationTests",
      dependencies: [
        "SMCFanKit",
        "SMCFanProtocol",
        "SMCFanXPCClient",
      ],
      path: "Tests/IntegrationTests",
      exclude: ["Fixtures"],
      swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
      ]
    ),
  ]
)
