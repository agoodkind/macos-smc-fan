//
//  SMCDClient.swift
//  SMCDClient
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//
//  User space client for the smcd arbiter. Mirrors SMCFanXPCClient's
//  robust reconnect pattern: lazy NSXPCConnection, invalidation and
//  interruption handlers that clear state, per call proxy guarded by
//  ResumeGuard, bounded timeout sync wrappers.
//

import AppLog
import Foundation
import SMCFanProtocol

private let log = AppLog.make(category: "SMCDClient")

// MARK: - Errors

public struct SMCDError: LocalizedError, Sendable {
  public let message: String
  public var errorDescription: String? { message }
  public init(_ message: String?) {
    self.message = message ?? "Unknown error"
  }
}

/// Write was rejected because a higher priority client currently owns the fan.
public struct SMCDConflictError: LocalizedError, Sendable {
  public let message: String
  public var errorDescription: String? { message }
  public init(_ message: String?) {
    self.message = message ?? "Preempted by higher priority client"
  }
}

public struct SMCDTimeoutError: LocalizedError, Sendable {
  public let label: String
  public let seconds: TimeInterval
  public var errorDescription: String? {
    "SMCD \(label) timed out after \(seconds)s"
  }
  public init(label: String, seconds: TimeInterval) {
    self.label = label
    self.seconds = seconds
  }
}

// MARK: - Internal state boxes

private final class SyncErrorBox: @unchecked Sendable {
  var error: Error?
}

private final class SyncFanInfoBox: @unchecked Sendable {
  var info: FanInfo?
}

private final class SyncFloatBox: @unchecked Sendable {
  var value: Float = 0
}

private final class SyncUIntBox: @unchecked Sendable {
  var value: UInt = 0
}

// MARK: - ResumeGuard

/// Single use gate ensuring a closure runs exactly once. Matches the one in
/// SMCFanXPCClient. The per call proxy's error handler and the XPC reply
/// can both fire in failure paths.
private final class ResumeGuard: @unchecked Sendable {
  private var fired = false
  private let lock = NSLock()

  func tryResume(_ action: () -> Void) {
    lock.lock()
    if fired {
      lock.unlock()
      return
    }
    fired = true
    lock.unlock()
    action()
  }
}

// MARK: - Client

/// XPC client for the user space smcd arbiter.
///
/// Holds a single lazy NSXPCConnection that is recreated on invalidation.
/// Every call uses a fresh per call proxy via `remoteObjectProxyWithErrorHandler`.
/// The client re-issues `registerClient(name:)` automatically after any reconnect.
public final class SMCDClient: @unchecked Sendable {
  public static let defaultSyncTimeout: TimeInterval = 5.0

  private let smcdBundleID: String
  private let clientName: String
  private let defaultPriority: Int
  private let syncTimeout: TimeInterval

  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var registered = false

  public init(
    clientName: String,
    defaultPriority: Int,
    syncTimeout: TimeInterval = SMCDClient.defaultSyncTimeout
  ) {
    self.smcdBundleID = SMCFanConfiguration.default.smcdBundleID
    self.clientName = clientName
    self.defaultPriority = defaultPriority
    self.syncTimeout = syncTimeout
    log.debug(
      "smcd_client.init name=\(clientName, privacy: .public) default_priority=\(defaultPriority, privacy: .public)"
    )
  }

  deinit {
    self.lock.lock()
    let conn = self.connection
    self.connection = nil
    self.lock.unlock()
    conn?.invalidate()
  }

  /// Explicit teardown before process exit. Safe to call more than once.
  public func shutdown() {
    self.lock.lock()
    let conn = self.connection
    self.connection = nil
    self.registered = false
    self.lock.unlock()
    conn?.invalidate()
    log.debug("smcd_client.shutdown name=\(self.clientName, privacy: .public)")
  }

  // MARK: - Connection lifecycle

  private func ensureConnection() -> NSXPCConnection {
    self.lock.lock()
    if let conn = self.connection {
      self.lock.unlock()
      return conn
    }
    let conn = NSXPCConnection(machServiceName: self.smcdBundleID)
    conn.remoteObjectInterface = NSXPCInterface(with: SMCDProtocol.self)
    conn.interruptionHandler = { [weak self] in
      log.debug("smcd_client.interrupted action=register_on_next_call")
      guard let self = self else { return }
      self.lock.lock()
      self.registered = false
      self.lock.unlock()
    }
    conn.invalidationHandler = { [weak self] in
      log.debug("smcd_client.invalidated action=reconnect_on_next_call")
      guard let self = self else { return }
      self.lock.lock()
      self.connection = nil
      self.registered = false
      self.lock.unlock()
    }
    conn.resume()
    self.connection = conn
    self.lock.unlock()
    log.debug(
      "smcd_client.connected mach_service=\(self.smcdBundleID, privacy: .public)"
    )
    return conn
  }

  private func isRegistered() -> Bool {
    self.lock.lock()
    let v = self.registered
    self.lock.unlock()
    return v
  }

  private func markRegistered() {
    self.lock.lock()
    self.registered = true
    self.lock.unlock()
  }

  private func ensureRegistered() async throws {
    if self.isRegistered() { return }
    try await self.register()
    self.markRegistered()
  }

  private func ensureRegisteredSync() throws {
    if self.isRegistered() { return }
    try self.registerSync()
    self.markRegistered()
  }

  private func register() async throws {
    let conn = self.ensureConnection()
    let name = self.clientName
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "smcd_client.register_proxy_error error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCDError("Failed to get smcd proxy"))
        }
        return
      }
      p.registerClient(name: name) { success, message in
        once.tryResume {
          if success {
            continuation.resume()
          } else {
            continuation.resume(throwing: SMCDError(message))
          }
        }
      }
    }
  }

  private func registerSync() throws {
    let conn = self.ensureConnection()
    let name = self.clientName
    let sem = DispatchSemaphore(value: 0)
    let errBox = SyncErrorBox()
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        log.error(
          "smcd_client.register_proxy_error_sync error=\(error.localizedDescription, privacy: .public)"
        )
        errBox.error = SMCDError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCDProtocol else {
      throw SMCDError("Failed to get smcd proxy")
    }
    p.registerClient(name: name) { success, message in
      once.tryResume {
        if !success {
          errBox.error = SMCDError(message)
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      throw SMCDTimeoutError(label: "register", seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
  }

  // MARK: - Async write API

  public func setFanRPM(
    _ index: UInt,
    rpm: Float
  ) async throws {
    try await self.setFanRPM(index, rpm: rpm, priority: self.defaultPriority)
  }

  public func setFanRPM(
    _ index: UInt,
    rpm: Float,
    priority: Int
  ) async throws {
    try await self.ensureRegistered()
    let conn = self.ensureConnection()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "smcd_client.setFanRPM_proxy_error fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCDError("Failed to get smcd proxy"))
        }
        return
      }
      p.setFanRPM(index, rpm: rpm, priority: priority) { success, preempted, message in
        once.tryResume {
          if success {
            continuation.resume()
          } else if preempted {
            continuation.resume(throwing: SMCDConflictError(message))
          } else {
            continuation.resume(throwing: SMCDError(message))
          }
        }
      }
    }
  }

  public func setFanAuto(_ index: UInt) async throws {
    try await self.setFanAuto(index, priority: self.defaultPriority)
  }

  public func setFanAuto(_ index: UInt, priority: Int) async throws {
    try await self.ensureRegistered()
    let conn = self.ensureConnection()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCDError("Failed to get smcd proxy"))
        }
        return
      }
      p.setFanAuto(index, priority: priority) { success, preempted, message in
        once.tryResume {
          if success {
            continuation.resume()
          } else if preempted {
            continuation.resume(throwing: SMCDConflictError(message))
          } else {
            continuation.resume(throwing: SMCDError(message))
          }
        }
      }
    }
  }

  // MARK: - Async read API

  public func getFanCount() async throws -> UInt {
    try await self.ensureRegistered()
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<UInt, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume { continuation.resume(throwing: SMCDError("Failed to get smcd proxy")) }
        return
      }
      p.getFanCount { success, count, message in
        once.tryResume {
          if success { continuation.resume(returning: count) }
          else { continuation.resume(throwing: SMCDError(message)) }
        }
      }
    }
  }

  public func getFanInfo(_ index: UInt) async throws -> FanInfo {
    try await self.ensureRegistered()
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<FanInfo, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume { continuation.resume(throwing: SMCDError("Failed to get smcd proxy")) }
        return
      }
      p.getFanInfo(index) { success, actual, target, min, max, manual, message in
        once.tryResume {
          if success {
            continuation.resume(returning: FanInfo(
              actualRPM: actual, targetRPM: target,
              minRPM: min, maxRPM: max, manualMode: manual
            ))
          } else {
            continuation.resume(throwing: SMCDError(message))
          }
        }
      }
    }
  }

  public func readKey(_ key: String) async throws -> Float {
    try await self.ensureRegistered()
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Float, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume { continuation.resume(throwing: SMCDError("Failed to get smcd proxy")) }
        return
      }
      p.readKey(key) { success, value, message in
        once.tryResume {
          if success { continuation.resume(returning: value) }
          else { continuation.resume(throwing: SMCDError(message)) }
        }
      }
    }
  }

  /// A single fan ownership row returned by `getOwnership`.
  public struct OwnershipEntry: Sendable {
    public let fanIndex: UInt
    public let clientName: String
    public let priority: Int
    /// Seconds since the owner's last write, as measured by smcd at the
    /// moment the snapshot was taken.
    public let secondsSinceLastWrite: TimeInterval
    public init(fanIndex: UInt, clientName: String, priority: Int, secondsSinceLastWrite: TimeInterval) {
      self.fanIndex = fanIndex
      self.clientName = clientName
      self.priority = priority
      self.secondsSinceLastWrite = secondsSinceLastWrite
    }
  }

  /// Snapshot of smcd's current per fan arbitration state.
  public func getOwnership() async throws -> [OwnershipEntry] {
    try await self.ensureRegistered()
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[OwnershipEntry], Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCDError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume { continuation.resume(throwing: SMCDError("Failed to get smcd proxy")) }
        return
      }
      p.getOwnership { fans, names, priorities, ages in
        once.tryResume {
          let count = min(fans.count, names.count, priorities.count, ages.count)
          let entries: [OwnershipEntry] = (0..<count).map { i in
            OwnershipEntry(
              fanIndex: fans[i],
              clientName: names[i],
              priority: priorities[i],
              secondsSinceLastWrite: ages[i]
            )
          }
          continuation.resume(returning: entries)
        }
      }
    }
  }

  public func enumerateKeys() async -> [String] {
    do { try await self.ensureRegistered() } catch { return [] }
    let conn = self.ensureConnection()
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<[String], Never>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
        once.tryResume { continuation.resume(returning: []) }
      }
      guard let p = proxy as? SMCDProtocol else {
        once.tryResume { continuation.resume(returning: []) }
        return
      }
      p.enumerateKeys { keys in
        once.tryResume { continuation.resume(returning: keys) }
      }
    }
  }

  // MARK: - Sync write API

  public func setFanRPMSync(_ index: UInt, rpm: Float) throws {
    try self.setFanRPMSync(index, rpm: rpm, priority: self.defaultPriority)
  }

  public func setFanRPMSync(_ index: UInt, rpm: Float, priority: Int) throws {
    try self.ensureRegisteredSync()
    let conn = self.ensureConnection()
    let sem = DispatchSemaphore(value: 0)
    let errBox = SyncErrorBox()
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        errBox.error = SMCDError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCDProtocol else {
      throw SMCDError("Failed to get smcd proxy")
    }
    p.setFanRPM(index, rpm: rpm, priority: priority) { success, preempted, message in
      once.tryResume {
        if !success {
          if preempted {
            errBox.error = SMCDConflictError(message)
          } else {
            errBox.error = SMCDError(message)
          }
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      throw SMCDTimeoutError(label: "setFanRPMSync[\(index)]", seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
  }

  public func setFanAutoSync(_ index: UInt) throws {
    try self.setFanAutoSync(index, priority: self.defaultPriority)
  }

  public func setFanAutoSync(_ index: UInt, priority: Int) throws {
    try self.ensureRegisteredSync()
    let conn = self.ensureConnection()
    let sem = DispatchSemaphore(value: 0)
    let errBox = SyncErrorBox()
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        errBox.error = SMCDError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCDProtocol else {
      throw SMCDError("Failed to get smcd proxy")
    }
    p.setFanAuto(index, priority: priority) { success, preempted, message in
      once.tryResume {
        if !success {
          if preempted {
            errBox.error = SMCDConflictError(message)
          } else {
            errBox.error = SMCDError(message)
          }
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      throw SMCDTimeoutError(label: "setFanAutoSync[\(index)]", seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
  }

  // MARK: - Sync read API

  public func getFanInfoSync(_ index: UInt) throws -> FanInfo {
    try self.ensureRegisteredSync()
    let conn = self.ensureConnection()
    let sem = DispatchSemaphore(value: 0)
    let errBox = SyncErrorBox()
    let infoBox = SyncFanInfoBox()
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        errBox.error = SMCDError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCDProtocol else {
      throw SMCDError("Failed to get smcd proxy")
    }
    p.getFanInfo(index) { success, actual, target, min, max, manual, message in
      once.tryResume {
        if success {
          infoBox.info = FanInfo(
            actualRPM: actual, targetRPM: target,
            minRPM: min, maxRPM: max, manualMode: manual
          )
        } else {
          errBox.error = SMCDError(message)
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      throw SMCDTimeoutError(label: "getFanInfoSync[\(index)]", seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
    guard let info = infoBox.info else {
      throw SMCDError("Missing fan info")
    }
    return info
  }
}
