//
//  SMCProtocol.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation

// MARK: - Types

/// Fan information returned from SMC
public struct FanInfo: Sendable {
  public let actualRPM: Float
  public let targetRPM: Float
  public let minRPM: Float
  public let maxRPM: Float
  public let manualMode: Bool

  public init(
    actualRPM: Float,
    targetRPM: Float,
    minRPM: Float,
    maxRPM: Float,
    manualMode: Bool
  ) {
    self.actualRPM = actualRPM
    self.targetRPM = targetRPM
    self.minRPM = minRPM
    self.maxRPM = maxRPM
    self.manualMode = manualMode
  }
}

/// Priority constants shared by every client that writes fans through
/// `SMCFanXPCClient`. The helper arbitrates per fan by these values.
/// Higher preempts lower while the incumbent is active. Constants are
/// advisory; any Int is valid.
public enum SMCFanPriority {
  /// Default passive curve. fancurveagent normal operation.
  public static let curveNormal = 10
  /// Cooldown after LLM unload. lmd during hold and ramp down.
  public static let llmCooling = 20
  /// Active LLM inference. lmd's FanCoordinator while inference runs.
  public static let llmActive = 50
  /// User initiated boost from the GUI.
  public static let userBoost = 50
}

/// XPC protocol for SMC fan control operations.
///
/// Reply signatures use primitive types only so the whole protocol crosses
/// the NSXPCConnection boundary without a custom coder. Writes return a
/// `preempted` flag in addition to `success` so callers can distinguish a
/// priority rejection from an SMC failure.
@objc public protocol SMCFanHelperProtocol {
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
    reply:
      @escaping @Sendable (
        Bool,
        Float,
        Float,
        Float,
        Float,
        Bool,
        String?
      ) -> Void
  )

  /// Request a fan RPM target. Rejected with `preempted=true` when a
  /// higher priority owner currently holds this fan. Ownership lapses
  /// after the helper's TTL with no further writes.
  func smcSetFanRPM(
    _ fanIndex: UInt,
    rpm: Float,
    priority: Int,
    reply: @escaping @Sendable (Bool, Bool, String?) -> Void
  )

  /// Hand the fan back to automatic/minimum speed control. Same
  /// arbitration rules as `smcSetFanRPM`.
  func smcSetFanAuto(
    _ fanIndex: UInt,
    priority: Int,
    reply: @escaping @Sendable (Bool, Bool, String?) -> Void
  )

  /// Enumerate all SMC keys
  func smcEnumerateKeys(
    reply: @escaping @Sendable ([String]) -> Void
  )

  /// Register a human readable name for this connection. Optional. When
  /// set, ownership diagnostics and preemption messages refer to this
  /// name instead of `<unregistered>`.
  func smcRegisterClient(
    name: String,
    reply: @escaping @Sendable (Bool, String?) -> Void
  )

  /// Snapshot of current arbitration state. Returns four parallel
  /// arrays, one entry per fan that currently has an owner.
  func smcGetOwnership(
    reply: @escaping @Sendable ([UInt], [String], [Int], [Double]) -> Void
  )
}

/// XPC protocol for log message forwarding from daemon to CLI
@objc public protocol SMCFanClientProtocol {
  func logMessage(_ message: String)
}
