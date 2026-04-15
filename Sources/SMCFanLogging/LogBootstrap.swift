//
//  LogBootstrap.swift
//  SMCFanLogging
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-15.
//  Copyright © 2026
//

import Foundation
import Logging
@preconcurrency import struct JSONLogger.JSONLogger
import os
import CommonCrypto

// MARK: - XDG Paths

private enum XDG {
  static var stateHome: String {
    ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
      ?? NSHomeDirectory() + "/.local/state"
  }

  static var logDir: String { stateHome + "/smcfan" }
  static var daemonLogPath: String { logDir + "/daemon.log" }
}

// MARK: - Build Info

public enum BuildInfo {
  public nonisolated(unsafe) static var commit = "unknown"
  public nonisolated(unsafe) static var version = "dev"
  public nonisolated(unsafe) static var dirty = "false"

  public static func buildHash() -> String {
    guard let exe = Bundle.main.executableURL,
      let data = try? Data(contentsOf: exe)
    else { return "unknown" }
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  static var metadata: Logging.Logger.Metadata {
    [
      "commit": "\(commit)",
      "version": "\(version)",
      "buildHash": "\(buildHash())",
      "dirty": "\(dirty)",
    ]
  }
}

// MARK: - Bootstrap

public enum LogBootstrap {

  public static func configure(subsystem: String, extraHandlers: [any LogHandler] = []) {
    let stderrEnabled = ProcessInfo.processInfo.environment["SMCFAN_DEBUG"] != nil

    let fileHandle = openLogFile()

    LoggingSystem.bootstrap { label in
      // 1. File: always on, all levels, JSONL
      var file = JSONLogger(label: label, fileHandle: fileHandle)
      file.logLevel = .trace

      // 2. os_log: always on, all levels, Console.app
      var oslog = OSLogBridge(subsystem: subsystem, category: label)
      oslog.logLevel = .trace

      var handlers: [any LogHandler] = [file, oslog]

      // 3. stderr: only with SMCFAN_DEBUG
      if stderrEnabled {
        var stderr = JSONLogger(label: label, fileHandle: .standardError)
        stderr.logLevel = .debug
        handlers.append(stderr)
      }

      handlers.append(contentsOf: extraHandlers)

      // Attach build info to every handler
      var mux = MultiplexLogHandler(handlers)
      for (key, value) in BuildInfo.metadata {
        mux.metadata[key] = value
      }
      return mux
    }
  }

  private static func openLogFile() -> FileHandle {
    let dir = XDG.logDir
    let path = XDG.daemonLogPath
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let fh = FileHandle(forWritingAtPath: path) else {
      return .standardError
    }
    fh.seekToEndOfFile()
    return fh
  }
}

// MARK: - os_log Bridge

private struct OSLogBridge: LogHandler, Sendable {
  let subsystem: String
  let category: String
  var metadata: Logging.Logger.Metadata = [:]
  var logLevel: Logging.Logger.Level = .trace

  subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    let osLog = OSLog(subsystem: subsystem, category: category)
    let osLogType: OSLogType
    switch event.level {
    case .trace, .debug: osLogType = .debug
    case .info, .notice: osLogType = .info
    case .warning: osLogType = .error
    case .error, .critical: osLogType = .fault
    }
    os_log(osLogType, log: osLog, "%{public}s", "\(event.message)")
  }
}
