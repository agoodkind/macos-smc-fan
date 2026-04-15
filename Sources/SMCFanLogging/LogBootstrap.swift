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

public enum LogBootstrap {

  public static func configure(subsystem: String, extraHandlers: [any LogHandler] = []) {
    let debugEnabled = ProcessInfo.processInfo.environment["SMCFAN_DEBUG"] != nil
    let level: Logging.Logger.Level = debugEnabled ? .debug : .info

    LoggingSystem.bootstrap { label in
      var json = JSONLogger(label: label, fileHandle: .standardError)
      json.logLevel = level
      var oslog = OSLogBridge(subsystem: subsystem, category: label)
      oslog.logLevel = level
      var handlers: [any LogHandler] = [json, oslog]
      handlers.append(contentsOf: extraHandlers)
      return MultiplexLogHandler(handlers)
    }
  }
}

private struct OSLogBridge: LogHandler, Sendable {
  let subsystem: String
  let category: String
  var metadata: Logging.Logger.Metadata = [:]
  var logLevel: Logging.Logger.Level = .debug

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
