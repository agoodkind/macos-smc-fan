//
//  SMCFanXPCClient.swift
//  SMCFanXPCClient
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026, all rights reserved.
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

  init() {
    // No stored state to configure; the guard starts un-fired.
  }

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
    let current = fired
    lock.unlock()
    return current
  }
}

// MARK: - IdentityRequestState

private final class IdentityRequestState: @unchecked Sendable {
  private let once = ResumeGuard()
  private let lock = NSLock()
  private var continuation: CheckedContinuation<SMCFanHelperIdentity, Error>?
  private var pendingResult: Result<SMCFanHelperIdentity, Error>?

  func install(_ continuation: CheckedContinuation<SMCFanHelperIdentity, Error>) {
    lock.lock()
    if let pendingResult {
      lock.unlock()
      continuation.resume(with: pendingResult)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func complete(
    with result: Result<SMCFanHelperIdentity, Error>,
    onWinning: () -> Void
  ) {
    once.tryResume {
      onWinning()
      lock.lock()
      let installedContinuation = self.continuation
      self.continuation = nil
      if installedContinuation == nil {
        pendingResult = result
      }
      lock.unlock()
      installedContinuation?.resume(with: result)
    }
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
  public static let defaultIdentityTimeout: TimeInterval = 2.0

  private static let identityOperationLabel = "getHelperIdentity"

  public struct OwnershipEntry: Sendable {
    public let fanIndex: UInt
    public let clientName: String
    public let priority: Int
    /// Seconds since the owner's last write, measured by the helper at
    /// snapshot time.
    public let secondsSinceLastWrite: TimeInterval

    public init(
      fanIndex: UInt, clientName: String, priority: Int, secondsSinceLastWrite: TimeInterval
    ) {
      self.fanIndex = fanIndex
      self.clientName = clientName
      self.priority = priority
      self.secondsSinceLastWrite = secondsSinceLastWrite
    }
  }

  private let helperBundleID: String
  private let syncTimeout: TimeInterval
  private let identityTimeout: TimeInterval
  private let clientName: String?
  private let defaultPriority: Int
  private let connectionFactory: (() -> NSXPCConnection)?
  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var smcOpened = false
  private var registered = false

  public init(
    clientName: String? = nil,
    defaultPriority: Int = SMCFanPriority.curveNormal,
    syncTimeout: TimeInterval = SMCFanXPCClient.defaultSyncTimeout
  ) {
    self.helperBundleID = SMCFanConfiguration.default.helperBundleID
    self.syncTimeout = syncTimeout
    self.identityTimeout = SMCFanXPCClient.defaultIdentityTimeout
    self.clientName = clientName
    self.defaultPriority = defaultPriority
    self.connectionFactory = nil
    log.debug(
      "xpc.client_init bundle_id=\(self.helperBundleID, privacy: .public) client_name=\(clientName ?? "<none>", privacy: .public) default_priority=\(defaultPriority, privacy: .public) sync_timeout=\(self.syncTimeout, privacy: .public) identity_timeout=\(self.identityTimeout, privacy: .public)"
    )
  }

  init(
    identityTimeout: TimeInterval = SMCFanXPCClient.defaultIdentityTimeout,
    connectionFactory: @escaping () -> NSXPCConnection
  ) {
    self.helperBundleID = SMCFanConfiguration.default.helperBundleID
    self.syncTimeout = SMCFanXPCClient.defaultSyncTimeout
    self.identityTimeout = identityTimeout
    self.clientName = nil
    self.defaultPriority = SMCFanPriority.curveNormal
    self.connectionFactory = connectionFactory
    log.debug(
      "xpc.client_init bundle_id=anonymous client_name=<none> default_priority=\(self.defaultPriority, privacy: .public) sync_timeout=\(self.syncTimeout, privacy: .public) identity_timeout=\(self.identityTimeout, privacy: .public)"
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

  private func ensureConnection() -> NSXPCConnection {
    self.lock.lock()
    if let conn = self.connection {
      self.lock.unlock()
      return conn
    }
    let conn: NSXPCConnection
    if let connectionFactory {
      conn = connectionFactory()
    } else {
      conn = NSXPCConnection(
        machServiceName: self.helperBundleID,
        options: .privileged
      )
    }
    conn.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)

    conn.interruptionHandler = { [weak self] in
      log.debug("xpc.connection_interrupted action=reopen_on_next_call")
      guard let self else { return }
      lock.lock()
      smcOpened = false
      registered = false
      lock.unlock()
    }

    conn.invalidationHandler = { [weak self] in
      log.debug("xpc.connection_invalidated action=recreate_on_next_call")
      guard let self else { return }
      lock.lock()
      connection = nil
      smcOpened = false
      registered = false
      lock.unlock()
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
    let current = self.smcOpened
    self.lock.unlock()
    return current
  }

  private func markRegistered() {
    self.lock.lock()
    self.registered = true
    self.lock.unlock()
  }

  private func isRegistered() -> Bool {
    self.lock.lock()
    let current = self.registered
    self.lock.unlock()
    return current
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

  public func getHelperIdentity() async throws -> SMCFanHelperIdentity {
    let requestTimeout = self.identityTimeout
    let requestState = IdentityRequestState()
    log.debug(
      "xpc.helper_identity.request timeout_seconds=\(requestTimeout, privacy: .public)"
    )
    return try await withTaskCancellationHandler {
      try await self.performHelperIdentityRequest(
        requestState: requestState,
        timeout: requestTimeout
      )
    } onCancel: {
      Self.cancelHelperIdentityRequest(requestState)
    }
  }

  private func performHelperIdentityRequest(
    requestState: IdentityRequestState,
    timeout: TimeInterval
  ) async throws -> SMCFanHelperIdentity {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      requestState.install(continuation)
      guard !Task.isCancelled else {
        Self.cancelHelperIdentityRequest(requestState)
        return
      }
      self.scheduleHelperIdentityTimeout(requestState: requestState, timeout: timeout)
      self.sendHelperIdentityRequest(requestState: requestState)
    }
  }

  private func scheduleHelperIdentityTimeout(
    requestState: IdentityRequestState,
    timeout: TimeInterval
  ) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
      let timeoutError = SMCXPCTimeoutError(
        label: Self.identityOperationLabel,
        seconds: timeout
      )
      requestState.complete(with: .failure(timeoutError)) {
        log.error("xpc.helper_identity.timed_out seconds=\(timeout, privacy: .public)")
      }
    }
  }

  private func sendHelperIdentityRequest(requestState: IdentityRequestState) {
    let xpcConnection = self.ensureConnection()
    let proxy = xpcConnection.remoteObjectProxyWithErrorHandler { error in
      requestState.complete(with: .failure(SMCXPCError(error.localizedDescription))) {
        log.error(
          "xpc.helper_identity.proxy_failed error=\(error.localizedDescription, privacy: .public)"
        )
      }
    }
    guard let helper = proxy as? SMCFanHelperProtocol else {
      requestState.complete(with: .failure(SMCXPCError("Failed to get proxy"))) {
        log.error("xpc.helper_identity.proxy_unavailable")
      }
      return
    }
    helper.smcGetIdentity { success, version, build, commit, hash, protocolVersion, error in
      guard success else {
        let requestError = SMCXPCError(error)
        requestState.complete(with: .failure(requestError)) {
          log.error(
            "xpc.helper_identity.rejected error=\(requestError.localizedDescription, privacy: .public)"
          )
        }
        return
      }
      let identity = SMCFanHelperIdentity(
        version: version,
        build: build,
        commit: commit,
        executableHash: hash,
        protocolVersion: protocolVersion
      )
      requestState.complete(with: .success(identity)) {
        log.info(
          "xpc.helper_identity.succeeded version=\(version, privacy: .public) build=\(build, privacy: .public) commit=\(commit, privacy: .public) protocol=\(protocolVersion, privacy: .public)"
        )
      }
    }
  }

  private static func cancelHelperIdentityRequest(_ requestState: IdentityRequestState) {
    requestState.complete(with: .failure(CancellationError())) {
      log.debug("xpc.helper_identity.cancelled")
    }
  }

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
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation { continuation in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=getFanInfo fan=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      typedProxy.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
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

  /// Result of a batched key read. `success` distinguishes a key that
  /// legitimately does not exist on this machine from a read failure;
  /// `error` is empty for successful entries.
  public struct KeyReadResult: Sendable {
    public let key: String
    public let success: Bool
    public let value: Float
    public let error: String

    public init(key: String, success: Bool, value: Float, error: String) {
      self.key = key
      self.success = success
      self.value = value
      self.error = error
    }
  }

  /// Read multiple SMC keys in a single XPC round trip. Returns one
  /// `KeyReadResult` per requested key, in request order.
  public func readKeys(_ keys: [String]) async throws -> [KeyReadResult] {
    try await self.ensureOpened()
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation { continuation in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=readKeys error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      typedProxy.smcReadKeys(keys) { successes, values, errors in
        once.tryResume {
          do {
            let results = try Self.buildKeyReadResults(
              keys: keys, successes: successes, values: values, errors: errors
            )
            continuation.resume(returning: results)
          } catch {
            log.error(
              "xpc.read_keys.length_mismatch error=\(error.localizedDescription, privacy: .public)"
            )
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  /// Pairs each requested key with its reply, in request order. The reply is
  /// positional, and `NSXPCInterface` enforces nothing about cross-array
  /// lengths, so a helper that answers with a short array is a broken
  /// contract, not a request for fewer keys; this throws instead of
  /// truncating so that break is loud rather than silently mistaken for
  /// missing keys.
  static func buildKeyReadResults(
    keys: [String], successes: [Bool], values: [Float], errors: [String]
  ) throws -> [KeyReadResult] {
    guard successes.count == keys.count, values.count == keys.count, errors.count == keys.count
    else {
      let detail =
        "requested=\(keys.count) successes=\(successes.count) "
        + "values=\(values.count) errors=\(errors.count)"
      throw SMCXPCError("Helper returned mismatched array lengths: \(detail)")
    }
    return keys.indices.map { index in
      KeyReadResult(
        key: keys[index],
        success: successes[index],
        value: values[index],
        error: errors[index]
      )
    }
  }

  public func enumerateKeys() async -> [String] {
    do { try await self.ensureOpened() } catch { return [] }
    let conn = self.ensureConnection()
    return await withCheckedContinuation { continuation in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=enumerateKeys error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(returning: [])
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume { continuation.resume(returning: []) }
        return
      }
      typedProxy.smcEnumerateKeys { keys in
        once.tryResume { continuation.resume(returning: keys) }
      }
    }
  }

  public func registerClient(name: String) async throws {
    let conn = self.ensureConnection()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume { continuation.resume(throwing: SMCXPCError("Failed to get proxy")) }
        return
      }
      typedProxy.smcRegisterClient(name: name) { success, message in
        once.tryResume {
          if success {
            continuation.resume()
          } else {
            continuation.resume(throwing: SMCXPCError(message))
          }
        }
      }
    }
    self.markRegistered()
  }

  public func getOwnership() async throws -> [OwnershipEntry] {
    try await self.ensureOpened()
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation { continuation in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume { continuation.resume(throwing: SMCXPCError("Failed to get proxy")) }
        return
      }
      typedProxy.smcGetOwnership { fans, names, priorities, ages in
        once.tryResume {
          let count = min(fans.count, names.count, priorities.count, ages.count)
          let entries: [OwnershipEntry] = (0..<count).map { index in
            OwnershipEntry(
              fanIndex: fans[index],
              clientName: names[index],
              priority: priorities[index],
              secondsSinceLastWrite: ages[index]
            )
          }
          continuation.resume(returning: entries)
        }
      }
    }
  }

  // MARK: - Async helpers

  private func call<T: Sendable>(
    _ block:
      @escaping (
        SMCFanHelperProtocol,
        @escaping @Sendable (Bool, T, String?) -> Void
      ) -> Void
  ) async throws -> T {
    let conn = self.ensureConnection()
    return try await withCheckedThrowingContinuation { continuation in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      block(typedProxy) { success, value, error in
        once.tryResume {
          if success {
            continuation.resume(returning: value)
          } else {
            continuation.resume(throwing: SMCXPCError(error))
          }
        }
      }
    }
  }

  private func callVoid(
    skipEnsureOpen: Bool = false,
    skipEnsureRegistered: Bool = false,
    _ block:
      @escaping (
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
    let conn = self.ensureConnection()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      block(typedProxy) { success, error in
        once.tryResume {
          if success {
            continuation.resume()
          } else {
            continuation.resume(throwing: SMCXPCError(error))
          }
        }
      }
    }
  }

  /// Async helper for arbitrated writes. The reply is
  /// `(Bool success, Bool preempted, String? error)`; preempted maps to
  /// `SMCXPCConflictError`.
  private func callArbitrated(
    opLabel: String,
    _ block:
      @escaping (
        SMCFanHelperProtocol,
        @escaping @Sendable (Bool, Bool, String?) -> Void
      ) -> Void
  ) async throws {
    let conn = self.ensureConnection()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = ResumeGuard()
      let proxy = conn.remoteObjectProxyWithErrorHandler { error in
        once.tryResume {
          log.error(
            "xpc.proxy_error op=\(opLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(throwing: SMCXPCError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCError("Failed to get proxy"))
        }
        return
      }
      block(typedProxy) { success, preempted, error in
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
    let conn = self.ensureConnection()
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
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCError("Failed to get proxy")
    }
    typedProxy.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
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
    let conn = self.ensureConnection()
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
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCError("Failed to get proxy")
    }
    block(typedProxy) { success, error in
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
    let conn = self.ensureConnection()
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
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCError("Failed to get proxy")
    }
    block(typedProxy) { success, preempted, error in
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
