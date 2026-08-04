//
//  BuildInfo.swift
//  AppLog
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026, all rights reserved.
//
//  Moved from SMCFanLogging/LogBootstrap.swift.
//  Emitted as a single process.started notice in AppLog.bootstrap.

import CryptoKit
import Foundation

public enum BuildInfo {
  private static let buildHashLength = 12
  private static let cachedExecutableHash = computeExecutableHash()

  nonisolated(unsafe) public static var commit = "unknown"
  nonisolated(unsafe) public static var version = "dev"
  nonisolated(unsafe) public static var build = "unknown"
  nonisolated(unsafe) public static var dirty = "false"

  public static func executableHash() -> String {
    cachedExecutableHash
  }

  private static func computeExecutableHash() -> String {
    guard let executable = Bundle.main.executableURL else {
      return "unknown"
    }
    let bytes: Data
    do {
      bytes = try Data(contentsOf: executable)
    } catch {
      return "unknown"
    }
    return SHA256.hash(data: bytes)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public static func buildHash() -> String {
    String(executableHash().prefix(buildHashLength))
  }
}
