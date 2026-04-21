//
//  SMCDProtocol.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//
//  XPC protocol that the user space smcd arbiter exposes to its clients
//  (fancurveagent, lmd-serve, and any future fan consumer). smcd owns the
//  single privileged XPC connection to smcfanhelper. Clients call smcd
//  instead of the privileged helper directly, and smcd arbitrates fan
//  writes by priority.
//

import Foundation

/// Priority constants that clients declare on each write. Higher priority
/// preempts lower priority while the owner is active. The constants are
/// suggestions, not a closed set; any Int is valid. Documented here so
/// every consumer agrees on a common scale.
public enum SMCDPriority {
  /// Default passive curve policy. fancurveagent normal operation.
  public static let curveNormal = 10
  /// Active LLM inference. lmd-serve's FanCoordinator while LLM is live.
  public static let llmActive = 50
  /// Cooldown phase after LLM unloads. lmd-serve during hold and ramp down.
  public static let llmCooling = 20
  /// User initiated boost from the GUI. fancurveagent when boost is on.
  public static let userBoost = 50
}

/// XPC protocol implemented by smcd and consumed by SMCFanClient targets.
///
/// Reply signatures use primitive types only so the same protocol can be
/// encoded across the NSXPCConnection boundary. Writes return a
/// `preempted` boolean in addition to `success` so clients can distinguish
/// arbitration rejection from helper failure.
@objc public protocol SMCDProtocol {
  /// Registers a client name on this connection. The name is recorded as
  /// part of the client identity used for ownership tracking. Idempotent.
  /// Calling again with a new name overwrites the previous value.
  func registerClient(
    name: String,
    reply: @escaping @Sendable (Bool, String?) -> Void
  )

  /// Request a fan RPM target. Rejected with `preempted=true` when a
  /// higher priority owner currently holds this fan.
  func setFanRPM(
    _ index: UInt,
    rpm: Float,
    priority: Int,
    reply: @escaping @Sendable (Bool, Bool, String?) -> Void
  )

  /// Hand the fan back to the SMC's automatic control. Same arbitration
  /// rules as setFanRPM.
  func setFanAuto(
    _ index: UInt,
    priority: Int,
    reply: @escaping @Sendable (Bool, Bool, String?) -> Void
  )

  /// Read number of fans from the SMC via smcfanhelper. Unconditional.
  func getFanCount(
    reply: @escaping @Sendable (Bool, UInt, String?) -> Void
  )

  /// Read fan info. Unconditional pass through.
  func getFanInfo(
    _ index: UInt,
    reply: @escaping @Sendable (Bool, Float, Float, Float, Float, Bool, String?) -> Void
  )

  /// Read a single SMC key. Unconditional pass through.
  func readKey(
    _ key: String,
    reply: @escaping @Sendable (Bool, Float, String?) -> Void
  )

  /// Enumerate all SMC keys. Unconditional pass through.
  func enumerateKeys(
    reply: @escaping @Sendable ([String]) -> Void
  )

  /// Snapshot of arbitration state, one entry per fan with a currently
  /// assigned owner. Fans absent from the reply are unowned. The reply
  /// is encoded as two parallel arrays so the payload traverses the XPC
  /// boundary without needing a custom coder: `fans[i]` owns
  /// `(names[i], priorities[i], ages[i])` where `ages[i]` is seconds
  /// since the owner's last write.
  func getOwnership(
    reply: @escaping @Sendable ([UInt], [String], [Int], [Double]) -> Void
  )
}
