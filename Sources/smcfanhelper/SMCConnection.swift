//
//  SMCConnection.swift
//  SMCFanHelper
//
//  High-level SMC fan control operations.
//
//  Created by Alex Goodkind on 2026-01-18.
//

import Foundation

#if !DIRECT_BUILD
  import SMCCommon
#endif

// MARK: - Fan Control Strategy

enum FanControlStrategy: Sendable {
  case direct
  case ftstUnlock
}

// MARK: - SMCConnection Extensions

extension SMCConnection {

  func enableManualMode(fanIndex: Int) throws -> FanControlStrategy {
    let modeKey = SMCFanKey.key(hwConfig.modeKeyFormat, fan: fanIndex)
    Log.debug("BEGIN fan=\(fanIndex) modeKey=\(modeKey)")

    // Try direct mode write first
    do {
      try writeKey(modeKey, bytes: [1])
      Log.connectionInfo("direct write \(modeKey)=1 succeeded for fan \(fanIndex)")
      return .direct
    } catch {
      Log.debug("direct write \(modeKey)=1 failed: \(error)")
      Log.connectionInfo(
        "direct write \(modeKey)=1 not accepted (expected on hardware requiring Ftst unlock)")
    }

    // Fall back to Ftst unlock sequence if available
    guard hwConfig.ftstAvailable else {
      Log.connectionWarning("Ftst not available and direct write failed for fan \(fanIndex)")
      throw SMCError.firmware(.notFound)
    }

    Log.connectionInfo("using Ftst unlock for fan \(fanIndex)")
    try unlockFanControlSync(fanIndex: fanIndex)
    Log.connectionInfo("Ftst unlock succeeded for fan \(fanIndex)")
    return .ftstUnlock
  }

  func unlockFanControlSync(
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
  ) throws {
    let startTime = Date()
    Log.debug("BEGIN fan=\(fanIndex) maxRetries=\(maxRetries) timeout=\(timeout)s")
    try writeKey(SMCFanKey.forceTest, bytes: [1])
    Log.debug("Ftst=1 written, sleeping 0.5s before mode key retries")

    Thread.sleep(forTimeInterval: 0.5)

    let modeKey = SMCFanKey.key(hwConfig.modeKeyFormat, fan: fanIndex)
    let deadline = Date().addingTimeInterval(timeout)

    for attempt in 0..<maxRetries {
      do {
        try writeKey(modeKey, bytes: [1])
        let elapsed = Date().timeIntervalSince(startTime)
        Log.debug(
          "mode key \(modeKey)=1 succeeded on attempt \(attempt) after \(String(format: "%.2f", elapsed))s"
        )
        return
      } catch {
        if Date() >= deadline {
          let elapsed = Date().timeIntervalSince(startTime)
          Log.debug(
            "TIMEOUT after \(attempt) attempts, \(String(format: "%.2f", elapsed))s, last error: \(error)"
          )
          throw SMCError.timeout
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)
    Log.debug("exhausted \(maxRetries) retries after \(String(format: "%.2f", elapsed))s")
    throw SMCError.timeout
  }

  func unlockFanControl(
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
  ) async throws {
    let startTime = Date()
    Log.debug("BEGIN fan=\(fanIndex) maxRetries=\(maxRetries) timeout=\(timeout)s")
    try writeKey(SMCFanKey.forceTest, bytes: [1])
    Log.debug("Ftst=1 written, sleeping 0.5s before mode key retries")

    try await Task.sleep(nanoseconds: 500_000_000)

    let modeKey = SMCFanKey.key(hwConfig.modeKeyFormat, fan: fanIndex)
    let deadline = Date().addingTimeInterval(timeout)

    for attempt in 0..<maxRetries {
      do {
        try writeKey(modeKey, bytes: [1])
        let elapsed = Date().timeIntervalSince(startTime)
        Log.debug(
          "mode key \(modeKey)=1 succeeded on attempt \(attempt) after \(String(format: "%.2f", elapsed))s"
        )
        return
      } catch {
        if Date() >= deadline {
          let elapsed = Date().timeIntervalSince(startTime)
          Log.debug(
            "TIMEOUT after \(attempt) attempts, \(String(format: "%.2f", elapsed))s, last error: \(error)"
          )
          throw SMCError.timeout
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)
    Log.debug("exhausted \(maxRetries) retries after \(String(format: "%.2f", elapsed))s")
    throw SMCError.timeout
  }

  func resetFanControl() throws {
    Log.debug("writing Ftst=0")
    try writeKey(SMCFanKey.forceTest, bytes: [0])
    Log.debug("Ftst=0 OK")
  }
}
