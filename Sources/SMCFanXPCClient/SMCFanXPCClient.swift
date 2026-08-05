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

// MARK: - SMCXPCTransportError

public struct SMCXPCTransportError: LocalizedError, Sendable {
  public let message: String

  public var errorDescription: String? { message }

  public init(_ message: String?) {
    self.message = message ?? "Unknown XPC transport error"
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

}

// MARK: - AsyncRequestState

private final class AsyncRequestState<Value: Sendable>: @unchecked Sendable {
  private let once = ResumeGuard()
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var pendingResult: Result<Value, Error>?

  func install(_ continuation: CheckedContinuation<Value, Error>) {
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
    with result: Result<Value, Error>,
    onWinning: () -> Void
  ) {
    once.tryResume {
      onWinning()
      self.resume(with: result)
    }
  }

  func complete(with result: Result<Value, Error>) {
    once.tryResume {
      self.resume(with: result)
    }
  }

  private func resume(with result: Result<Value, Error>) {
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

// MARK: - RequestScopeState

final class RequestScopeState: @unchecked Sendable {
  enum CancellationResult {
    case alreadyCancelled
    case cancelled(NSXPCConnection?)
    case foreignOwner
  }

  let identifier: UInt64

  private let lock = NSLock()
  private let owner: ObjectIdentifier
  private var connection: NSXPCConnection?
  private var opened = false
  private var registered = false
  private var cancelled = false

  init(identifier: UInt64, owner: ObjectIdentifier, connection: NSXPCConnection) {
    self.identifier = identifier
    self.owner = owner
    self.connection = connection
  }

  init(cancelledIdentifier identifier: UInt64, owner: ObjectIdentifier) {
    self.identifier = identifier
    self.owner = owner
    self.connection = nil
    self.cancelled = true
  }

  deinit {
    lock.lock()
    let ownedConnection = self.connection
    self.connection = nil
    lock.unlock()
    ownedConnection?.invalidate()
  }

  var isCancelled: Bool {
    lock.lock()
    let current = cancelled
    lock.unlock()
    return current
  }

  func cancel(owner expectedOwner: ObjectIdentifier) -> CancellationResult {
    lock.lock()
    guard owner == expectedOwner else {
      lock.unlock()
      return .foreignOwner
    }
    guard !cancelled else {
      lock.unlock()
      return .alreadyCancelled
    }
    cancelled = true
    let cancelledConnection = self.connection
    self.connection = nil
    opened = false
    registered = false
    lock.unlock()
    return .cancelled(cancelledConnection)
  }

  func isOpened(owner expectedOwner: ObjectIdentifier) throws -> Bool {
    try withActiveScope(owner: expectedOwner) { opened }
  }

  func markOpened(owner expectedOwner: ObjectIdentifier) throws {
    try withActiveScope(owner: expectedOwner) { opened = true }
  }

  func isRegistered(owner expectedOwner: ObjectIdentifier) throws -> Bool {
    try withActiveScope(owner: expectedOwner) { registered }
  }

  func markRegistered(owner expectedOwner: ObjectIdentifier) throws {
    try withActiveScope(owner: expectedOwner) { registered = true }
  }

  func claimConnection(owner expectedOwner: ObjectIdentifier) throws -> NSXPCConnection {
    try withActiveScope(owner: expectedOwner) {
      guard let connection else {
        throw CancellationError()
      }
      return connection
    }
  }

  func connectionInterrupted(_ interruptedConnection: NSXPCConnection) {
    lock.lock()
    if connection === interruptedConnection {
      opened = false
      registered = false
    }
    lock.unlock()
  }

  func connectionInvalidated(_ invalidatedConnection: NSXPCConnection) {
    lock.lock()
    if connection === invalidatedConnection {
      connection = nil
      opened = false
      registered = false
      cancelled = true
    }
    lock.unlock()
  }

  private func withActiveScope<Value>(
    owner expectedOwner: ObjectIdentifier,
    _ operation: () throws -> Value
  ) throws -> Value {
    lock.lock()
    defer { lock.unlock() }
    guard owner == expectedOwner, !cancelled else {
      throw CancellationError()
    }
    return try operation()
  }
}

// MARK: - WeakRequestScopeState

private struct WeakRequestScopeState {
  weak var state: RequestScopeState?
}

// MARK: - SMCFanXPCRequestScope

public struct SMCFanXPCRequestScope: Sendable {
  let state: RequestScopeState
}

// MARK: - Client

/// XPC client for the privileged SMC fan helper.
///
/// Safe for long running daemons. Unscoped calls share one NSXPCConnection.
/// Each request scope eagerly owns one isolated connection and becomes terminal
/// after cancellation or invalidation. The shared unscoped connection is
/// recreated lazily after invalidation. Every call uses a fresh per call proxy
/// via `remoteObjectProxyWithErrorHandler`. A
/// `ResumeGuard` ensures the continuation or semaphore receives exactly one
/// signal, whether the reply or error handler fires first.
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
  private let connectionFactory: () -> NSXPCConnection
  private let remoteProxyFactory:
    ((NSXPCConnection, @escaping @Sendable (Error) -> Void) -> SMCFanHelperProtocol)?
  private let beforeConnectionClaim: (@Sendable () async -> Void)?
  private let beforeRequestScopeRegistration: (@Sendable () -> Void)?
  private let afterScopedRequestCompletion: (@Sendable () async -> Void)?
  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var nextRequestScopeIdentifier: UInt64 = 0
  private var requestScopeStates: [WeakRequestScopeState] = []
  private var requestScopesShutDown = false
  private var smcOpened = false
  private var registered = false

  public convenience init(
    clientName: String? = nil,
    defaultPriority: Int = SMCFanPriority.curveNormal,
    syncTimeout: TimeInterval = SMCFanXPCClient.defaultSyncTimeout
  ) {
    let configuredHelperBundleID = SMCFanConfiguration.default.helperBundleID
    self.init(
      clientName: clientName,
      defaultPriority: defaultPriority,
      syncTimeout: syncTimeout,
      identityTimeout: SMCFanXPCClient.defaultIdentityTimeout,
      connectionLogLabel: configuredHelperBundleID
    ) {
      NSXPCConnection(machServiceName: configuredHelperBundleID, options: .privileged)
    }
  }

  init(
    clientName: String? = nil,
    defaultPriority: Int = SMCFanPriority.curveNormal,
    syncTimeout: TimeInterval = SMCFanXPCClient.defaultSyncTimeout,
    identityTimeout: TimeInterval = SMCFanXPCClient.defaultIdentityTimeout,
    beforeConnectionClaim: (@Sendable () async -> Void)? = nil,
    beforeRequestScopeRegistration: (@Sendable () -> Void)? = nil,
    afterScopedRequestCompletion: (@Sendable () async -> Void)? = nil,
    connectionLogLabel: String = "anonymous",
    remoteProxyFactory:
      ((NSXPCConnection, @escaping @Sendable (Error) -> Void) -> SMCFanHelperProtocol)? = nil,
    connectionFactory: @escaping () -> NSXPCConnection
  ) {
    self.helperBundleID = SMCFanConfiguration.default.helperBundleID
    self.syncTimeout = syncTimeout
    self.identityTimeout = identityTimeout
    self.clientName = clientName
    self.defaultPriority = defaultPriority
    self.connectionFactory = connectionFactory
    self.remoteProxyFactory = remoteProxyFactory
    self.beforeConnectionClaim = beforeConnectionClaim
    self.beforeRequestScopeRegistration = beforeRequestScopeRegistration
    self.afterScopedRequestCompletion = afterScopedRequestCompletion
    log.debug(
      "xpc.client_init bundle_id=\(connectionLogLabel, privacy: .public) client_name=\(clientName ?? "<none>", privacy: .public) default_priority=\(self.defaultPriority, privacy: .public) sync_timeout=\(self.syncTimeout, privacy: .public) identity_timeout=\(self.identityTimeout, privacy: .public)"
    )
  }

  deinit {
    for activeConnection in self.takeConnectionsForShutdown() {
      activeConnection.invalidate()
    }
  }

  /// Explicit teardown for callers that need to release connections before
  /// process exit. Safe to call more than once. Request scopes created after
  /// shutdown are terminal and do not create connections.
  public func shutdown() {
    let connections = self.takeConnectionsForShutdown()
    for activeConnection in connections {
      activeConnection.invalidate()
    }
    log.debug("xpc.client_shutdown connections=\(connections.count, privacy: .public)")
  }

  private func takeConnectionsForShutdown() -> [NSXPCConnection] {
    self.lock.lock()
    self.requestScopesShutDown = true
    let unscopedConnection = self.connection
    self.connection = nil
    self.smcOpened = false
    self.registered = false
    let scopeStates = self.requestScopeStates.compactMap(\.state)
    self.requestScopeStates.removeAll()
    self.lock.unlock()

    var connections = scopeStates.compactMap { state -> NSXPCConnection? in
      guard case .cancelled(let connection) = state.cancel(owner: ObjectIdentifier(self)) else {
        return nil
      }
      return connection
    }
    if let unscopedConnection {
      connections.append(unscopedConnection)
    }
    return connections
  }

  public func makeRequestScope() -> SMCFanXPCRequestScope {
    self.lock.lock()
    let identifier = self.nextRequestScopeIdentifier
    self.nextRequestScopeIdentifier &+= 1
    let scopesAlreadyShutDown = self.requestScopesShutDown
    self.lock.unlock()

    if scopesAlreadyShutDown {
      let state = RequestScopeState(
        cancelledIdentifier: identifier,
        owner: ObjectIdentifier(self)
      )
      log.debug(
        "xpc.request_scope.creation_cancelled scope_id=\(identifier, privacy: .public) reason=client_shutdown action=return_cancelled_scope"
      )
      return SMCFanXPCRequestScope(state: state)
    }

    let scopedConnection = self.makeConnection()
    scopedConnection.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    let state = RequestScopeState(
      identifier: identifier,
      owner: ObjectIdentifier(self),
      connection: scopedConnection
    )
    scopedConnection.interruptionHandler = { [weak state, weak scopedConnection] in
      log.debug("xpc.scoped_connection_interrupted action=reopen_existing_connection")
      guard let scopedConnection else { return }
      state?.connectionInterrupted(scopedConnection)
    }
    scopedConnection.invalidationHandler = { [weak state, weak scopedConnection] in
      log.debug("xpc.scoped_connection_invalidated action=cancel_scope")
      guard let scopedConnection else { return }
      state?.connectionInvalidated(scopedConnection)
    }
    self.beforeRequestScopeRegistration?()

    self.lock.lock()
    if self.requestScopesShutDown {
      self.lock.unlock()
      if case .cancelled(let connection) = state.cancel(owner: ObjectIdentifier(self)) {
        connection?.invalidate()
      }
      log.debug(
        "xpc.request_scope.creation_cancelled scope_id=\(identifier, privacy: .public) reason=concurrent_client_shutdown action=invalidate_scoped_connection"
      )
      return SMCFanXPCRequestScope(state: state)
    }
    self.requestScopeStates.removeAll { $0.state == nil }
    self.requestScopeStates.append(WeakRequestScopeState(state: state))
    scopedConnection.resume()
    self.lock.unlock()
    let scope = SMCFanXPCRequestScope(state: state)
    log.debug(
      "xpc.request_scope.created scope_id=\(identifier, privacy: .public) action=create_scoped_connection"
    )
    return scope
  }

  public func cancelRequests(in scope: SMCFanXPCRequestScope) {
    switch scope.state.cancel(owner: ObjectIdentifier(self)) {
    case .foreignOwner:
      log.error("xpc.request_scope.cancel_ignored reason=foreign_owner")
    case .alreadyCancelled:
      log.debug(
        "xpc.request_scope.cancel_ignored reason=already_cancelled scope_id=\(scope.state.identifier, privacy: .public)"
      )
    case .cancelled(let connection):
      connection?.invalidate()
      log.debug(
        "xpc.request_scope.cancelled scope_id=\(scope.state.identifier, privacy: .public) action=invalidate_scoped_connection"
      )
    }
  }

  // MARK: - Connection management

  private func ensureConnection() -> NSXPCConnection {
    self.lock.lock()
    let (conn, created) = self.ensureConnectionLocked()
    self.lock.unlock()
    if created {
      log.debug(
        "xpc.connection_created bundle_id=\(self.helperBundleID, privacy: .public)"
      )
    }
    return conn
  }

  private func ensureConnectionLocked() -> (connection: NSXPCConnection, created: Bool) {
    if let conn = self.connection {
      return (conn, false)
    }
    let conn = self.makeConnection()
    conn.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)

    conn.interruptionHandler = { [weak self] in
      log.debug("xpc.connection_interrupted action=reopen_on_next_call")
      guard let self else { return }
      lock.lock()
      if connection === conn {
        smcOpened = false
        registered = false
      }
      lock.unlock()
    }

    conn.invalidationHandler = { [weak self] in
      log.debug("xpc.connection_invalidated action=recreate_on_next_call")
      guard let self else { return }
      lock.lock()
      if connection === conn {
        connection = nil
        smcOpened = false
        registered = false
      }
      lock.unlock()
    }

    conn.resume()
    self.connection = conn
    return (conn, true)
  }

  private func makeConnection() -> NSXPCConnection {
    self.connectionFactory()
  }

  private func isOpened(scope: SMCFanXPCRequestScope) throws -> Bool {
    try scope.state.isOpened(owner: ObjectIdentifier(self))
  }

  private func markOpened(scope: SMCFanXPCRequestScope) throws {
    try scope.state.markOpened(owner: ObjectIdentifier(self))
  }

  private func isRegistered(scope: SMCFanXPCRequestScope) throws -> Bool {
    try scope.state.isRegistered(owner: ObjectIdentifier(self))
  }

  private func markRegistered(scope: SMCFanXPCRequestScope) throws {
    try scope.state.markRegistered(owner: ObjectIdentifier(self))
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

  private func ensureOpened(scope: SMCFanXPCRequestScope) async throws {
    if try self.isOpened(scope: scope) { return }
    try await self.callVoid(
      scope: scope,
      opLabel: "smcOpen",
      skipEnsureOpen: true,
      skipEnsureRegistered: true
    ) { proxy, reply in
      proxy.smcOpen(reply: reply)
    }
    try self.markOpened(scope: scope)
    log.debug(
      "xpc.smc_opened scope_id=\(scope.state.identifier, privacy: .public)"
    )
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

  private func ensureRegistered(scope: SMCFanXPCRequestScope) async throws {
    guard let name = self.clientName else { return }
    if try self.isRegistered(scope: scope) { return }
    try await self.callVoid(
      scope: scope,
      opLabel: "smcRegisterClient",
      skipEnsureOpen: true,
      skipEnsureRegistered: true
    ) { proxy, reply in
      proxy.smcRegisterClient(name: name, reply: reply)
    }
    try self.markRegistered(scope: scope)
    log.debug(
      "xpc.client_registered name=\(name, privacy: .public) scope_id=\(scope.state.identifier, privacy: .public)"
    )
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
    let requestState = AsyncRequestState<SMCFanHelperIdentity>()
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
    requestState: AsyncRequestState<SMCFanHelperIdentity>,
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
    requestState: AsyncRequestState<SMCFanHelperIdentity>,
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

  private func sendHelperIdentityRequest(
    requestState: AsyncRequestState<SMCFanHelperIdentity>
  ) {
    let xpcConnection = self.ensureConnection()
    let proxy = xpcConnection.remoteObjectProxyWithErrorHandler { error in
      requestState.complete(with: .failure(SMCXPCTransportError(error.localizedDescription))) {
        log.error(
          "xpc.helper_identity.proxy_failed error=\(error.localizedDescription, privacy: .public)"
        )
      }
    }
    guard let helper = proxy as? SMCFanHelperProtocol else {
      requestState.complete(with: .failure(SMCXPCTransportError("Failed to get proxy"))) {
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

  private static func cancelHelperIdentityRequest(
    _ requestState: AsyncRequestState<SMCFanHelperIdentity>
  ) {
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

  public func getFanCount(scope: SMCFanXPCRequestScope) async throws -> UInt {
    try await self.ensureOpened(scope: scope)
    return try await self.call(scope: scope, opLabel: "getFanCount") { proxy, reply in
      proxy.smcGetFanCount(reply: reply)
    }
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
          continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCTransportError("Failed to get proxy"))
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

  public func setFanAuto(_ index: UInt, scope: SMCFanXPCRequestScope) async throws {
    try await self.setFanAuto(index, priority: self.defaultPriority, scope: scope)
  }

  public func setFanAuto(
    _ index: UInt,
    priority: Int,
    scope: SMCFanXPCRequestScope
  ) async throws {
    try await self.ensureOpened(scope: scope)
    try await self.ensureRegistered(scope: scope)
    try await self.callArbitrated(
      scope: scope,
      opLabel: "setFanAuto[\(index)]"
    ) { proxy, reply in
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
          continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCTransportError("Failed to get proxy"))
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
          continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCTransportError("Failed to get proxy"))
        }
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
          continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
        }
      }
      guard let typedProxy = proxy as? SMCFanHelperProtocol else {
        once.tryResume {
          continuation.resume(throwing: SMCXPCTransportError("Failed to get proxy"))
        }
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

  private func waitBeforeConnectionClaim() async {
    if let beforeConnectionClaim {
      await beforeConnectionClaim()
    }
  }

  private func dispatchScopedAfterClaim(
    scope: SMCFanXPCRequestScope,
    opLabel: String,
    errorHandler: @escaping @Sendable (Error) -> Void,
    dispatch: (SMCFanHelperProtocol) -> Void
  ) throws {
    do {
      let scopedConnection = try scope.state.claimConnection(owner: ObjectIdentifier(self))
      try self.dispatch(
        on: scopedConnection,
        errorHandler: errorHandler,
        dispatch: dispatch
      )
    } catch {
      if error is CancellationError {
        log.debug(
          "xpc.request_scope.dispatch_cancelled op=\(opLabel, privacy: .public) scope_id=\(scope.state.identifier, privacy: .public)"
        )
      }
      throw error
    }
  }

  private func dispatch(
    on connection: NSXPCConnection,
    errorHandler: @escaping @Sendable (Error) -> Void,
    dispatch: (SMCFanHelperProtocol) -> Void
  ) throws {
    if let proxyFactory = remoteProxyFactory {
      dispatch(proxyFactory(connection, errorHandler))
      return
    }
    let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCTransportError("Failed to get proxy")
    }
    dispatch(typedProxy)
  }

  private func performScopedRequest<Value: Sendable>(
    scope: SMCFanXPCRequestScope,
    opLabel: String,
    dispatchRequest: @escaping @Sendable (AsyncRequestState<Value>) -> Void
  ) async throws -> Value {
    let requestState = AsyncRequestState<Value>()
    let requestTimeout = self.syncTimeout
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      await self.waitBeforeConnectionClaim()
      try Task.checkCancellation()
      do {
        let value = try await withCheckedThrowingContinuation { continuation in
          requestState.install(continuation)
          guard !Task.isCancelled else {
            self.cancelScopedRequest(requestState, scope: scope, opLabel: opLabel)
            return
          }
          self.scheduleScopedRequestTimeout(
            requestState,
            scope: scope,
            opLabel: opLabel,
            timeout: requestTimeout
          )
          dispatchRequest(requestState)
        }
        await self.waitAfterScopedRequestCompletion()
        return value
      } catch {
        await self.waitAfterScopedRequestCompletion()
        throw error
      }
    } onCancel: {
      self.cancelScopedRequest(requestState, scope: scope, opLabel: opLabel)
    }
  }

  private func waitAfterScopedRequestCompletion() async {
    if let afterScopedRequestCompletion = self.afterScopedRequestCompletion {
      await afterScopedRequestCompletion()
    }
  }

  private func scheduleScopedRequestTimeout<Value: Sendable>(
    _ requestState: AsyncRequestState<Value>,
    scope: SMCFanXPCRequestScope,
    opLabel: String,
    timeout: TimeInterval
  ) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
      let timeoutError = SMCXPCTimeoutError(label: opLabel, seconds: timeout)
      requestState.complete(with: .failure(timeoutError)) {
        log.error(
          "xpc.request_scope.timed_out op=\(opLabel, privacy: .public) scope_id=\(scope.state.identifier, privacy: .public) seconds=\(timeout, privacy: .public)"
        )
        self.cancelRequests(in: scope)
      }
    }
  }

  private func cancelScopedRequest<Value: Sendable>(
    _ requestState: AsyncRequestState<Value>,
    scope: SMCFanXPCRequestScope,
    opLabel: String
  ) {
    requestState.complete(with: .failure(CancellationError())) {
      log.debug(
        "xpc.request_scope.task_cancelled op=\(opLabel, privacy: .public) scope_id=\(scope.state.identifier, privacy: .public)"
      )
      self.cancelRequests(in: scope)
    }
  }

  private func call<T: Sendable>(
    scope: SMCFanXPCRequestScope,
    opLabel: String,
    _ block:
      @escaping @Sendable (
        SMCFanHelperProtocol,
        @escaping @Sendable (Bool, T, String?) -> Void
      ) -> Void
  ) async throws -> T {
    try await self.performScopedRequest(scope: scope, opLabel: opLabel) { requestState in
      do {
        try self.dispatchScopedAfterClaim(
          scope: scope,
          opLabel: opLabel,
          errorHandler: { error in
            requestState.complete(
              with: .failure(self.scopedProxyError(error, scope: scope))
            ) {
              if scope.state.isCancelled {
                log.debug(
                  "xpc.request_scope.proxy_cancelled op=\(opLabel, privacy: .public) scope_id=\(scope.state.identifier, privacy: .public)"
                )
              }
            }
          },
          dispatch: { proxy in
            block(proxy) { success, value, error in
              if scope.state.isCancelled {
                requestState.complete(with: .failure(CancellationError()))
              } else if success {
                requestState.complete(with: .success(value))
              } else {
                requestState.complete(with: .failure(SMCXPCError(error)))
              }
            }
          })
      } catch {
        log.error(
          "xpc.request_scope.call_failed op=\(opLabel, privacy: .public) reason=\(String(describing: error), privacy: .private) action=resume_error"
        )
        requestState.complete(with: .failure(error))
      }
    }
  }

  private func scopedProxyError(_ error: Error, scope: SMCFanXPCRequestScope) -> Error {
    if scope.state.isCancelled {
      return CancellationError()
    }
    return SMCXPCTransportError(error.localizedDescription)
  }

  private func scopedReplyError(_ error: String?, scope: SMCFanXPCRequestScope) -> Error {
    if scope.state.isCancelled {
      return CancellationError()
    }
    return SMCXPCError(error)
  }

  private func callVoid(
    scope: SMCFanXPCRequestScope,
    opLabel: String,
    skipEnsureOpen: Bool = false,
    skipEnsureRegistered: Bool = false,
    _ block:
      @escaping @Sendable (
        SMCFanHelperProtocol,
        @escaping @Sendable (Bool, String?) -> Void
      ) -> Void
  ) async throws {
    if !skipEnsureOpen {
      try await self.ensureOpened(scope: scope)
    }
    if !skipEnsureRegistered {
      try await self.ensureRegistered(scope: scope)
    }
    let _: Void = try await self.performScopedRequest(
      scope: scope,
      opLabel: opLabel
    ) { requestState in
      do {
        try self.dispatchScopedAfterClaim(
          scope: scope,
          opLabel: opLabel,
          errorHandler: { error in
            requestState.complete(
              with: .failure(self.scopedProxyError(error, scope: scope))
            )
          },
          dispatch: { proxy in
            block(proxy) { success, error in
              if success, !scope.state.isCancelled {
                requestState.complete(with: .success(()))
              } else {
                requestState.complete(
                  with: .failure(self.scopedReplyError(error, scope: scope))
                )
              }
            }
          })
      } catch {
        log.error(
          "xpc.request_scope.call_failed op=\(opLabel, privacy: .public) reason=\(String(describing: error), privacy: .private) action=resume_error"
        )
        requestState.complete(with: .failure(error))
      }
    }
  }

  private func callArbitrated(
    scope: SMCFanXPCRequestScope,
    opLabel: String,
    _ block:
      @escaping @Sendable (
        SMCFanHelperProtocol,
        @escaping @Sendable (Bool, Bool, String?) -> Void
      ) -> Void
  ) async throws {
    let _: Void = try await self.performScopedRequest(
      scope: scope,
      opLabel: opLabel
    ) { requestState in
      do {
        try self.dispatchScopedAfterClaim(
          scope: scope,
          opLabel: opLabel,
          errorHandler: { error in
            requestState.complete(
              with: .failure(self.scopedProxyError(error, scope: scope))
            )
          },
          dispatch: { proxy in
            block(proxy) { success, preempted, error in
              if scope.state.isCancelled {
                requestState.complete(with: .failure(CancellationError()))
              } else if success {
                requestState.complete(with: .success(()))
              } else if preempted {
                requestState.complete(with: .failure(SMCXPCConflictError(error)))
              } else {
                requestState.complete(with: .failure(SMCXPCError(error)))
              }
            }
          })
      } catch {
        log.error(
          "xpc.request_scope.call_failed op=\(opLabel, privacy: .public) reason=\(String(describing: error), privacy: .private) action=resume_error"
        )
        requestState.complete(with: .failure(error))
      }
    }
  }

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
      do {
        try self.dispatch(
          on: conn,
          errorHandler: { error in
            once.tryResume {
              log.error(
                "xpc.proxy_error error=\(error.localizedDescription, privacy: .public)"
              )
              continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
            }
          },
          dispatch: { proxy in
            block(proxy) { success, value, error in
              once.tryResume {
                if success {
                  continuation.resume(returning: value)
                } else {
                  continuation.resume(throwing: SMCXPCError(error))
                }
              }
            }
          })
      } catch {
        log.error(
          "xpc.call_failed reason=\(String(describing: error), privacy: .private) action=resume_error"
        )
        once.tryResume {
          continuation.resume(throwing: error)
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
      do {
        try self.dispatch(
          on: conn,
          errorHandler: { error in
            once.tryResume {
              log.error(
                "xpc.proxy_error error=\(error.localizedDescription, privacy: .public)"
              )
              continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
            }
          },
          dispatch: { proxy in
            block(proxy) { success, error in
              once.tryResume {
                if success {
                  continuation.resume()
                } else {
                  continuation.resume(throwing: SMCXPCError(error))
                }
              }
            }
          })
      } catch {
        log.error(
          "xpc.call_failed op=void reason=\(String(describing: error), privacy: .private) action=resume_error"
        )
        once.tryResume {
          continuation.resume(throwing: error)
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
      do {
        try self.dispatch(
          on: conn,
          errorHandler: { error in
            once.tryResume {
              log.error(
                "xpc.proxy_error op=\(opLabel, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
              )
              continuation.resume(throwing: SMCXPCTransportError(error.localizedDescription))
            }
          },
          dispatch: { proxy in
            block(proxy) { success, preempted, error in
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
          })
      } catch {
        log.error(
          "xpc.call_failed op=\(opLabel, privacy: .public) reason=\(String(describing: error), privacy: .private) action=resume_error"
        )
        once.tryResume {
          continuation.resume(throwing: error)
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
        errBox.error = SMCXPCTransportError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCTransportError("Failed to get proxy")
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
        errBox.error = SMCXPCTransportError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCTransportError("Failed to get proxy")
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
        errBox.error = SMCXPCTransportError(error.localizedDescription)
        sem.signal()
      }
    }
    guard let typedProxy = proxy as? SMCFanHelperProtocol else {
      throw SMCXPCTransportError("Failed to get proxy")
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
