//
//  SMCFanHelper.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import IOKit

#if !DIRECT_BUILD
  import SMCCommon
#endif

/// XPC service that handles privileged SMC operations
class SMCFanHelper: NSObject, NSXPCListenerDelegate, SMCFanHelperProtocol, @unchecked Sendable {
  private let listener: NSXPCListener
  private var connection: SMCConnection?

  override init() {
    let config = SMCFanConfiguration.default
    listener = NSXPCListener(machServiceName: config.helperBundleID)
    super.init()
    listener.delegate = self
  }

  func start() {
    listener.resume()
    Log.info("Service started")
    RunLoop.current.run()
  }

  // MARK: - NSXPCListenerDelegate

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    newConnection.exportedObject = self
    newConnection.remoteObjectInterface = NSXPCInterface(with: SMCFanClientProtocol.self)

    if let client = newConnection.remoteObjectProxy as? SMCFanClientProtocol {
      Log.setXPCSink(client)
    }

    newConnection.invalidationHandler = {
      Log.setXPCSink(nil)
      Log.notice("Connection invalidated")
    }

    newConnection.interruptionHandler = {
      Log.setXPCSink(nil)
      Log.notice("Connection interrupted")
    }

    newConnection.resume()
    return true
  }

  // MARK: - Connection Management

  private func ensureConnected() throws {
    if connection == nil {
      connection = try SMCConnection()
    }
  }

  // MARK: - SMCFanHelperProtocol

  func smcOpen(reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
      reply(true, nil)
    } catch {
      reply(false, error.localizedDescription)
    }
  }

  func smcClose(reply: @escaping (Bool, String?) -> Void) {
    connection = nil
    reply(true, nil)
  }

  func smcReadKey(_ key: String, reply: @escaping (Bool, Float, String?) -> Void) {
    do {
      try ensureConnected()
      guard let conn = connection else {
        reply(false, 0, "Connection not established")
        return
      }
      let (value, size) = try conn.readKey(key)
      reply(true, SMCDataFormat.float(from: value, size: size), nil)
    } catch {
      reply(false, 0, error.localizedDescription)
    }
  }

  func smcWriteKey(_ key: String, value: Float, reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
      guard let conn = connection else {
        reply(false, "Connection not established")
        return
      }
      let (_, size) = try conn.readKey(key)
      let writeVal = SMCDataFormat.bytes(from: value, size: size)
      try conn.writeKey(key, bytes: writeVal)
      reply(true, nil)
    } catch {
      reply(false, error.localizedDescription)
    }
  }

  func smcGetFanCount(reply: @escaping (Bool, UInt, String?) -> Void) {
    do {
      try ensureConnected()
      guard let conn = connection else {
        reply(false, 0, "Connection not established")
        return
      }
      let (value, _) = try conn.readKey(SMCFanKey.count)
      reply(true, UInt(value[0]), nil)
    } catch {
      reply(false, 0, error.localizedDescription)
    }
  }

  func smcGetFanInfo(
    _ fanIndex: UInt,
    reply: @escaping (Bool, Float, Float, Float, Float, Bool, String?) -> Void
  ) {
    do {
      try ensureConnected()

      let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) ?? 0
      let targetRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.target) ?? 0
      let minRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.minimum) ?? 0
      let maxRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.maximum) ?? 0

      let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: Int(fanIndex))
      let manualMode: Bool
      do {
        guard let conn = connection else {
          throw SMCError.notOpen
        }
        let (modeValue, _) = try conn.readKey(modeKey)
        manualMode = modeValue[0] == 1
      } catch {
        manualMode = false
      }

      reply(true, actualRPM, targetRPM, minRPM, maxRPM, manualMode, nil)
    } catch {
      reply(false, 0, 0, 0, 0, false, error.localizedDescription)
    }
  }

  private func readFloat(fanIndex: UInt, keyFormat: String) -> Float? {
    let key = SMCFanKey.key(keyFormat, fan: Int(fanIndex))
    guard let conn = connection else { return nil }
    do {
      let (value, size) = try conn.readKey(key)
      return SMCDataFormat.float(from: value, size: size)
    } catch {
      return nil
    }
  }

  func smcSetFanRPM(_ fanIndex: UInt, rpm: Float, reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
    } catch {
      reply(false, error.localizedDescription)
      return
    }

    guard let conn = connection else {
      reply(false, "Connection not established")
      return
    }

    let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: Int(fanIndex))
    let alreadyManual: Bool
    do {
      let (modeBytes, _) = try conn.readKey(modeKey)
      alreadyManual = !modeBytes.isEmpty && modeBytes[0] == 1
    } catch {
      alreadyManual = false
    }

    Log.debug("setFanRPM: fan=\(fanIndex) rpm=\(Int(rpm)) alreadyManual=\(alreadyManual)")

    if !alreadyManual {
      do {
        let strategy = try conn.enableManualMode(fanIndex: Int(fanIndex))
        Log.info("enableManualMode: strategy=\(String(describing: strategy)) fan=\(fanIndex)")
      } catch {
        reply(false, error.localizedDescription)
        return
      }
    }

    let key = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
    let value = SMCDataFormat.bytes(from: rpm, size: 4)

    do {
      try conn.writeKey(key, bytes: value)
      Log.info("Set fan \(fanIndex) to \(Int(rpm)) RPM")
      reply(true, nil)

      let capturedFanIndex = fanIndex
      let capturedRPM = rpm
      Task.detached { [weak self] in
        await self?.verifyFanSpeed(
          fanIndex: capturedFanIndex, targetRPM: capturedRPM
        )
      }
    } catch {
      reply(false, error.localizedDescription)
    }
  }

  /// Polls actual RPM until it reaches target (within 10%) or times out
  private func verifyFanSpeed(
    fanIndex: UInt,
    targetRPM: Float,
    timeout: TimeInterval = 30.0,
    interval: TimeInterval = 2.0
  ) async {
    let startTime = Date()
    let tolerance: Float = 0.10

    while Date().timeIntervalSince(startTime) < timeout {
      guard let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) else {
        return
      }

      let diff = abs(actualRPM - targetRPM) / max(targetRPM, 1)
      if diff <= tolerance {
        let elapsed = Date().timeIntervalSince(startTime)
        Log.info(
          "Fan \(fanIndex) reached \(Int(actualRPM)) RPM (target: \(Int(targetRPM))) after \(String(format: "%.1f", elapsed))s"
        )
        return
      }

      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    if let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) {
      Log.warning(
        "Fan \(fanIndex) at \(Int(actualRPM)) RPM after 30s (target was \(Int(targetRPM)))")
    }
  }

  func smcSetFanAuto(_ fanIndex: UInt, reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
    } catch {
      reply(false, error.localizedDescription)
      return
    }

    guard let conn = connection else {
      reply(false, "Connection not established")
      return
    }

    let fanCount: Int
    do {
      let (numBytes, _) = try conn.readKey(SMCFanKey.count)
      fanCount = Int(numBytes[0])
    } catch {
      reply(false, "Failed to read fan count")
      return
    }

    var otherFansManual = 0

    for i in 0..<fanCount {
      if i == Int(fanIndex) { continue }
      let checkKey = SMCFanKey.key(SMCFanKey.mode, fan: i)
      do {
        let (checkBytes, _) = try conn.readKey(checkKey)
        if !checkBytes.isEmpty, checkBytes[0] == 1 {
          otherFansManual += 1
        }
      } catch {
        continue
      }
    }

    let modeKey = SMCFanKey.key(SMCFanKey.mode, fan: Int(fanIndex))
    do {
      try conn.writeKey(modeKey, bytes: [0])
    } catch {
      Log.warning("Failed to set auto mode: \(error)")
    }

    let targetKey = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
    let writeVal = SMCDataFormat.bytes(from: 0, size: 4)
    do {
      try conn.writeKey(targetKey, bytes: writeVal)
    } catch {
      Log.warning("Failed to reset target: \(error)")
    }

    if otherFansManual > 0 {
      Log.info("setFanAuto: fan \(fanIndex) to auto, \(otherFansManual) other fans still manual")
    } else {
      let ftstActive: Bool
      do {
        let (ftstBytes, _) = try conn.readKey(SMCFanKey.forceTest)
        ftstActive = !ftstBytes.isEmpty && ftstBytes[0] == 1
      } catch {
        ftstActive = false
      }

      Log.info("setFanAuto: last fan, ftstActive=\(ftstActive)")

      if ftstActive {
        do {
          try conn.resetFanControl()
          Log.info("Ftst reset succeeded")
        } catch {
          Log.warning("Ftst reset failed: \(error)")
        }
      } else {
        Log.info("All fans auto, direct mode, no Ftst to reset")
      }
    }

    reply(true, nil)
  }
}
