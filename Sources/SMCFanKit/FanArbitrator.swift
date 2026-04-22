//
//  FanArbitrator.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-21.
//  Copyright © 2026
//
//  Pure priority arbitration for SMC fan writes. Owned by the privileged
//  helper; clients never touch this type directly. Each connection is an
//  ObjectIdentifier as far as this type cares. The helper supplies the
//  actual NSXPCConnection identity at call time.
//

import AppLog
import Foundation

private let log = AppLog.make(category: "FanArbitrator")

/// Per fan ownership record. An owner is whichever client most recently
/// wrote to the fan at a priority at least as high as any incumbent.
/// Ownership lapses after `ownerTTL` seconds without a further write. At
/// that point any client may claim the fan regardless of priority.
public struct FanOwnerState: Sendable {
  public let clientID: ObjectIdentifier
  public let clientName: String
  public let priority: Int
  public var lastWriteAt: Date

  public init(
    clientID: ObjectIdentifier,
    clientName: String,
    priority: Int,
    lastWriteAt: Date
  ) {
    self.clientID = clientID
    self.clientName = clientName
    self.priority = priority
    self.lastWriteAt = lastWriteAt
  }
}

/// One row in an ownership snapshot.
public struct FanOwnershipSnapshotRow: Sendable {
  public let fanIndex: UInt
  public let clientName: String
  public let priority: Int
  public let ageSeconds: TimeInterval

  public init(
    fanIndex: UInt,
    clientName: String,
    priority: Int,
    ageSeconds: TimeInterval
  ) {
    self.fanIndex = fanIndex
    self.clientName = clientName
    self.priority = priority
    self.ageSeconds = ageSeconds
  }
}

public enum ClaimDecision: Sendable {
  case accepted(clientName: String)
  case rejected(ownerName: String, ownerPriority: Int)
}

/// Pure state machine for fan ownership. No XPC, no threads. The caller
/// passes a stable `clientID` (typically `ObjectIdentifier` of the
/// `NSXPCConnection`) and an optional human readable name registered via
/// `registerClientName`.
public final class FanArbitrator: @unchecked Sendable {
  private let ownerTTL: TimeInterval
  private let lock = NSLock()
  private var clientNames: [ObjectIdentifier: String] = [:]
  private var fanOwners: [UInt: FanOwnerState] = [:]

  public init(ownerTTL: TimeInterval = 10) {
    self.ownerTTL = ownerTTL
    log.notice(
      "arbitrator.init owner_ttl=\(ownerTTL, privacy: .public)"
    )
  }

  /// Associate a human readable name with a client connection. Idempotent.
  public func registerClientName(_ name: String, for id: ObjectIdentifier) {
    self.lock.lock()
    self.clientNames[id] = name
    self.lock.unlock()
  }

  /// Drop all state for a disconnected client.
  public func cleanupClient(id: ObjectIdentifier) {
    self.lock.lock()
    let name = self.clientNames.removeValue(forKey: id) ?? "<unknown>"
    var releasedFans: [UInt] = []
    for (fan, state) in self.fanOwners where state.clientID == id {
      self.fanOwners.removeValue(forKey: fan)
      releasedFans.append(fan)
    }
    self.lock.unlock()
    if !releasedFans.isEmpty {
      log.info(
        "arbitrator.ownership_released client=\(name, privacy: .public) fans=\(releasedFans.map { String($0) }.joined(separator: ","), privacy: .public)"
      )
    }
  }

  /// Release ownership of a single fan if the caller owns it. Used after
  /// an accepted setFanAuto so the fan's ownership clears immediately
  /// rather than waiting for the TTL.
  public func releaseOwnership(fan: UInt, clientID: ObjectIdentifier) {
    self.lock.lock()
    if let state = self.fanOwners[fan], state.clientID == clientID {
      self.fanOwners.removeValue(forKey: fan)
    }
    self.lock.unlock()
  }

  /// Decide whether `clientID` may write to `fan` at `priority`.
  /// Updates the owner record on accept.
  public func decideClaim(
    fan: UInt,
    priority: Int,
    clientID: ObjectIdentifier,
    now: Date = Date()
  ) -> ClaimDecision {
    self.lock.lock()
    let clientName = self.clientNames[clientID] ?? "<unregistered>"
    let existing = self.fanOwners[fan]

    if let state = existing,
       state.clientID != clientID,
       now.timeIntervalSince(state.lastWriteAt) < self.ownerTTL,
       priority < state.priority
    {
      self.lock.unlock()
      return .rejected(ownerName: state.clientName, ownerPriority: state.priority)
    }

    self.fanOwners[fan] = FanOwnerState(
      clientID: clientID,
      clientName: clientName,
      priority: priority,
      lastWriteAt: now
    )
    self.lock.unlock()
    return .accepted(clientName: clientName)
  }

  /// Snapshot of current ownership for diagnostics. Fans without an owner
  /// are not included. Sorted by fan index.
  public func getOwnershipSnapshot(now: Date = Date()) -> [FanOwnershipSnapshotRow] {
    self.lock.lock()
    let snapshot = self.fanOwners.map { (fan, state) in
      FanOwnershipSnapshotRow(
        fanIndex: fan,
        clientName: state.clientName,
        priority: state.priority,
        ageSeconds: now.timeIntervalSince(state.lastWriteAt)
      )
    }
    self.lock.unlock()
    return snapshot.sorted { $0.fanIndex < $1.fanIndex }
  }
}
