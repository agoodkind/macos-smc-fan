//
//  Config.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation

/// Configuration for SMC Fan Control
public struct SMCFanConfiguration {
    /// Bundle identifier for the XPC helper service
    public let helperBundleID: String
    
    public init(helperBundleID: String) {
        self.helperBundleID = helperBundleID
    }
}

// Default configuration
extension SMCFanConfiguration {
    /// Default configuration
    /// - Production (make all): Uses Config.generated.swift
    /// - Development (swift build): Uses HELPER_BUNDLE_ID environment variable
    public static let `default`: SMCFanConfiguration = {
        #if GENERATED_CONFIG
        // Production: Config.generated.swift provides the value
        return SMCFanConfiguration(helperBundleID: productionHelperBundleID)
        #else
        // Development: environment variable at runtime
        guard let bundleID = ProcessInfo.processInfo.environment["HELPER_BUNDLE_ID"] else {
            fatalError("HELPER_BUNDLE_ID not set. Use: HELPER_BUNDLE_ID=xxx swift build")
        }
        return SMCFanConfiguration(helperBundleID: bundleID)
        #endif
    }()
}

// Config.generated.swift defines this when built via Makefile
#if GENERATED_CONFIG
private let productionHelperBundleID: String = _productionHelperBundleIDFromGenerated
#endif
