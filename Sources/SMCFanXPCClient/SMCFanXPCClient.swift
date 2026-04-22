//
//  SMCFanXPCClient.swift
//  SMCFanXPCClient
//

import AppLog
import Foundation
import SMCFanProtocol

private let log = AppLog.make(category: "SMCFanXPCClient")

// MARK: - Error types

public struct SMCXPCError: LocalizedError, Sendable {
  public let message: String

  public var errorDescription: String? { message }

  public init(_ message: String?) {
    self.message = message ?? "Unknown error"
  }
}

/// Thrown when a sync call exceeds its bounded wait.
public struct SMCXPCTimeoutError: LocalizedError, Sendable {
  public let label: String
  public let seconds: TimeInterval

  public var errorDescription: String? {
    "SMC \(label) timed out after \(seconds)s"
  }

  public init(label: String, seconds: TimeInterval) {
    self.label = label
    self.seconds = seconds
  }
}

/// A fan write was rejected by the helper because a higher priority owner
/// currently holds that fan. The write did not land. Callers typically log
/// this at debug and retry on the next tick.
public struct SMCXPCConflictError: LocalizedError, Sendable {
  public let message: String

  public var errorDescription: String? { message }

  public init(_ message: String?) {
    self.message = message ?? "Preempted by higher priority client"
  }
}

// MARK: - Sync result boxes

private final class SyncErrorBox: @unchecked Sendable {
  var error: Error?
}

private final class SyncFanInfoBox: @unchecked Sendable {
  var info: FanInfo?
}

// MARK: - ResumeGuard

/// Single use gate ensuring a closure runs exactly once. The per call proxy's
/// error handler and the XPC reply can both fire in failure paths. The
/// continuation or the semaphore must only receive exactly one signal.
///
/// Internal rather than private so tests in SMCFanXPCClientTests can verify
/// the exactly once semantics directly.
final class ResumeGuard: @unchecked Sendable {
  private var fired = false
  private let lock = NSLock()

  init() {}

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

  /// Observable state for tests. Do not use in production code paths.
  var hasFired: Bool {
    lock.lock()
    let v = fired
    lock.unlock()
    return v
  }
}

// MARK: - Client

/// XPC client for the privileged SMC fan helper.
///
/// Safe for long running daemons. The client holds a single NSXPCConnection
/// that is recreated lazily on the next call after invalidation or
/// interruption. Every call uses a fresh per call proxy via
/// `remoteObjectProxyWithErrorHandler`. A `ResumeGuard` ensures the
/// continuation or the semaphore receives exactly one signal, whether the
/// reply fires or the error handler fires first.
///
/// Every write carries a priority. The helper arbitrates: higher priority
/// preempts a current owner, lower priority is rejected with an
/// `SMCXPCConflictError`. Ownership lapses on the helper's TTL. If a
/// `clientName` was supplied at init, it is automatically re-registered
/// on reconnect so ownership diagnostics in smcfan list remain useful.
public final class SMCFanXPCClient: @unchecked Sendable {
  /// Default bounded wait for every sync call before `SMCXPCTimeoutError` is
  /// thrown. Chosen so first call authorization on a fresh privileged
  /// connection has room to complete.
  public static let defaultSyncTimeout: TimeInterval = 5.0

  public struct OwnershipEntry: Sendable {
    public let fanIndex: UInt
    public let clientName: String
    public let priority: Int
    /// Seconds since the owner's last write, measured by the helper at
    /// snapshot time.
    public let secondsSinceLastWrite: TimeInterval
    public init(fanIndex: UInt, clientName: String, priority: Int, secondsSinceLastWrite: TimeInterval) {
      self.fanIndex = fanIndex
      self.clientName = clientName
      self.priority = priority
      self.secondsSinceLastWrite = secondsSinceLastWrite
    }
  }

  private let helperBundleID: String
  private let syncTimeout: TimeInterval
  private let clientName: String?
  private let defaultPriority: Int
  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var smcOpened = false
  private var registered = false

  public init(
    clientName: String? = nil,
    defaultPriority: Int = SMCFanPriority.curveNormal,
    syncTimeout: TimeInterval = SMCFanXPCClient.defaultSyncTimeout
  ) throws {
    self.helperBundleID = SMCFanConfiguration.default.helperBundleID
    self.syncTimeout = syncTimeout
    self.clientName = clientName
    self.defaultPriority = defaultPriority
    log.debug(
      "xpc.client_init bundle_id=\(self.helperBundleID, privacy: .public) client_name=\(clientName ?? "<none>", privacy: .public) default_priority=\(defaultPriority, privacy: .public) sync_timeout=\(self.syncTimeout, privacy: .public)"
    )
  }

  deinit {
    self.lock.lock()
    let conn = self.connection
    self.connection = nil
    self.lock.unlock()
    conn?.invalidate()
  }

  /// Explicit teardown for callers that need to release the connection before
  /// process exit. Safe to call more than once.
  public func shutdown() {
    self.lock.lock()
    let conn = self.connection
    self.connection = nil
    self.smcOpened = false
    self.registered = false
    self.lock.unlock()
    conn?.invalidate()
    log.debug("xpc.client_shutdown")
  }

  // MARK: - Connection management

  private func ensureConnection() throws -> NSXPCConnection {
    self.lock.lock()
    if let conn = self.connection {
      self.lock.unlock()
      return conn
    }
    let conn = NSXPCConnection(
      machServiceName: self.helperBundleID,
      options: .privileged
    )
    conn.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)

    conn.interruptionHandler = { [weak self] in
      log.debug("xpc.connection_interrupted action=reopen_on_next_call")
      guard let self = self else { return }
      self.lock.lock()
      self.smcOpened = false
      self.registered = false
      self.lock.unlock()
    }

    conn.invalidationHandler = { [weak self] in
      log.debug("xpc.connection_invalidated action=recreate_on_next_call")
      guard let self = self else { return }
      self.lock.lock()
      self.connection = nil
      self.smcOpened = false
      self.registered = false
      self.lock.unlock()
    }

    conn.resume()
    self.connection = conn
    self.lock.unlock()
    log.debug(
      "xpc.connection_created bundle_id=\(self.helperBundleID, privacy: .public)"
    )
    return conn
  }

  private func markOpened() {
    self.lock.lock()
    self.smcOpened = true
    self.lock.unlock()
  }

  private func markClosed() {
    self.lock.lock()
    self.smcOpened = false
    self.lock.unlock()
  }

  private func isOpened() -> Bool {
    self.lock.lock()
    let v = self.smcOpened
    self.lock.unlock()
    return v
  }

  private func markRegistered() {
    self.lock.lock()
    self.registered = true
    self.lock.unlock()
  }

  private func isRegistered() -> Bool {
    self.lock.lock()
    let v = self.registered
    self.lock.unlock()
    return v
  }

  private func ensureOpened() async throws {
    if self.isOpened() { return }
    try await self.callVoid(skipEnsureOpen: true, skipEnsureRegistered: true) { proxy, reply in
      proxy.smcOpen(reply: reply)
    }
    self.markOpened()
    log.debug("xpc.smc_opened")
  }

  private func ensureRegistered() async throws {
    guard let name = self.clientName else { return }
    if self.isRegistered() { return }
    try await self.callVoid(skipEnsureOpen: true, skipEnsureRegistered: true) { proxy, reply in
      proxy.smcRegisterClient(name: name, reply: reply)
    }
    self.markRegistered()
    log.debug("xpc.client_registered name=\(name, privacy: .public)")
  }

  private func ensureOpenedSync() throws {
    if self.isOpened() { return }
    try self.callVoidSync(
      label: "smcOpen",
      skipEnsureOpen: true,
      skipEnsureRegistered: true
    ) { proxy, reply in
      proxy.smcOpen(reply: reply)
    }
    self.markOpened()
    log.debug("xpc.smc_opened_sync")
  }

  private func ensureRegisteredSync() throws {
    guard let name = self.clientName else { return }
    if self.isRegistered() { return }
    try self.callVoidSync(
      label: "smcRegisterClient",
      skipEnsureOpen: true,
      skipEnsureRegistered: true
    ) { proxy, reply in
      proxy.smcRegisterClient(name: name, reply: reply)
    }
    self.markRegistered()
    log.debug("xpc.client_registered_sync name=\(name, privacy: .public)")
  }

  // MARK: - Async API

  public func open() async throws {
    try await self.ensureOpened()
  }

  public func close() async throws {
    guard self.isOpened() else { return }
    try await self.callVoid(skipEnsureOpen: true, skipEnsureRegistered: true) { proxy, reply in
      proxy.smcClose(reply: reply)
    }
    self.markClosed()
  }

  public func getFanCount() async throws -> UInt {
    try await self.ensureOpened()
    return try await self.call { proxy, reply in proxy.smcGetFanCount(reply: reply) }
  }

  public func getFanInfo(_ index: UInt) async throws -> FanInfo {
    try await self.ensureOpened()
    let conn = try self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<FanInfo, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=getFanInfo fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      p.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
        once.tryResume {
          if success {
            continuation.resume(
              returning: FanInfo(
                actualRPM: actual,
                targetRPM: target,
                minRPM: min,
                maxRPM: max,
                manualMode: manual
              ))
          } else {
            continuation.resume(throwing: SMCXPCError(error))
          }
        }
      }
    }
  }

  public func setFanRPM(_ index: UInt, rpm: Float) async throws {
    try await self.setFanRPM(index, rpm: rpm, priority: self.defaultPriority)
  }

  public func setFanRPM(_ index: UInt, rpm: Float, priority: Int) async throws {
    try await self.ensureOpened()
    try await self.ensureRegistered()
    try await self.callArbitrated(opLabel: "setFanRPM[\(index)]") { proxy, reply in
      proxy.smcSetFanRPM(index, rpm: rpm, priority: priority, reply: reply)
    }
  }

  public func setFanAuto(_ index: UInt) async throws {
    try await self.setFanAuto(index, priority: self.defaultPriority)
  }

  public func setFanAuto(_ index: UInt, priority: Int) async throws {
    try await self.ensureOpened()
    try await self.ensureRegistered()
    try await self.callArbitrated(opLabel: "setFanAuto[\(index)]") { proxy, reply in
      proxy.smcSetFanAuto(index, priority: priority, reply: reply)
    }
  }

  public func readKey(_ key: String) async throws -> Float {
    try await self.ensureOpened()
    return try await self.call { proxy, reply in proxy.smcReadKey(key, reply: reply) }
  }

  public func enumerateKeys() async -> [String] {
    do { try await self.ensureOpened() } catch { return [] }
    let conn: NSXPCConnection
    do { conn = try self.ensureConnection() } catch { return [] }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<[String], Never>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=enumerateKeys error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(returning: [])
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume { continuation.resume(returning: []) }
        return
      }
      p.smcEnumerateKeys { keys in
        once.tryResume { continuation.resume(returning: keys) }
      }
    }
  }

  public func registerClient(name: String) async throws {
    let conn = try self.ensureConnection()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume { continuation.resume(throwing: SMCXPCError("Failed to get proxy")) }
        return
      }
      p.smcRegisterClient(name: name) { success, message in
        once.tryResume {
          if success { continuation.resume() }
          else { continuation.resume(throwing: SMCXPCError(message)) }
        }
      }
    }
    self.markRegistered()
  }

  public func getOwnership() async throws -> [OwnershipEntry] {
    try await self.ensureOpened()
    let conn = try self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[OwnershipEntry], Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume { continuation.resume(throwing: SMCXPCError("Failed to get proxy")) }
        return
      }
      p.smcGetOwnership { fans, names, priorities, ages in
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

  // MARK: - Async helpers

  private func call<T: Sendable>(
    _ block: @escaping (
      SMCFanHelperProtocol,
      @escaping @Sendable (Bool, T, String?) -> Void
    ) -> Void
  ) async throws -> T {
    let conn = try self.ensureConnection()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<T, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      block(p) { success, value, error in
        once.tryResume {
          if success { continuation.resume(returning: value) }
          else { continuation.resume(throwing: SMCXPCError(error)) }
        }
      }
    }
  }

  private func callVoid(
    skipEnsureOpen: Bool = false,
    skipEnsureRegistered: Bool = false,
    _ block: @escaping (
      SMCFanHelperProtocol,
      @escaping @Sendable (Bool, String?) -> Void
    ) -> Void
  ) async throws {
    if !skipEnsureOpen {
      try await self.ensureOpened()
    }
    if !skipEnsureRegistered {
      try await self.ensureRegistered()
    }
    let conn = try self.ensureConnection()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      block(p) { success, error in
        once.tryResume {
          if success { continuation.resume() }
          else { continuation.resume(throwing: SMCXPCError(error)) }
        }
      }
    }
  }

  /// Async helper for arbitrated writes. The reply is
  /// `(Bool success, Bool preempted, String? error)`; preempted maps to
  /// `SMCXPCConflictError`.
  private func callArbitrated(
    opLabel: String,
    _ block: @escaping (
      SMCFanHelperProtocol,
      @escaping @Sendable (Bool, Bool, String?) -> Void
    ) -> Void
  ) async throws {
    let conn = try self.ensureConnection()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=\(opLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let p = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      block(p) { success, preempted, error in
        once.tryResume {
          if success {
            continuation.resume()
          } else if preempted {
            continuation.resume(throwing: SMCXPCConflictError(error))
          } else {
            continuation.resume(throwing: SMCXPCError(error))
          }
        }
      }
    }
  }

  // MARK: - Synchronous API (for atexit / signal handlers)

  public func openSync() throws {
    try self.ensureOpenedSync()
  }

  public func closeSync() throws {
    guard self.isOpened() else { return }
    try self.callVoidSync(
      label: "smcClose",
      skipEnsureOpen: true,
      skipEnsureRegistered: true
    ) { proxy, reply in
      proxy.smcClose(reply: reply)
    }
    self.markClosed()
  }

  public func getFanInfoSync(_ index: UInt) throws -> FanInfo {
    try self.ensureOpenedSync()
    let conn = try self.ensureConnection()
    let errBox = SyncErrorBox()
    let infoBox = SyncFanInfoBox()
    let sem = DispatchSemaphore(value: 0)
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        log.error(
          "xpc.proxy_error op=getFanInfoSync fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        errBox.error = SMCXPCError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCError("Failed to get proxy")
    }
    p.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
      once.tryResume {
        if success {
          infoBox.info = FanInfo(
            actualRPM: actual,
            targetRPM: target,
            minRPM: min,
            maxRPM: max,
            manualMode: manual
          )
        } else {
          errBox.error = SMCXPCError(error)
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      log.error(
        "xpc.sync_timeout op=getFanInfoSync fan=\(index, privacy: .public) seconds=\(self.syncTimeout, privacy: .public)"
      )
      throw SMCXPCTimeoutError(label: "getFanInfoSync[\(index)]", seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
    guard let info = infoBox.info else {
      throw SMCXPCError("Missing fan info")
    }
    return info
  }

  public func setFanRPMSync(_ index: UInt, rpm: Float) throws {
    try self.setFanRPMSync(index, rpm: rpm, priority: self.defaultPriority)
  }

  public func setFanRPMSync(_ index: UInt, rpm: Float, priority: Int) throws {
    try self.ensureOpenedSync()
    try self.ensureRegisteredSync()
    try self.callArbitratedSync(label: "setFanRPMSync[\(index)]") { proxy, reply in
      proxy.smcSetFanRPM(index, rpm: rpm, priority: priority, reply: reply)
    }
  }

  public func setFanAutoSync(_ index: UInt) throws {
    try self.setFanAutoSync(index, priority: self.defaultPriority)
  }

  public func setFanAutoSync(_ index: UInt, priority: Int) throws {
    try self.ensureOpenedSync()
    try self.ensureRegisteredSync()
    try self.callArbitratedSync(label: "setFanAutoSync[\(index)]") { proxy, reply in
      proxy.smcSetFanAuto(index, priority: priority, reply: reply)
    }
  }

  private func callVoidSync(
    label: String,
    skipEnsureOpen: Bool = false,
    skipEnsureRegistered: Bool = false,
    _ block: (SMCFanHelperProtocol, @escaping @Sendable (Bool, String?) -> Void) -> Void
  ) throws {
    if !skipEnsureOpen {
      try self.ensureOpenedSync()
    }
    if !skipEnsureRegistered {
      try self.ensureRegisteredSync()
    }
    let conn = try self.ensureConnection()
    let errBox = SyncErrorBox()
    let sem = DispatchSemaphore(value: 0)
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        log.error(
          "xpc.proxy_error op=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        errBox.error = SMCXPCError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCError("Failed to get proxy")
    }
    block(p) { success, error in
      once.tryResume {
        if !success {
          errBox.error = SMCXPCError(error)
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      log.error(
        "xpc.sync_timeout op=\(label, privacy: .public) seconds=\(self.syncTimeout, privacy: .public)"
      )
      throw SMCXPCTimeoutError(label: label, seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
  }

  private func callArbitratedSync(
    label: String,
    _ block: (SMCFanHelperProtocol, @escaping @Sendable (Bool, Bool, String?) -> Void) -> Void
  ) throws {
    let conn = try self.ensureConnection()
    let errBox = SyncErrorBox()
    let sem = DispatchSemaphore(value: 0)
    let once = ResumeGuard()
    let proxy = conn.remoteObjectProxyWithErrorHandler { error in
      once.tryResume {
        log.error(
          "xpc.proxy_error op=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        errBox.error = SMCXPCError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let p = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCError("Failed to get proxy")
    }
    block(p) { success, preempted, error in
      once.tryResume {
        if !success {
          if preempted {
            errBox.error = SMCXPCConflictError(error)
          } else {
            errBox.error = SMCXPCError(error)
          }
        }
        sem.signal()
      }
    }
    if sem.wait(timeout: .now() + self.syncTimeout) == .timedOut {
      log.error(
        "xpc.sync_timeout op=\(label, privacy: .public) seconds=\(self.syncTimeout, privacy: .public)"
      )
      throw SMCXPCTimeoutError(label: label, seconds: self.syncTimeout)
    }
    if let err = errBox.error { throw err }
  }
}
