import Foundation
import IOKit

// MARK: - SMC Connection Management

//
// This file provides a functional API for SMC operations using the pure Swift
// SMC class. No C code is required.

private var sharedSMC: SMC?

/// Open connection to AppleSMC IOKit service
func smcOpenConnection() -> (io_connect_t, kern_return_t) {
    if sharedSMC == nil {
        sharedSMC = SMC()
    }
    // Return dummy connection handle - actual connection is managed by SMC class
    return (sharedSMC != nil ? 1 : 0, sharedSMC != nil ? kIOReturnSuccess : kIOReturnError)
}

/// Close SMC connection
func smcCloseConnection() {
    sharedSMC = nil
}

/// Read SMC key, returning (result, value, size)
func smcRead(_: io_connect_t, key: String) -> (kern_return_t, [UInt8], UInt32) {
    guard let smc = sharedSMC else {
        return (kIOReturnNotOpen, [], 0)
    }
    return smc.read(key: key)
}

/// Write SMC key with byte array
func smcWrite(_: io_connect_t, key: String, value: [UInt8], size: UInt32) -> kern_return_t {
    guard let smc = sharedSMC else {
        return kIOReturnNotOpen
    }
    return smc.write(key: key, value: value, size: size)
}

// MARK: - Fan Control Unlock

/// Unlock fan control by writing Ftst=1 and retrying mode write for the specified fan.
/// This bypasses thermalmonitord's mode 3 lock.
/// Sets the specified fan to manual mode (1) as part of the unlock.
func smcUnlockFanControl(
    _ conn: io_connect_t,
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
) -> kern_return_t {
    // Step 1: Write Ftst=1 to trigger unlock
    var result = smcWrite(conn, key: SMCKey.fanTest, value: [1], size: 1)
    guard result == kIOReturnSuccess else { return result }

    // Step 2: Retry writing mode=1 to the specified fan until it succeeds
    // This both verifies unlock and sets the fan to manual mode
    let modeKey = String(format: SMCKey.fanMode, fanIndex)
    let startTime = Date()

    for _ in 0 ..< maxRetries {
        result = smcWrite(conn, key: modeKey, value: [1], size: 1)

        if result == kIOReturnSuccess {
            return kIOReturnSuccess
        }

        if Date().timeIntervalSince(startTime) >= timeout {
            return kIOReturnTimeout
        }

        Thread.sleep(forTimeInterval: 0.1)
    }

    return kIOReturnTimeout
}
