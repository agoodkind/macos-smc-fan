//
//  SMCConnection.swift
//  SMCFanHelper
//
//  Functional API wrapper for SMC operations and fan control unlock.
//
//  Created by Alex Goodkind on 2026-01-18.
//

import Foundation

// MARK: - Shared Connection

private var sharedConnection: SMCConnection?

/// Opens connection to AppleSMC. Returns dummy handle for compatibility.
func smcOpenConnection() -> (io_connect_t, kern_return_t) {
  if sharedConnection == nil {
    sharedConnection = SMCConnection()
  }
  let success = sharedConnection != nil
  return (success ? 1 : 0, success ? kIOReturnSuccess : kIOReturnError)
}

/// Closes SMC connection
func smcCloseConnection() {
  sharedConnection = nil
}

/// Reads raw bytes from SMC key
func smcRead(_: io_connect_t, key: String) -> (kern_return_t, [UInt8], UInt32) {
  guard let smc = sharedConnection else {
    return (kIOReturnNotOpen, [], 0)
  }
  return smc.readKey(key)
}

/// Writes raw bytes to SMC key
func smcWrite(_: io_connect_t, key: String, value: [UInt8], size: UInt32) -> kern_return_t {
  guard let smc = sharedConnection else {
    return kIOReturnNotOpen
  }
  let bytes = Array(value.prefix(Int(size)))
  return smc.writeKey(key, bytes: bytes)
}

// MARK: - Fan Control

/// Unlocks fan control by writing Ftst=1 and retrying mode write.
/// Bypasses thermalmonitord's Mode 3 enforcement on Apple Silicon.
func smcUnlockFanControl(
  _ conn: io_connect_t,
  fanIndex: Int = 0,
  maxRetries: Int = 100,
  timeout: TimeInterval = 10.0
) -> kern_return_t {
  // Write Ftst=1 to enter diagnostic mode
  var result = smcWrite(conn, key: SMCFanKey.forceTest, value: [1], size: 1)
  guard result == kIOReturnSuccess else { return result }

  // Retry writing mode=1 until thermalmonitord yields
  let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: fanIndex)
  let deadline = Date().addingTimeInterval(timeout)

  for _ in 0..<maxRetries {
    result = smcWrite(conn, key: modeKey, value: [1], size: 1)
    if result == kIOReturnSuccess {
      return kIOReturnSuccess
    }

    if Date() >= deadline {
      return kIOReturnTimeout
    }

    Thread.sleep(forTimeInterval: 0.1)
  }

  return kIOReturnTimeout
}

/// Resets fan control by writing Ftst=0, returning control to thermalmonitord
func smcResetFanControl(_ conn: io_connect_t) -> kern_return_t {
  smcWrite(conn, key: SMCFanKey.forceTest, value: [0], size: 1)
}
