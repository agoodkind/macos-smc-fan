import Foundation

/// Configuration for SMC Fan Control
/// Injected by the consuming application - never hardcoded
public struct SMCFanConfiguration {
    /// Bundle identifier for the XPC helper service
    public let helperBundleID: String
    
    public init(helperBundleID: String) {
        self.helperBundleID = helperBundleID
    }
    
    #if canImport_smcfan_config
    /// Production configuration from generated config (config.mk → smcfan_config.h)
    public static let `default` = SMCFanConfiguration(
        helperBundleID: String(cString: HELPER_ID)
    )
    #else
    /// Development configuration from environment
    /// Set via: HELPER_BUNDLE_ID=com.your.helper swift build
    public static let `default`: SMCFanConfiguration = {
        guard let bundleID = ProcessInfo.processInfo.environment["HELPER_BUNDLE_ID"] else {
            fatalError(
                """
                HELPER_BUNDLE_ID environment variable not set.
                
                For development builds, set:
                  HELPER_BUNDLE_ID=com.your.helper swift build
                
                For production builds, use:
                  make all
                """
            )
        }
        return SMCFanConfiguration(helperBundleID: bundleID)
    }()
    #endif
}
