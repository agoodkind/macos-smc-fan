import Foundation
import IOKit
#if !DIRECT_BUILD
import libsmc
#endif

// MARK: - SMC Connection Management
//
// These functions handle IOKit service discovery and connection lifecycle.
// They use IOKit directly (no C struct packing required).

/// Open connection to AppleSMC IOKit service
func smcOpenConnection() -> (io_connect_t, kern_return_t) {
    var iterator: io_iterator_t = 0
    let matchingDict = IOServiceMatching("AppleSMC")
    
    let matchResult = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matchingDict,
        &iterator
    )
    guard matchResult == kIOReturnSuccess else {
        return (0, matchResult)
    }
    
    let device = IOIteratorNext(iterator)
    IOObjectRelease(iterator)
    
    guard device != 0 else {
        return (0, kIOReturnNotFound)
    }
    
    var conn: io_connect_t = 0
    let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
    IOObjectRelease(device)
    
    return (conn, openResult)
}

// MARK: - Swift Wrappers for C SMC Functions
//
// Why these wrappers exist:
// - C functions require raw pointers (const char*, unsigned char*)
// - Swift arrays/strings don't auto-convert to C pointers
// - withCString/withUnsafeBytes provides safe temporary pointers
//
// Why the underlying C functions exist (see smc.h):
// - SMC requires IOConnectCallStructMethod with exact 80-byte struct layout
// - Swift's automatic struct padding differs from C (offset 39 vs 42)

/// Read SMC key, returning (result, value, size)
func smcRead(_ conn: io_connect_t, key: String) -> (kern_return_t, [UInt8], UInt32) {
    var value: [UInt8] = Array(repeating: 0, count: 32)
    var size: UInt32 = 0
    
    let result = key.withCString { keyPtr in
        value.withUnsafeMutableBufferPointer { bufferPtr in
            smc_read_key(conn, keyPtr, bufferPtr.baseAddress!, &size)
        }
    }
    
    return (result, value, size)
}

/// Write SMC key with byte array
func smcWrite(_ conn: io_connect_t, key: String, value: [UInt8], size: UInt32) -> kern_return_t {
    var val = value
    if val.count < 32 {
        val.append(contentsOf: [UInt8](repeating: 0, count: 32 - val.count))
    }
    
    return key.withCString { keyPtr in
        val.withUnsafeBytes { bytes in
            smc_write_key(conn, keyPtr, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), size)
        }
    }
}

// MARK: - Fan Control Unlock

/// Unlock fan control by writing Ftst=1 and retrying F0Md=1
/// This bypasses thermalmonitord's mode 3 lock
func smcUnlockFanControl(
    _ conn: io_connect_t,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
) -> kern_return_t {
    // Step 1: Write Ftst=1 to trigger unlock
    var result = smcWrite(conn, key: SMC_KEY_FAN_TEST, value: [1], size: 1)
    guard result == kIOReturnSuccess else { return result }
    
    // Step 2: Retry loop for F0Md=1 write
    let modeKey = String(format: SMC_KEY_FAN_MODE, 0)
    let startTime = Date()
    
    for _ in 0..<maxRetries {
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
