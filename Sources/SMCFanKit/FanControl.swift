//
//  FanControl.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-14.
//  Copyright © 2026
//

import Foundation
import Logging
import SMCKit

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
  private let logger: Logging.Logger

  public init(connection: SMCConnection, logger: Logging.Logger = Logging.Logger(label: "com.smcfankit.fan")) throws {
    self.connection = connection
    self.logger = logger
    self.config = try SMCHardwareConfig.detectHardwareKeys(connection: connection, logger: logger)
  }

  public init(connection: SMCConnection, hardwareConfig: SMCHardwareConfig, logger: Logging.Logger = Logging.Logger(label: "com.smcfankit.fan")) {
    self.connection = connection
    self.config = hardwareConfig
    self.logger = logger
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
      logger.debug("fan\(fanIndex) modeKey=\(modeKey) strategy=direct succeeded")
      return .direct
    } catch {
      logger.debug("fan\(fanIndex) modeKey=\(modeKey) direct write failed: \(error), ftstAvailable=\(config.ftstAvailable)")
      // Fall back to Ftst unlock sequence if available
      guard config.ftstAvailable else {
        logger.error("fan\(fanIndex) modeKey=\(modeKey) direct write failed and Ftst not available")
        throw SMCError.firmware(.notFound)
      }
    }

    // Use Ftst unlock sequence
    logger.debug("fan\(fanIndex) falling back to Ftst unlock sequence")
    try unlockFanControlSync(fanIndex: fanIndex)
    logger.debug("fan\(fanIndex) strategy=ftstUnlock succeeded")
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
    logger.debug("fan\(fanIndex) writing Ftst=1")
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
        logger.debug("fan\(fanIndex) modeKey=\(modeKey) unlocked after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
        return
      } catch {
        if Date() >= deadline {
          let elapsed = Date().timeIntervalSince(start)
          logger.error("fan\(fanIndex) modeKey=\(modeKey) timed out after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
          throw SMCError.timeout
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    logger.error("fan\(fanIndex) modeKey=\(modeKey) exhausted \(maxRetries) retries, elapsed=\(String(format: "%.2f", elapsed))s")
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
    logger.debug("fan\(fanIndex) writing Ftst=1")
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
        logger.debug("fan\(fanIndex) modeKey=\(modeKey) unlocked after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
        return
      } catch {
        if Date() >= deadline {
          let elapsed = Date().timeIntervalSince(start)
          logger.error("fan\(fanIndex) modeKey=\(modeKey) timed out after \(attempt) attempt(s), elapsed=\(String(format: "%.2f", elapsed))s")
          throw SMCError.timeout
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    logger.error("fan\(fanIndex) modeKey=\(modeKey) exhausted \(maxRetries) retries, elapsed=\(String(format: "%.2f", elapsed))s")
    throw SMCError.timeout
  }

  /// Reset fan control by disabling force test mode.
  ///
  /// Writes Ftst=0 to reset the force test state and return fans to normal operation.
  ///
  /// - Throws: SMCError if the Ftst key write fails
  public func resetFanControl() throws {
    logger.debug("writing Ftst=0 to reset fan control")
    try connection.writeKey(SMCFanKey.forceTest, bytes: [0])
    logger.debug("fan control reset complete")
  }
}
