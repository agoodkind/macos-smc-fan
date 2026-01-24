// swift-tools-version: 5.9
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
        // Low-level C library for SMC hardware access
        .target(
            name: "libsmc",
            path: "Sources/libsmc",
            exclude: [],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),

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
    ],
    cLanguageStandard: .c11
)
