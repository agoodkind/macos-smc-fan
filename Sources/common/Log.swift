//
//  Log.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-02-14.
//  Copyright © 2026
//

import Foundation
import os

private final class XPCSinkHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var _sink: SMCFanClientProtocol?

  var sink: SMCFanClientProtocol? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _sink
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _sink = newValue
    }
  }
}

public enum Log {
  private static let subsystem = SMCFanConfiguration.default.helperBundleID
  private static let category = "fan-control"
  private static let legacyLog = OSLog(subsystem: subsystem, category: category)
  private static let sinkHolder = XPCSinkHolder()

  public static func setXPCSink(_ sink: SMCFanClientProtocol?) {
    sinkHolder.sink = sink
  }

  private static func format(_ message: String, _ function: String) -> String {
    "\(function): \(message)"
  }

  public static func info(_ message: String, function: String = #function) {
    let msg = format(message, function)
    if #available(macOS 11.0, *) {
      Logger(subsystem: subsystem, category: category).info("\(msg, privacy: .public)")
    } else {
      os_log(.info, log: legacyLog, "%{public}s", msg)
    }
    sinkHolder.sink?.logMessage(msg)
  }

  public static func notice(_ message: String, function: String = #function) {
    let msg = format(message, function)
    if #available(macOS 11.0, *) {
      Logger(subsystem: subsystem, category: category).notice("\(msg, privacy: .public)")
    } else {
      os_log(.default, log: legacyLog, "%{public}s", msg)
    }
    sinkHolder.sink?.logMessage(msg)
  }

  public static func warning(_ message: String, function: String = #function) {
    let msg = format(message, function)
    if #available(macOS 11.0, *) {
      Logger(subsystem: subsystem, category: category).warning("\(msg, privacy: .public)")
    } else {
      os_log(.error, log: legacyLog, "%{public}s", msg)
    }
    sinkHolder.sink?.logMessage(msg)
  }

  public static func debug(_ message: String, function: String = #function) {
    let msg = format(message, function)
    if #available(macOS 11.0, *) {
      Logger(subsystem: subsystem, category: category).debug("\(msg, privacy: .public)")
    } else {
      os_log(.debug, log: legacyLog, "%{public}s", msg)
    }
  }

  public static func connectionInfo(_ message: String, function: String = #function) {
    info(message, function: function)
  }

  public static func connectionNotice(_ message: String, function: String = #function) {
    notice(message, function: function)
  }

  public static func connectionWarning(_ message: String, function: String = #function) {
    warning(message, function: function)
  }

  public static func error(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
  }
}
