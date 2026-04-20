//
//  SMCFanXPCClient.swift
//  SMCFanXPCClient
//

import AppLog
import Foundation
import SMCFanProtocol

private let log = AppLog.make(category: "SMCFanXPCClient")

private final class SyncErrorBox: @unchecked Sendable {
  var error: Error?
}

private final class SyncFanInfoBox: @unchecked Sendable {
  var info: FanInfo?
}

public struct SMCXPCError: LocalizedError, Sendable {
  public let message: String

  public var errorDescription: String? { message }

  public init(_ message: String?) {
    self.message = message ?? "Unknown error"
  }
}

/// XPC client for the privileged SMC fan helper. Safe for long-running daemons (no `exit` on proxy errors).
public final class SMCFanXPCClient: @unchecked Sendable {
  private let connection: NSXPCConnection
  private let proxy: SMCFanHelperProtocol

  public init() throws {
    let config = SMCFanConfiguration.default
    log.debug("xpc.connect bundleID=\(config.helperBundleID, privacy: .public)")

    connection = NSXPCConnection(
      machServiceName: config.helperBundleID,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    connection.resume()

    guard
      let p = connection.remoteObjectProxyWithErrorHandler({ error in
        log.error("xpc.proxy.failed error=\(error.localizedDescription, privacy: .public)")
      }) as? SMCFanHelperProtocol
    else {
      throw SMCXPCError("Failed to create XPC proxy")
    }

    proxy = p
    log.debug("xpc.connected bundleID=\(config.helperBundleID, privacy: .public)")
  }

  deinit {
    connection.invalidate()
  }

  // MARK: - Private async helpers

  private func call<T: Sendable>(
    _ block: @escaping (@escaping @Sendable (Bool, T, String?) -> Void) -> Void
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      block { success, value, error in
        if success {
          continuation.resume(returning: value)
        } else {
          continuation.resume(throwing: SMCXPCError(error))
        }
      }
    }
  }

  private func callVoid(
    _ block: @escaping (@escaping @Sendable (Bool, String?) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      block { success, error in
        if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: SMCXPCError(error))
        }
      }
    }
  }

  // MARK: - Async API

  public func open() async throws {
    try await callVoid { self.proxy.smcOpen(reply: $0) }
  }

  public func close() async throws {
    try await callVoid { self.proxy.smcClose(reply: $0) }
  }

  public func getFanCount() async throws -> UInt {
    try await call { self.proxy.smcGetFanCount(reply: $0) }
  }

  public func getFanInfo(_ index: UInt) async throws -> FanInfo {
    try await withCheckedThrowingContinuation { continuation in
      self.proxy.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
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

  public func setFanRPM(_ index: UInt, rpm: Float) async throws {
    try await callVoid { self.proxy.smcSetFanRPM(index, rpm: rpm, reply: $0) }
  }

  public func setFanAuto(_ index: UInt) async throws {
    try await callVoid { self.proxy.smcSetFanAuto(index, reply: $0) }
  }

  public func readKey(_ key: String) async throws -> Float {
    try await call { self.proxy.smcReadKey(key, reply: $0) }
  }

  public func enumerateKeys() async -> [String] {
    await withCheckedContinuation { continuation in
      proxy.smcEnumerateKeys { keys in
        continuation.resume(returning: keys)
      }
    }
  }

  // MARK: - Synchronous API (atexit / signal handlers)

  public func openSync() throws {
    let box = SyncErrorBox()
    let sem = DispatchSemaphore(value: 0)
    proxy.smcOpen { success, err in
      if !success {
        box.error = SMCXPCError(err)
      }
      sem.signal()
    }
    sem.wait()
    if let err = box.error {
      throw err
    }
  }

  public func closeSync() throws {
    let box = SyncErrorBox()
    let sem = DispatchSemaphore(value: 0)
    proxy.smcClose { success, err in
      if !success {
        box.error = SMCXPCError(err)
      }
      sem.signal()
    }
    sem.wait()
    if let err = box.error {
      throw err
    }
  }

  public func getFanInfoSync(_ index: UInt) throws -> FanInfo {
    let errBox = SyncErrorBox()
    let infoBox = SyncFanInfoBox()
    let sem = DispatchSemaphore(value: 0)
    proxy.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
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
    sem.wait()
    if let err = errBox.error {
      throw err
    }
    guard let info = infoBox.info else {
      throw SMCXPCError("Missing fan info")
    }
    return info
  }

  public func setFanRPMSync(_ index: UInt, rpm: Float) throws {
    let box = SyncErrorBox()
    let sem = DispatchSemaphore(value: 0)
    proxy.smcSetFanRPM(index, rpm: rpm) { success, err in
      if !success {
        box.error = SMCXPCError(err)
      }
      sem.signal()
    }
    sem.wait()
    if let err = box.error {
      throw err
    }
  }

  public func setFanAutoSync(_ index: UInt) throws {
    let box = SyncErrorBox()
    let sem = DispatchSemaphore(value: 0)
    proxy.smcSetFanAuto(index) { success, err in
      if !success {
        box.error = SMCXPCError(err)
      }
      sem.signal()
    }
    sem.wait()
    if let err = box.error {
      throw err
    }
  }
}
