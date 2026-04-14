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

  static let helper = Logger(subsystem: subsystem, category: "fan-control")
  static let connection = Logger(subsystem: subsystem, category: "smc-connection")

  private static let sinkHolder = XPCSinkHolder()

  public static func setXPCSink(_ sink: SMCFanClientProtocol?) {
    sinkHolder.sink = sink
  }

  public static func info(_ message: String) {
    helper.info("\(message, privacy: .public)")
    sinkHolder.sink?.logMessage(message)
  }

  public static func notice(_ message: String) {
    helper.notice("\(message, privacy: .public)")
    sinkHolder.sink?.logMessage(message)
  }

  public static func warning(_ message: String) {
    helper.warning("\(message, privacy: .public)")
    sinkHolder.sink?.logMessage(message)
  }

  public static func debug(_ message: String) {
    helper.debug("\(message, privacy: .public)")
  }

  public static func connectionInfo(_ message: String) {
    connection.info("\(message, privacy: .public)")
    sinkHolder.sink?.logMessage(message)
  }

  public static func connectionNotice(_ message: String) {
    connection.notice("\(message, privacy: .public)")
    sinkHolder.sink?.logMessage(message)
  }

  public static func connectionWarning(_ message: String) {
    connection.warning("\(message, privacy: .public)")
    sinkHolder.sink?.logMessage(message)
  }

  public static func error(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
  }
}
