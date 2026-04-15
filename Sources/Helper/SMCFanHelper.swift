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

/// XPC service that handles privileged SMC operations
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
    Log.info("Service started")
    Log.debug("listener resumed, entering RunLoop")
    RunLoop.current.run()
  }

  // MARK: - NSXPCListenerDelegate

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    Log.debug(
      "new XPC connection request pid=\(newConnection.processIdentifier) euid=\(newConnection.effectiveUserIdentifier)"
    )
    newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    newConnection.exportedObject = self
    newConnection.remoteObjectInterface = NSXPCInterface(with: SMCFanClientProtocol.self)

    if let client = newConnection.remoteObjectProxy as? SMCFanClientProtocol {
      Log.setXPCSink(client)
      Log.debug("XPC sink set for pid=\(newConnection.processIdentifier)")
    } else {
      Log.debug("failed to get remote object proxy as SMCFanClientProtocol")
    }

    newConnection.invalidationHandler = {
      Log.debug("XPC connection invalidated")
      Log.setXPCSink(nil)
      Log.notice("Connection invalidated")
    }

    newConnection.interruptionHandler = {
      Log.debug("XPC connection interrupted")
      Log.setXPCSink(nil)
      Log.notice("Connection interrupted")
    }

    newConnection.resume()
    Log.debug("accepted and resumed connection from pid=\(newConnection.processIdentifier)")
    return true
  }

  // MARK: - Connection Management

  private func ensureConnected() throws {
    if fanController == nil {
      Log.debug("no existing connection, creating new SMCConnection")
      let conn = try SMCConnection()
      fanController = try FanController(connection: conn)
      Log.debug("SMCConnection created successfully")
    } else {
      Log.debug("reusing existing SMCConnection")
    }
  }

  // MARK: - SMCFanHelperProtocol

  func smcOpen(reply: @escaping (Bool, String?) -> Void) {
    Log.debug("called")
    do {
      try ensureConnected()
      Log.debug("success")
      reply(true, nil)
    } catch {
      Log.debug("error=\(error)")
      reply(false, error.localizedDescription)
    }
  }

  func smcClose(reply: @escaping (Bool, String?) -> Void) {
    Log.debug("ENTER connectionActive=\(fanController != nil)")
    fanController = nil
    Log.debug("connection released")
    reply(true, nil)
  }

  func smcReadKey(_ key: String, reply: @escaping (Bool, Float, String?) -> Void) {
    Log.debug("ENTER key=\(key)")
    do {
      try ensureConnected()
      guard let fanController = fanController else {
        Log.debug("no connection")
        reply(false, 0, "Connection not established")
        return
      }
      let (value, size) = try fanController.connection.readKey(key)
      let floatVal = SMCDataFormat.float(from: value, size: size)
      Log.debug("key=\(key) size=\(size) bytes=\(value) float=\(floatVal)")
      reply(true, floatVal, nil)
    } catch {
      Log.debug("key=\(key) error=\(error)")
      reply(false, 0, error.localizedDescription)
    }
  }

  func smcWriteKey(_ key: String, value: Float, reply: @escaping (Bool, String?) -> Void) {
    Log.debug("ENTER key=\(key) value=\(value)")
    do {
      try ensureConnected()
      guard let fanController = fanController else {
        Log.debug("no connection")
        reply(false, "Connection not established")
        return
      }
      let (_, size) = try fanController.connection.readKey(key)
      let writeVal = SMCDataFormat.bytes(from: value, size: size)
      Log.debug("key=\(key) size=\(size) encodedBytes=\(writeVal)")
      try fanController.connection.writeKey(key, bytes: writeVal)
      Log.debug("key=\(key) OK")
      reply(true, nil)
    } catch {
      Log.debug("key=\(key) error=\(error)")
      reply(false, error.localizedDescription)
    }
  }

  func smcGetFanCount(reply: @escaping (Bool, UInt, String?) -> Void) {
    Log.debug("called")
    do {
      try ensureConnected()
      guard let fanController = fanController else {
        Log.debug("no connection")
        reply(false, 0, "Connection not established")
        return
      }
      let (value, _) = try fanController.connection.readKey(SMCFanKey.count)
      let count = UInt(value[0])
      Log.debug("count=\(count)")
      reply(true, count, nil)
    } catch {
      Log.debug("error=\(error)")
      reply(false, 0, error.localizedDescription)
    }
  }

  func smcGetFanInfo(
    _ fanIndex: UInt,
    reply: @escaping (Bool, Float, Float, Float, Float, Bool, String?) -> Void
  ) {
    Log.debug("ENTER fan=\(fanIndex)")
    do {
      try ensureConnected()

      let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) ?? 0
      let targetRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.target) ?? 0
      let minRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.minimum) ?? 0
      let maxRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.maximum) ?? 0

      let manualMode: Bool
      do {
        guard let fanController = fanController else {
          throw SMCError.notOpen
        }
        let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
        let (modeValue, _) = try fanController.connection.readKey(modeKey)
        manualMode = modeValue[0] == 1
      } catch {
        Log.debug("failed to read mode key for fan \(fanIndex): \(error)")
        manualMode = false
      }

      Log.debug(
        "EXIT fan=\(fanIndex) actual=\(Int(actualRPM)) target=\(Int(targetRPM)) min=\(Int(minRPM)) max=\(Int(maxRPM)) manual=\(manualMode)"
      )
      reply(true, actualRPM, targetRPM, minRPM, maxRPM, manualMode, nil)
    } catch {
      Log.debug("fan=\(fanIndex) error=\(error)")
      reply(false, 0, 0, 0, 0, false, error.localizedDescription)
    }
  }

  private func readFloat(fanIndex: UInt, keyFormat: String) -> Float? {
    let key = SMCFanKey.key(keyFormat, fan: Int(fanIndex))
    guard let fanController = fanController else {
      Log.debug("no connection for key=\(key)")
      return nil
    }
    do {
      let (value, size) = try fanController.connection.readKey(key)
      let result = SMCDataFormat.float(from: value, size: size)
      Log.debug("key=\(key) size=\(size) bytes=\(value) float=\(result)")
      return result
    } catch {
      Log.debug("key=\(key) error=\(error)")
      return nil
    }
  }

  func smcSetFanRPM(_ fanIndex: UInt, rpm: Float, reply: @escaping (Bool, String?) -> Void) {
    Log.debug("ENTER fan=\(fanIndex) rpm=\(Int(rpm))")
    do {
      try ensureConnected()
    } catch {
      Log.debug("connection error=\(error)")
      reply(false, error.localizedDescription)
      return
    }

    guard let fanController = fanController else {
      Log.debug("no connection")
      reply(false, "Connection not established")
      return
    }

    let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
    let alreadyManual: Bool
    do {
      let (modeBytes, _) = try fanController.connection.readKey(modeKey)
      alreadyManual = !modeBytes.isEmpty && modeBytes[0] == 1
    } catch {
      Log.debug("failed to read mode key \(modeKey): \(error)")
      alreadyManual = false
    }

    Log.debug("fan=\(fanIndex) rpm=\(Int(rpm)) alreadyManual=\(alreadyManual)")

    if !alreadyManual {
      do {
        let strategy = try fanController.enableManualMode(fanIndex: Int(fanIndex))
        Log.info("enableManualMode: strategy=\(String(describing: strategy)) fan=\(fanIndex)")
      } catch {
        Log.debug("enableManualMode failed: \(error)")
        reply(false, error.localizedDescription)
        return
      }
    } else {
      Log.debug("fan \(fanIndex) already in manual mode, skipping enableManualMode")
    }

    let key = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
    let value = SMCDataFormat.bytes(from: rpm, size: 4)
    Log.debug("writing target key=\(key) bytes=\(value)")

    do {
      try fanController.connection.writeKey(key, bytes: value)
      Log.info("Set fan \(fanIndex) to \(Int(rpm)) RPM")
      Log.debug("fan=\(fanIndex) rpm=\(Int(rpm)) OK")
      reply(true, nil)

      let capturedFanIndex = fanIndex
      let capturedRPM = rpm
      Task.detached { [weak self] in
        await self?.verifyFanSpeed(
          fanIndex: capturedFanIndex, targetRPM: capturedRPM
        )
      }
    } catch {
      Log.debug("fan=\(fanIndex) writeKey error=\(error)")
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
    Log.debug("BEGIN fan=\(fanIndex) target=\(Int(targetRPM)) timeout=\(timeout)s")
    let startTime = Date()
    let tolerance: Float = 0.10

    while Date().timeIntervalSince(startTime) < timeout {
      guard let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) else {
        Log.debug("failed to read actual RPM for fan \(fanIndex), aborting")
        return
      }

      let diff = abs(actualRPM - targetRPM) / max(targetRPM, 1)
      Log.debug(
        "fan=\(fanIndex) actual=\(Int(actualRPM)) target=\(Int(targetRPM)) diff=\(String(format: "%.1f", diff * 100))%"
      )
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
    Log.debug("ENTER fan=\(fanIndex)")
    do {
      try ensureConnected()
    } catch {
      Log.debug("connection error=\(error)")
      reply(false, error.localizedDescription)
      return
    }

    guard let fanController = fanController else {
      Log.debug("no connection")
      reply(false, "Connection not established")
      return
    }

    let fanCount: Int
    do {
      let (numBytes, _) = try fanController.connection.readKey(SMCFanKey.count)
      fanCount = Int(numBytes[0])
      Log.debug("fanCount=\(fanCount)")
    } catch {
      Log.debug("failed to read fan count: \(error)")
      reply(false, "Failed to read fan count")
      return
    }

    var otherFansManual = 0

    for i in 0..<fanCount {
      if i == Int(fanIndex) { continue }
      let checkKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: i)
      do {
        let (checkBytes, _) = try fanController.connection.readKey(checkKey)
        let isManual = !checkBytes.isEmpty && checkBytes[0] == 1
        Log.debug("fan \(i) mode bytes=\(checkBytes) isManual=\(isManual)")
        if isManual {
          otherFansManual += 1
        }
      } catch {
        Log.debug("failed to read mode for fan \(i): \(error)")
        continue
      }
    }

    let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
    Log.debug("writing modeKey=\(modeKey) bytes=[0]")
    do {
      try fanController.connection.writeKey(modeKey, bytes: [0])
      Log.debug("modeKey write OK")
    } catch {
      Log.warning("Failed to set auto mode: \(error)")
    }

    let targetKey = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
    let writeVal = SMCDataFormat.bytes(from: 0, size: 4)
    Log.debug("writing targetKey=\(targetKey) bytes=\(writeVal)")
    do {
      try fanController.connection.writeKey(targetKey, bytes: writeVal)
      Log.debug("target write OK")
    } catch {
      Log.warning("Failed to reset target: \(error)")
    }

    if otherFansManual > 0 {
      Log.info("setFanAuto: fan \(fanIndex) to auto, \(otherFansManual) other fans still manual")
      Log.debug("skipping Ftst reset, \(otherFansManual) other fans still manual")
    } else if fanController.config.ftstAvailable {
      do {
        let (ftstBytes, _) = try fanController.connection.readKey(SMCFanKey.forceTest)
        Log.debug("current Ftst bytes=\(ftstBytes)")
        if !ftstBytes.isEmpty, ftstBytes[0] == 1 {
          try fanController.resetFanControl()
          Log.info("setFanAuto: Ftst reset succeeded")
        } else {
          Log.debug("Ftst already 0, no reset needed")
        }
      } catch {
        Log.warning("setFanAuto: Ftst reset failed: \(error)")
      }
    } else {
      Log.info("setFanAuto: all fans auto, no Ftst on this hardware")
    }

    Log.debug("fan=\(fanIndex) OK")
    reply(true, nil)
  }

  func smcEnumerateKeys(reply: @escaping ([String]) -> Void) {
    Log.debug("called")
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try self.ensureConnected()
        guard let fanController = self.fanController else {
          Log.debug("no connection")
          reply([])
          return
        }
        let keys = fanController.connection.enumerateKeys()
        Log.debug("found \(keys.count) keys")
        reply(keys)
      } catch {
        Log.debug("error=\(error)")
        reply([])
      }
    }
  }
}
