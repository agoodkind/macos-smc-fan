//
//  FanControl.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-14.
//  Copyright © 2026
//

import Foundation
import SMCKit
import os

// MARK: - Logging Helpers

private let fanLog = OSLog(subsystem: "com.smcfankit", category: "fan")

private func logDebug(_ message: String, function: String = #function) {
  os_log(.debug, log: fanLog, "%{public}s: %{public}s", function, message)
}

private func logError(_ message: String, function: String = #function) {
  os_log(.error, log: fanLog, "%{public}s: %{public}s", function, message)
}

// MARK: - Fan Control Strategy

/// Strategy used to enable manual fan control
public enum FanControlStrategy: Sendable {
  /// Direct mode key write succeeded
  case direct

  /// Ftst (force test) unlock was required
  case ftstUnlock
}

// MARK: - Fan Controller

/// Manages fan control operations on SMC hardware.
///
/// FanController coordinates with an SMCConnection and detected hardware configuration
/// to enable, unlock, and reset fan control modes.
public class FanController {
  public let connection: SMCConnection
  public let config: SMCHardwareConfig

  /// Initialize a FanController with an open connection.
  ///
  /// Probes the hardware to detect configuration, then stores both the connection
  /// and hardware config for use in control operations.
  ///
  /// - Parameter connection: An open SMCConnection
  /// - Throws: SMCError if hardware detection fails
  public init(connection: SMCConnection) throws {
    self.connection = connection
    self.config = try SMCHardwareConfig.detectHardwareKeys(connection: connection)
  }

  /// Initialize with explicit hardware configuration.
  ///
  /// Use this when you already have hardware config (e.g., from a previous detection).
  ///
  /// - Parameters:
  ///   - connection: An open SMCConnection
  ///   - hardwareConfig: Pre-detected hardware configuration
  public init(connection: SMCConnection, hardwareConfig: SMCHardwareConfig) {
    self.connection = connection
    self.config = hardwareConfig
  }

  // MARK: - Control Operations

  /// Enable manual fan control mode for a specific fan.
  ///
  /// Attempts direct mode key write first. If that fails and Ftst is available,
  /// performs an Ftst unlock sequence before trying the mode key write again.
  ///
  /// - Parameter fanIndex: The index of the fan to control
  /// - Returns: The strategy that was used to enable manual mode
  /// - Throws: SMCError if manual mode cannot be enabled
  public func enableManualMode(fanIndex: Int) throws -> FanControlStrategy {
    let modeKey = SMCFanKey.key(config.modeKeyFormat, fan: fanIndex)

    // Try direct mode write first
    do {
      try connection.writeKey(modeKey, bytes: [1])
      logDebug("fan\(fanIndex) modeKey=\(modeKey) strategy=direct succeeded")
      return .direct
    } catch {
      logDebug("fan\(fanIndex) modeKey=\(modeKey) direct write failed: \(error), ftstAvailable=\(config.ftstAvailable)")
      // Fall back to Ftst unlock sequence if available
      guard config.ftstAvailable else {
        logError("fan\(fanIndex) modeKey=\(modeKey) direct write failed and Ftst not available")
        throw SMCError.firmware(.notFound)
      }
    }

    // Use Ftst unlock sequence
    logDebug("fan\(fanIndex) falling back to Ftst unlock sequence")
    try unlockFanControlSync(fanIndex: fanIndex)
    logDebug("fan\(fanIndex) strategy=ftstUnlock succeeded")
    return .ftstUnlock
  }

  /// Synchronously unlock fan control using Ftst (force test) sequence.
  ///
  /// Writes Ftst=1, waits, then retries the mode key write with exponential backoff
  /// until success or timeout.
  ///
  /// - Parameters:
  ///   - fanIndex: The index of the fan to unlock
  ///   - maxRetries: Maximum number of retry attempts (default: 100)
  ///   - timeout: Maximum elapsed time in seconds (default: 10.0)
  /// - Throws: SMCError.timeout if mode key write doesn't succeed within the timeout
  public func unlockFanControlSync(
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
  ) throws {
    logDebug("fan\(fanIndex) writing Ftst=1")
    try connection.writeKey(SMCFanKey.forceTest, bytes: [1])

    Thread.sleep(forTimeInterval: 0.5)

    let modeKey = SMCFanKey.key(config.modeKeyFormat, fan: fanIndex)
    let start = Date()
    let deadline = start.addingTimeInterval(timeout)

    var attempt = 0
    for _ in 0..<maxRetries {
      attempt += 1
      do {
        try connection.writeKey(modeKey, bytes: [1])
        let elapsed = Date().timeIntervalSince(start)
        logDebug("fan\(fanIndex) modeKey=\(modeKey) unlocked after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
        return
      } catch {
        if Date() >= deadline {
          let elapsed = Date().timeIntervalSince(start)
          logError("fan\(fanIndex) modeKey=\(modeKey) timed out after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
          throw SMCError.timeout
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    logError("fan\(fanIndex) modeKey=\(modeKey) exhausted \(maxRetries) retries, elapsed=\(String(format: "%.2f", elapsed))s")
    throw SMCError.timeout
  }

  /// Asynchronously unlock fan control using Ftst (force test) sequence.
  ///
  /// Writes Ftst=1, waits, then retries the mode key write with exponential backoff
  /// until success or timeout. Uses async/await for non-blocking operation.
  ///
  /// - Parameters:
  ///   - fanIndex: The index of the fan to unlock
  ///   - maxRetries: Maximum number of retry attempts (default: 100)
  ///   - timeout: Maximum elapsed time in seconds (default: 10.0)
  /// - Throws: SMCError.timeout if mode key write doesn't succeed within the timeout
  public func unlockFanControl(
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
  ) async throws {
    logDebug("fan\(fanIndex) writing Ftst=1")
    try connection.writeKey(SMCFanKey.forceTest, bytes: [1])

    try await Task.sleep(nanoseconds: 500_000_000)

    let modeKey = SMCFanKey.key(config.modeKeyFormat, fan: fanIndex)
    let start = Date()
    let deadline = start.addingTimeInterval(timeout)

    var attempt = 0
    for _ in 0..<maxRetries {
      attempt += 1
      do {
        try connection.writeKey(modeKey, bytes: [1])
        let elapsed = Date().timeIntervalSince(start)
        logDebug("fan\(fanIndex) modeKey=\(modeKey) unlocked after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
        return
      } catch {
        if Date() >= deadline {
          let elapsed = Date().timeIntervalSince(start)
          logError("fan\(fanIndex) modeKey=\(modeKey) timed out after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
          throw SMCError.timeout
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    logError("fan\(fanIndex) modeKey=\(modeKey) exhausted \(maxRetries) retries, elapsed=\(String(format: "%.2f", elapsed))s")
    throw SMCError.timeout
  }

  /// Reset fan control by disabling force test mode.
  ///
  /// Writes Ftst=0 to reset the force test state and return fans to normal operation.
  ///
  /// - Throws: SMCError if the Ftst key write fails
  public func resetFanControl() throws {
    logDebug("writing Ftst=0 to reset fan control")
    try connection.writeKey(SMCFanKey.forceTest, bytes: [0])
    logDebug("fan control reset complete")
  }
}
