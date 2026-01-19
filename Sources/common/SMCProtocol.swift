import Foundation

/// Fan information returned from SMC
struct FanInfo {
    let actualRPM: Float
    let targetRPM: Float
    let minRPM: Float
    let maxRPM: Float
    let manualMode: Bool
}

/// XPC protocol for SMC fan control operations
/// Note: Return values use separate parameters instead of structs for XPC compatibility
@objc protocol SMCFanHelperProtocol {
    /// Open connection to SMC
    func smcOpen(reply: @escaping @Sendable (Bool, String?) -> Void)
    
    /// Close connection to SMC
    func smcClose(reply: @escaping @Sendable (Bool, String?) -> Void)
    
    /// Read a single SMC key value
    func smcReadKey(
        _ key: String,
        reply: @escaping @Sendable (Bool, Float, String?) -> Void
    )
    
    /// Write a value to an SMC key
    func smcWriteKey(
        _ key: String,
        value: Float,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )
    
    /// Get the number of fans in the system
    func smcGetFanCount(
        reply: @escaping @Sendable (Bool, UInt, String?) -> Void
    )
    
    /// Get detailed information about a specific fan
    /// Returns: (success, actualRPM, targetRPM, minRPM, maxRPM, manualMode, error)
    func smcGetFanInfo(
        _ fanIndex: UInt,
        reply: @escaping @Sendable (
            Bool,
            Float,
            Float,
            Float,
            Float,
            Bool,
            String?
        ) -> Void
    )
    
    /// Set fan speed to a specific RPM
    func smcSetFanRPM(
        _ fanIndex: UInt,
        rpm: Float,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )
    
    /// Return fan to automatic/minimum speed control
    func smcSetFanAuto(
        _ fanIndex: UInt,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )
}
