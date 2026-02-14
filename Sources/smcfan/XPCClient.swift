//
//  XPCClient.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCCommon

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

    connection = NSXPCConnection(
      machServiceName: config.helperBundleID,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    connection.exportedInterface = NSXPCInterface(with: SMCFanClientProtocol.self)
    connection.exportedObject = logReceiver
    connection.resume()

    guard
      let p = connection.remoteObjectProxyWithErrorHandler({ error in
        Log.error("XPC connection failed: \(error)")
        exit(1)
      }) as? SMCFanHelperProtocol
    else {
      throw SMCXPCError("Failed to create proxy")
    }

    proxy = p
  }

  deinit {
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
    try await callVoid { self.proxy.smcOpen(reply: $0) }
  }

  func getFanCount() async throws -> UInt {
    try await call { self.proxy.smcGetFanCount(reply: $0) }
  }

  func getFanInfo(_ index: UInt) async throws -> FanInfo {
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

  func setFanRPM(_ index: UInt, rpm: Float) async throws {
    try await callVoid { self.proxy.smcSetFanRPM(index, rpm: rpm, reply: $0) }
  }

  func setFanAuto(_ index: UInt) async throws {
    try await callVoid { self.proxy.smcSetFanAuto(index, reply: $0) }
  }

  func readKey(_ key: String) async throws -> Float {
    try await call { self.proxy.smcReadKey(key, reply: $0) }
  }
}
