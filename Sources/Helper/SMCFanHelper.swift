//
//  SMCFanHelper.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import IOKit
import SMCKit
import SMCFanKit

import Logging

private let ultraDebug = ProcessInfo.processInfo.environment["SMCFAN_ULTRA_DEBUG"] != nil

private let tempKeys = [
  "Ts0P", "Ts1P",  // M5 Max
  "Tp09", "Tp0T",  // Apple Silicon (some models)
  "TC0P", "TC0p",  // Intel
  "Tg0f", "Tw0P",  // GPU, wireless
]

class SMCFanHelper: NSObject, NSXPCListenerDelegate, SMCFanHelperProtocol, @unchecked Sendable {
  private let listener: NSXPCListener
  private var fanController: FanController?

  override init() {
    let config = SMCFanConfiguration.default
    listener = NSXPCListener(machServiceName: config.helperBundleID)
    super.init()
    listener.delegate = self
  }

  func start() {
    listener.resume()
    Log.info("Helper daemon started, listening for XPC connections")
    RunLoop.current.run()
  }

  // MARK: - NSXPCListenerDelegate

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    Log.debug("XPC connection from pid=\(newConnection.processIdentifier) euid=\(newConnection.effectiveUserIdentifier)")
    newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    newConnection.exportedObject = self
    newConnection.remoteObjectInterface = NSXPCInterface(with: SMCFanClientProtocol.self)

    if let client = newConnection.remoteObjectProxy as? SMCFanClientProtocol {
      Log.setXPCSink(client)
    }

    newConnection.invalidationHandler = {
      Log.setXPCSink(nil)
      Log.debug("XPC connection closed")
    }

    newConnection.interruptionHandler = {
      Log.setXPCSink(nil)
      Log.debug("XPC connection interrupted")
    }

    newConnection.resume()
    return true
  }

  // MARK: - Connection Management

  private func ensureConnected() throws {
    if fanController == nil {
      let conn = try SMCConnection()
      fanController = try FanController(connection: conn)
      Log.debug("SMC connection established, hardware config detected")
    }
  }

  // MARK: - SMCFanHelperProtocol

  func smcOpen(reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
      reply(true, nil)
    } catch {
      Log.warning("SMC open failed: \(error)")
      reply(false, error.localizedDescription)
    }
  }

  func smcClose(reply: @escaping (Bool, String?) -> Void) {
    fanController = nil
    Log.debug("SMC connection released")
    reply(true, nil)
  }

  func smcReadKey(_ key: String, reply: @escaping (Bool, Float, String?) -> Void) {
    do {
      try ensureConnected()
      guard let fanController = fanController else {
        reply(false, 0, "Connection not established")
        return
      }
      let (value, size) = try fanController.connection.readKey(key)
      let floatVal = SMCDataFormat.float(from: value, size: size)
      Log.debug("read \(key) = \(floatVal) (size=\(size) bytes=\(value))")
      reply(true, floatVal, nil)
    } catch {
      Log.debug("read \(key) failed: \(error)")
      reply(false, 0, error.localizedDescription)
    }
  }

  func smcWriteKey(_ key: String, value: Float, reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
      guard let fanController = fanController else {
        reply(false, "Connection not established")
        return
      }
      let (_, size) = try fanController.connection.readKey(key)
      let writeVal = SMCDataFormat.bytes(from: value, size: size)
      try fanController.connection.writeKey(key, bytes: writeVal)
      Log.debug("wrote \(key) = \(value) (size=\(size) bytes=\(writeVal))")
      reply(true, nil)
    } catch {
      Log.debug("write \(key) = \(value) failed: \(error)")
      reply(false, error.localizedDescription)
    }
  }

  func smcGetFanCount(reply: @escaping (Bool, UInt, String?) -> Void) {
    do {
      try ensureConnected()
      guard let fanController = fanController else {
        reply(false, 0, "Connection not established")
        return
      }
      let (value, _) = try fanController.connection.readKey(SMCFanKey.count)
      let count = UInt(value[0])
      reply(true, count, nil)
    } catch {
      Log.debug("failed to read fan count: \(error)")
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

      let manualMode: Bool
      do {
        guard let fanController = fanController else { throw SMCError.notOpen }
        let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
        let (modeValue, _) = try fanController.connection.readKey(modeKey)
        manualMode = modeValue[0] == 1
      } catch {
        Log.debug("could not read mode for fan \(fanIndex): \(error)")
        manualMode = false
      }

      Log.debug("fan \(fanIndex): actual=\(Int(actualRPM)) target=\(Int(targetRPM)) min=\(Int(minRPM)) max=\(Int(maxRPM)) manual=\(manualMode)")
      reply(true, actualRPM, targetRPM, minRPM, maxRPM, manualMode, nil)
    } catch {
      Log.debug("fan \(fanIndex) info read failed: \(error)")
      reply(false, 0, 0, 0, 0, false, error.localizedDescription)
    }
  }

  private func readFloat(fanIndex: UInt, keyFormat: String) -> Float? {
    let key = SMCFanKey.key(keyFormat, fan: Int(fanIndex))
    guard let fanController = fanController else { return nil }
    do {
      let (value, size) = try fanController.connection.readKey(key)
      return SMCDataFormat.float(from: value, size: size)
    } catch {
      Log.debug("read \(key) failed: \(error)")
      return nil
    }
  }

  func smcSetFanRPM(_ fanIndex: UInt, rpm: Float, reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
    } catch {
      Log.warning("connection failed setting fan \(fanIndex) to \(Int(rpm)) RPM: \(error)")
      reply(false, error.localizedDescription)
      return
    }

    guard let fanController = fanController else {
      reply(false, "Connection not established")
      return
    }

    let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
    let alreadyManual: Bool
    do {
      let (modeBytes, _) = try fanController.connection.readKey(modeKey)
      alreadyManual = !modeBytes.isEmpty && modeBytes[0] == 1
    } catch {
      Log.debug("could not read mode for fan \(fanIndex), assuming auto: \(error)")
      alreadyManual = false
    }

    if !alreadyManual {
      do {
        let strategy = try fanController.enableManualMode(fanIndex: Int(fanIndex))
        Log.logger.info("enableManualMode: strategy=\(String(describing: strategy)) fan=\(fanIndex)", metadata: sensorSnapshot())
      } catch {
        Log.warning("enableManualMode failed for fan \(fanIndex): \(error)")
        reply(false, error.localizedDescription)
        return
      }
    }

    let key = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
    let value = SMCDataFormat.bytes(from: rpm, size: 4)

    do {
      try fanController.connection.writeKey(key, bytes: value)
      Log.logger.info("Set fan \(fanIndex) to \(Int(rpm)) RPM", metadata: sensorSnapshot())
      reply(true, nil)

      let capturedFanIndex = fanIndex
      let capturedRPM = rpm
      Task.detached { [weak self] in
        await self?.verifyFanSpeed(fanIndex: capturedFanIndex, targetRPM: capturedRPM)
      }
    } catch {
      Log.warning("failed to write target RPM for fan \(fanIndex): \(error)")
      reply(false, error.localizedDescription)
    }
  }

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
        Log.debug("lost connection reading fan \(fanIndex) RPM during verify, aborting")
        return
      }

      let diff = abs(actualRPM - targetRPM) / max(targetRPM, 1)
      Log.debug("fan \(fanIndex) ramping: \(Int(actualRPM))/\(Int(targetRPM)) RPM (\(String(format: "%.1f", diff * 100))% off)")

      if diff <= tolerance {
        let elapsed = Date().timeIntervalSince(startTime)
        Log.info("fan \(fanIndex) reached \(Int(actualRPM)) RPM (target \(Int(targetRPM))) in \(String(format: "%.1f", elapsed))s")
        return
      }

      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    if let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) {
      Log.warning("fan \(fanIndex) at \(Int(actualRPM)) RPM after \(Int(timeout))s, target was \(Int(targetRPM))")
    }
  }

  func smcSetFanAuto(_ fanIndex: UInt, reply: @escaping (Bool, String?) -> Void) {
    do {
      try ensureConnected()
    } catch {
      Log.warning("connection failed resetting fan \(fanIndex) to auto: \(error)")
      reply(false, error.localizedDescription)
      return
    }

    guard let fanController = fanController else {
      reply(false, "Connection not established")
      return
    }

    let fanCount: Int
    do {
      let (numBytes, _) = try fanController.connection.readKey(SMCFanKey.count)
      fanCount = Int(numBytes[0])
    } catch {
      Log.warning("failed to read fan count: \(error)")
      reply(false, "Failed to read fan count")
      return
    }

    var otherFansManual = 0
    for i in 0..<fanCount {
      if i == Int(fanIndex) { continue }
      let checkKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: i)
      do {
        let (checkBytes, _) = try fanController.connection.readKey(checkKey)
        if !checkBytes.isEmpty && checkBytes[0] == 1 { otherFansManual += 1 }
      } catch {
        continue
      }
    }

    let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
    do {
      try fanController.connection.writeKey(modeKey, bytes: [0])
    } catch {
      Log.warning("failed to set auto mode for fan \(fanIndex): \(error)")
    }

    let targetKey = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
    let writeVal = SMCDataFormat.bytes(from: 0, size: 4)
    do {
      try fanController.connection.writeKey(targetKey, bytes: writeVal)
    } catch {
      Log.warning("failed to reset target for fan \(fanIndex): \(error)")
    }

    if otherFansManual > 0 {
      Log.logger.info("setFanAuto: fan \(fanIndex) to auto, \(otherFansManual) other fans still manual", metadata: sensorSnapshot())
    } else if fanController.config.ftstAvailable {
      do {
        let (ftstBytes, _) = try fanController.connection.readKey(SMCFanKey.forceTest)
        if !ftstBytes.isEmpty, ftstBytes[0] == 1 {
          try fanController.resetFanControl()
          Log.logger.info("setFanAuto: Ftst reset, thermalmonitord reclaiming control", metadata: sensorSnapshot())
        }
      } catch {
        Log.warning("setFanAuto: Ftst reset failed: \(error)")
      }
    } else {
      Log.logger.info("setFanAuto: all fans auto, no Ftst on this hardware", metadata: sensorSnapshot())
    }

    reply(true, nil)
  }

  private func sensorSnapshot() -> Logging.Logger.Metadata {
    guard ultraDebug, let fc = fanController else { return [:] }
    var meta: Logging.Logger.Metadata = [:]

    if let (countBytes, _) = try? fc.connection.readKey(SMCFanKey.count) {
      let count = Int(countBytes[0])
      for i in 0..<count {
        if let rpm = readFloat(fanIndex: UInt(i), keyFormat: SMCFanKey.actual) {
          meta["fan.\(i).rpm"] = "\(Int(rpm))"
        }
        if let target = readFloat(fanIndex: UInt(i), keyFormat: SMCFanKey.target) {
          meta["fan.\(i).target"] = "\(Int(target))"
        }
      }
    }

    for key in tempKeys {
      if let (bytes, size) = try? fc.connection.readKey(key) {
        let temp = SMCDataFormat.float(from: bytes, size: size)
        if temp > 0 && temp < 150 {
          meta["temp.\(key)"] = "\(String(format: "%.1f", temp))C"
        }
      }
    }

    return meta
  }

  func smcEnumerateKeys(reply: @escaping ([String]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try self.ensureConnected()
        guard let fanController = self.fanController else {
          reply([])
          return
        }
        let keys = fanController.connection.enumerateKeys()
        Log.debug("enumerated \(keys.count) SMC keys")
        reply(keys)
      } catch {
        Log.debug("key enumeration failed: \(error)")
        reply([])
      }
    }
  }
}
