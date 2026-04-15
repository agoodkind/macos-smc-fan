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

  static let shared = XPCSinkHolder()
}

/// LogHandler that forwards log messages over XPC to the connected client.
/// Messages at info level and above are relayed so the CLI can display helper activity.
public struct XPCRelayLogHandler: LogHandler, @unchecked Sendable {
  public var metadata: Logging.Logger.Metadata = [:]
  public var logLevel: Logging.Logger.Level = .info

  public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  public func log(event: LogEvent) {
    XPCSinkHolder.shared.sink?.logMessage("\(event.function): \(event.message)")
  }
}

public enum Log {
  nonisolated(unsafe) public static var logger = Logging.Logger(label: "io.goodkind.smcfan")

  public static func setXPCSink(_ sink: SMCFanClientProtocol?) {
    XPCSinkHolder.shared.sink = sink
  }

  public static func info(
    _ message: String,
    function: String = #function,
    file: String = #fileID,
    line: UInt = #line
  ) {
    logger.info("\(message)", file: file, function: function, line: line)
  }

  public static func notice(
    _ message: String,
    function: String = #function,
    file: String = #fileID,
    line: UInt = #line
  ) {
    logger.notice("\(message)", file: file, function: function, line: line)
  }

  public static func warning(
    _ message: String,
    function: String = #function,
    file: String = #fileID,
    line: UInt = #line
  ) {
    logger.warning("\(message)", file: file, function: function, line: line)
  }

  public static func debug(
    _ message: String,
    function: String = #function,
    file: String = #fileID,
    line: UInt = #line
  ) {
    logger.debug("\(message)", file: file, function: function, line: line)
  }

  public static func error(
    _ message: String,
    file: String = #fileID,
    line: UInt = #line
  ) {
    logger.error("\(message)", file: file, function: "error", line: line)
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
  }

  public static func connectionInfo(_ message: String, function: String = #function, file: String = #fileID, line: UInt = #line) {
    info(message, function: function, file: file, line: line)
  }

  public static func connectionNotice(_ message: String, function: String = #function, file: String = #fileID, line: UInt = #line) {
    notice(message, function: function, file: file, line: line)
  }

  public static func connectionWarning(_ message: String, function: String = #function, file: String = #fileID, line: UInt = #line) {
    warning(message, function: function, file: file, line: line)
  }
}
