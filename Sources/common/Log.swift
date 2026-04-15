//
//  Log.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-02-14.
//  Copyright © 2026
//

import Foundation
import Logging

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

/// Logging facade that delegates to swift-log and relays messages over XPC.
///
/// Call sites use `Log.info(...)`, `Log.debug(...)`, etc. The underlying
/// swift-log backend (JSONL to stderr + os_log) is configured by calling
/// `LogBootstrap.configure()` at process start.
public enum Log {
  nonisolated(unsafe) public static var logger = Logging.Logger(label: "io.goodkind.smcfan")
  private static let sinkHolder = XPCSinkHolder()

  public static func setXPCSink(_ sink: SMCFanClientProtocol?) {
    sinkHolder.sink = sink
  }

  public static func info(_ message: String, function: String = #function) {
    logger.info("\(function): \(message)")
    sinkHolder.sink?.logMessage("\(function): \(message)")
  }

  public static func notice(_ message: String, function: String = #function) {
    logger.notice("\(function): \(message)")
    sinkHolder.sink?.logMessage("\(function): \(message)")
  }

  public static func warning(_ message: String, function: String = #function) {
    logger.warning("\(function): \(message)")
    sinkHolder.sink?.logMessage("\(function): \(message)")
  }

  public static func debug(_ message: String, function: String = #function) {
    logger.debug("\(function): \(message)")
  }

  public static func error(_ message: String) {
    logger.error("\(message)")
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
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
}
