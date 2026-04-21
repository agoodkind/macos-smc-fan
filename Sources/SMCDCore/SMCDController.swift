//
//  SMCDController.swift
//  smcd
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//

import AppLog
import Foundation
import SMCFanProtocol
import SMCFanXPCClient

private let log = AppLog.make(category: "SMCDController")

/// Per fan ownership record. An owner is whichever client most recently
/// wrote to the fan at a priority at least as high as any incumbent.
/// Ownership lapses after `ownerTTL` seconds without a further write at
/// which point any client may claim the fan regardless of priority.
public struct FanOwnerState: Sendable {
  public let clientID: ObjectIdentifier
  public let clientName: String
  public let priority: Int
  public var lastWriteAt: Date

  public init(clientID: ObjectIdentifier, clientName: String, priority: Int, lastWriteAt: Date) {
    self.clientID = clientID
    self.clientName = clientName
    self.priority = priority
    self.lastWriteAt = lastWriteAt
  }
}

/// XPC listener delegate + SMCDProtocol implementation.
///
/// Forwards reads and writes to `smcfanhelper` via a single long lived
/// `SMCFanXPCClient`. Arbitrates writes by priority. Exposes the SMCD
/// XPC surface to user space clients (fancurveagent, lmd-serve).
public final class SMCDController: NSObject, NSXPCListenerDelegate, SMCDProtocol, @unchecked Sendable {
  private let helper: SMCFanXPCClient
  private let ownerTTL: TimeInterval
  private let lock = NSLock()
  private var clientNames: [ObjectIdentifier: String] = [:]
  private var fanOwners: [UInt: FanOwnerState] = [:]

  public init(helper: SMCFanXPCClient, ownerTTL: TimeInterval = 10) {
    self.helper = helper
    self.ownerTTL = ownerTTL
    super.init()
    log.notice(
      "smcd.controller_init owner_ttl=\(ownerTTL, privacy: .public)"
    )
  }

  // MARK: - NSXPCListenerDelegate

  public func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    let pid = newConnection.processIdentifier
    let id = ObjectIdentifier(newConnection)
    log.info(
      "smcd.client_accepted pid=\(pid, privacy: .public)"
    )
    newConnection.exportedInterface = NSXPCInterface(with: SMCDProtocol.self)
    newConnection.exportedObject = self

    newConnection.invalidationHandler = { [weak self] in
      log.info(
        "smcd.client_disconnected pid=\(pid, privacy: .public)"
      )
      self?.cleanupClient(id: id)
    }
    newConnection.interruptionHandler = {
      log.debug(
        "smcd.client_interrupted pid=\(pid, privacy: .public)"
      )
    }

    newConnection.resume()
    return true
  }

  private func cleanupClient(id: ObjectIdentifier) {
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
        "smcd.ownership_released name=\(name, privacy: .public) fans=\(releasedFans.map { String($0) }.joined(separator: ","), privacy: .public)"
      )
    }
  }

  // MARK: - SMCDProtocol

  public func registerClient(
    name: String,
    reply: @escaping @Sendable (Bool, String?) -> Void
  ) {
    guard let conn = NSXPCConnection.current() else {
      log.error("smcd.register_no_connection")
      reply(false, "No XPC connection context")
      return
    }
    let id = ObjectIdentifier(conn)
    self.lock.lock()
    self.clientNames[id] = name
    self.lock.unlock()
    log.info(
      "smcd.client_registered pid=\(conn.processIdentifier, privacy: .public) name=\(name, privacy: .public)"
    )
    reply(true, nil)
  }

  public func setFanRPM(
    _ index: UInt,
    rpm: Float,
    priority: Int,
    reply: @escaping @Sendable (Bool, Bool, String?) -> Void
  ) {
    let clientID = self.currentClientID()
    let decision = self.decideClaim(fan: index, priority: priority, clientID: clientID)
    switch decision {
    case .rejected(let ownerName, let ownerPriority):
      log.debug(
        "smcd.write_rejected fan=\(index, privacy: .public) owner=\(ownerName, privacy: .public) owner_priority=\(ownerPriority, privacy: .public) caller_priority=\(priority, privacy: .public)"
      )
      reply(false, true, "preempted by \(ownerName) at priority \(ownerPriority)")
    case .accepted(let clientName):
      log.info(
        "smcd.fan_write fan=\(index, privacy: .public) rpm=\(Int(rpm.rounded()), privacy: .public) client=\(clientName, privacy: .public) priority=\(priority, privacy: .public)"
      )
      let helper = self.helper
      Task {
        do {
          try await helper.setFanRPM(index, rpm: rpm)
          reply(true, false, nil)
        } catch {
          log.error(
            "smcd.helper_setRpm_failed fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          reply(false, false, error.localizedDescription)
        }
      }
    }
  }

  public func setFanAuto(
    _ index: UInt,
    priority: Int,
    reply: @escaping @Sendable (Bool, Bool, String?) -> Void
  ) {
    let clientID = self.currentClientID()
    let decision = self.decideClaim(fan: index, priority: priority, clientID: clientID)
    switch decision {
    case .rejected(let ownerName, let ownerPriority):
      log.debug(
        "smcd.auto_rejected fan=\(index, privacy: .public) owner=\(ownerName, privacy: .public) owner_priority=\(ownerPriority, privacy: .public) caller_priority=\(priority, privacy: .public)"
      )
      reply(false, true, "preempted by \(ownerName) at priority \(ownerPriority)")
    case .accepted(let clientName):
      log.info(
        "smcd.fan_auto fan=\(index, privacy: .public) client=\(clientName, privacy: .public) priority=\(priority, privacy: .public)"
      )
      self.releaseOwnership(fan: index, clientID: clientID)
      let helper = self.helper
      Task {
        do {
          try await helper.setFanAuto(index)
          reply(true, false, nil)
        } catch {
          log.error(
            "smcd.helper_setAuto_failed fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          reply(false, false, error.localizedDescription)
        }
      }
    }
  }

  public func getFanCount(reply: @escaping @Sendable (Bool, UInt, String?) -> Void) {
    let helper = self.helper
    Task {
      do {
        let count = try await helper.getFanCount()
        reply(true, count, nil)
      } catch {
        log.error(
          "smcd.helper_getFanCount_failed error=\(error.localizedDescription, privacy: .public)"
        )
        reply(false, 0, error.localizedDescription)
      }
    }
  }

  public func getFanInfo(
    _ index: UInt,
    reply: @escaping @Sendable (Bool, Float, Float, Float, Float, Bool, String?) -> Void
  ) {
    let helper = self.helper
    Task {
      do {
        let info = try await helper.getFanInfo(index)
        reply(true, info.actualRPM, info.targetRPM, info.minRPM, info.maxRPM, info.manualMode, nil)
      } catch {
        log.error(
          "smcd.helper_getFanInfo_failed fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        reply(false, 0, 0, 0, 0, false, error.localizedDescription)
      }
    }
  }

  public func readKey(_ key: String, reply: @escaping @Sendable (Bool, Float, String?) -> Void) {
    let helper = self.helper
    Task {
      do {
        let v = try await helper.readKey(key)
        reply(true, v, nil)
      } catch {
        reply(false, 0, error.localizedDescription)
      }
    }
  }

  public func enumerateKeys(reply: @escaping @Sendable ([String]) -> Void) {
    let helper = self.helper
    Task {
      let keys = await helper.enumerateKeys()
      reply(keys)
    }
  }

  public func getOwnership(
    reply: @escaping @Sendable ([UInt], [String], [Int], [Double]) -> Void
  ) {
    let now = Date()
    self.lock.lock()
    let entries = self.fanOwners.map { (fan, state) in
      (fan, state.clientName, state.priority, now.timeIntervalSince(state.lastWriteAt))
    }
    self.lock.unlock()
    let sorted = entries.sorted { $0.0 < $1.0 }
    reply(
      sorted.map { $0.0 },
      sorted.map { $0.1 },
      sorted.map { $0.2 },
      sorted.map { $0.3 }
    )
  }

  // MARK: - Arbitration

  public enum ClaimDecision: Sendable {
    case accepted(clientName: String)
    case rejected(ownerName: String, ownerPriority: Int)
  }

  /// Decide whether `clientID` may write to `fan` at `priority`.
  /// Updates the owner record on accept. Public for testability: tests
  /// pass a synthetic `clientID` and optionally pre register a name.
  public func decideClaim(
    fan: UInt,
    priority: Int,
    clientID: ObjectIdentifier?,
    now: Date = Date()
  ) -> ClaimDecision {
    self.lock.lock()
    let clientName = (clientID.flatMap { self.clientNames[$0] }) ?? "<unregistered>"
    let existing = self.fanOwners[fan]

    if let state = existing,
       state.clientID != clientID,
       now.timeIntervalSince(state.lastWriteAt) < self.ownerTTL,
       priority < state.priority
    {
      self.lock.unlock()
      return .rejected(ownerName: state.clientName, ownerPriority: state.priority)
    }

    let resolvedID = clientID ?? ObjectIdentifier(self)
    self.fanOwners[fan] = FanOwnerState(
      clientID: resolvedID,
      clientName: clientName,
      priority: priority,
      lastWriteAt: now
    )
    self.lock.unlock()
    return .accepted(clientName: clientName)
  }

  /// Test hook for registering a client name against a synthetic identifier.
  public func registerClientName(_ name: String, for id: ObjectIdentifier) {
    self.lock.lock()
    self.clientNames[id] = name
    self.lock.unlock()
  }

  private func releaseOwnership(fan: UInt, clientID: ObjectIdentifier?) {
    guard let clientID = clientID else { return }
    self.lock.lock()
    if let state = self.fanOwners[fan], state.clientID == clientID {
      self.fanOwners.removeValue(forKey: fan)
    }
    self.lock.unlock()
  }

  private func currentClientID() -> ObjectIdentifier? {
    guard let conn = NSXPCConnection.current() else { return nil }
    return ObjectIdentifier(conn)
  }
}
