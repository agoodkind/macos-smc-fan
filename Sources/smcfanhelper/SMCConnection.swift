//
//  SMCConnection.swift
//  SMCFanHelper
//
//  High-level SMC fan control operations.
//
//  Created by Alex Goodkind on 2026-01-18.
//

import Foundation

#if !DIRECT_BUILD
  import SMCCommon
#endif

// MARK: - Fan Control Strategy

enum FanControlStrategy: Sendable {
  case direct
  case ftstUnlock
}

// MARK: - SMCConnection Extensions

extension SMCConnection {

  func enableManualMode(fanIndex: Int) throws -> FanControlStrategy {
    let (ftstBytes, _) = try readKey(SMCFanKey.forceTest)
    let ftstValue = ftstBytes.first ?? 0

    Log.connectionInfo("enableManualMode: fan=\(fanIndex) ftst=\(ftstValue)")

    if ftstValue == 1 {
      Log.connectionInfo("Ftst active, using unlock path for fan \(fanIndex)")
      try unlockFanControlSync(fanIndex: fanIndex)
      Log.connectionNotice("Ftst unlock succeeded for fan \(fanIndex)")
      return .ftstUnlock
    }

    let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: fanIndex)

    do {
      try writeKey(modeKey, bytes: [1])
      Log.connectionInfo("Direct write \(modeKey)=1 succeeded for fan \(fanIndex)")
      return .direct
    } catch {
      Log.connectionInfo("Direct failed, falling back to Ftst for fan \(fanIndex)")
      try unlockFanControlSync(fanIndex: fanIndex)
      Log.connectionNotice("Ftst unlock succeeded for fan \(fanIndex)")
      return .ftstUnlock
    }
  }

  func unlockFanControlSync(
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
  ) throws {
    try writeKey(SMCFanKey.forceTest, bytes: [1])

    Thread.sleep(forTimeInterval: 0.5)

    let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: fanIndex)
    let deadline = Date().addingTimeInterval(timeout)

    for _ in 0..<maxRetries {
      do {
        try writeKey(modeKey, bytes: [1])
        return
      } catch {
        if Date() >= deadline {
          throw SMCError.timeout
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }

    throw SMCError.timeout
  }

  func unlockFanControl(
    fanIndex: Int = 0,
    maxRetries: Int = 100,
    timeout: TimeInterval = 10.0
  ) async throws {
    try writeKey(SMCFanKey.forceTest, bytes: [1])

    try await Task.sleep(for: .milliseconds(500))

    let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: fanIndex)
    let deadline = Date().addingTimeInterval(timeout)

    for _ in 0..<maxRetries {
      do {
        try writeKey(modeKey, bytes: [1])
        return
      } catch {
        if Date() >= deadline {
          throw SMCError.timeout
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    }

    throw SMCError.timeout
  }

  func resetFanControl() throws {
    try writeKey(SMCFanKey.forceTest, bytes: [0])
  }
}
