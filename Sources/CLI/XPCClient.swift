//
//  XPCClient.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation

/// XPC-related errors
struct SMCXPCError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }

  init(_ message: String?) {
    self.message = message ?? "Unknown error"
  }
}

/// Log receiver for XPC messages from daemon
class XPCLogReceiver: NSObject, SMCFanClientProtocol {
  func logMessage(_ message: String) {
    print("  [helper] \(message)")
  }
}

/// Manages XPC connection to the privileged helper
class XPCClient {
  private let connection: NSXPCConnection
  private let proxy: SMCFanHelperProtocol
  private let logReceiver = XPCLogReceiver()

  init() throws {
    let config = SMCFanConfiguration.default
    Log.debug("connecting to \(config.helperBundleID)")

    connection = NSXPCConnection(
      machServiceName: config.helperBundleID,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    connection.exportedInterface = NSXPCInterface(with: SMCFanClientProtocol.self)
    connection.exportedObject = logReceiver
    connection.resume()
    Log.debug("connection resumed")

    guard
      let p = connection.remoteObjectProxyWithErrorHandler({ error in
        Log.error("XPC connection failed: \(error)")
        exit(1)
      }) as? SMCFanHelperProtocol
    else {
      Log.debug("failed to create remote object proxy")
      throw SMCXPCError("Failed to create proxy")
    }

    proxy = p
    Log.debug("proxy created successfully")
  }

  deinit {
    Log.debug("invalidating connection")
    connection.invalidate()
  }

  // MARK: - Private Helpers

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

  // MARK: - SMC Operations

  func open() async throws {
    Log.debug("calling smcOpen")
    try await callVoid { self.proxy.smcOpen(reply: $0) }
    Log.debug("smcOpen returned OK")
  }

  func getFanCount() async throws -> UInt {
    Log.debug("calling smcGetFanCount")
    let count: UInt = try await call { self.proxy.smcGetFanCount(reply: $0) }
    Log.debug("returned \(count)")
    return count
  }

  func getFanInfo(_ index: UInt) async throws -> FanInfo {
    Log.debug("calling smcGetFanInfo fan=\(index)")
    let info: FanInfo = try await withCheckedThrowingContinuation { continuation in
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
    Log.debug(
      "fan=\(index) actual=\(Int(info.actualRPM)) target=\(Int(info.targetRPM)) manual=\(info.manualMode)"
    )
    return info
  }

  func setFanRPM(_ index: UInt, rpm: Float) async throws {
    Log.debug("calling smcSetFanRPM fan=\(index) rpm=\(Int(rpm))")
    try await callVoid { self.proxy.smcSetFanRPM(index, rpm: rpm, reply: $0) }
    Log.debug("fan=\(index) rpm=\(Int(rpm)) OK")
  }

  func setFanAuto(_ index: UInt) async throws {
    Log.debug("calling smcSetFanAuto fan=\(index)")
    try await callVoid { self.proxy.smcSetFanAuto(index, reply: $0) }
    Log.debug("fan=\(index) OK")
  }

  func readKey(_ key: String) async throws -> Float {
    Log.debug("calling smcReadKey key=\(key)")
    let value: Float = try await call { self.proxy.smcReadKey(key, reply: $0) }
    Log.debug("key=\(key) value=\(value)")
    return value
  }

  func enumerateKeys() async -> [String] {
    Log.debug("calling smcEnumerateKeys")
    let keys = await withCheckedContinuation { continuation in
      proxy.smcEnumerateKeys { keys in
        continuation.resume(returning: keys)
      }
    }
    Log.debug("returned \(keys.count) keys")
    return keys
  }
}
