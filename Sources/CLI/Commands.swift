//
//  Commands.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCFanLogging

private let tempKeys = [
  "Ts0P", "Ts1P",  // M5 Max
  "Tp09", "Tp0T",  // Apple Silicon (some models)
  "TC0P", "TC0p",  // Intel
  "Tg0f", "Tw0P",  // GPU, wireless
]

enum Commands {

  static func list() async throws {
    let client = try XPCClient()
    try await client.open()

    let count = try await client.getFanCount()
    print("Fans: \(count)")

    for i in 0..<count {
      let info = try await client.getFanInfo(i)
      print(
        "Fan \(i): \(Int(info.actualRPM)) RPM " + "(Target: \(Int(info.targetRPM)), "
          + "Min: \(Int(info.minRPM)), " + "Max: \(Int(info.maxRPM)), "
          + "Mode: \(info.manualMode ? "Manual" : "Auto"))"
      )
    }

    var temps: [String] = []
    for key in tempKeys {
      if let value = try? await client.readKey(key), value > 0, value < 150 {
        temps.append("\(key): \(String(format: "%.1f", value))C")
      }
    }
    if !temps.isEmpty {
      print("Temps: \(temps.joined(separator: ", "))")
    }
  }

  static func set(fan: Int, rpm: Float) async throws {
    Log.debug("setting fan \(fan) to \(Int(rpm)) RPM")
    let client = try XPCClient()
    try await client.open()
    try await client.setFanRPM(UInt(fan), rpm: rpm)
    print("Set fan \(fan) to \(Int(rpm)) RPM")
  }

  static func auto(fan: Int) async throws {
    Log.debug("resetting fan \(fan) to auto")
    let client = try XPCClient()
    try await client.open()
    try await client.setFanAuto(UInt(fan))
    print("Set fan \(fan) to auto mode")
  }

  static func read(key: String) async throws {
    let client = try XPCClient()
    try await client.open()
    let value = try await client.readKey(key)
    print("\(key) = \(value)")
  }

  static func keys(filter: String? = nil) async throws {
    let client = try XPCClient()
    try await client.open()
    let allKeys = await client.enumerateKeys()
    let filtered = filter.map { f in allKeys.filter { $0.hasPrefix(f) } } ?? allKeys
    Log.debug("enumerated \(allKeys.count) keys, \(filtered.count) matching filter")
    print("Keys: \(filtered.count)\(filter.map { " (filter: \($0))" } ?? "")")
    for key in filtered {
      let value = try? await client.readKey(key)
      print("  \(key) = \(value.map { String($0) } ?? "?")")
    }
  }

  static func showLog() {
    let path = SMCFanLogPaths.daemonLog
    if FileManager.default.fileExists(atPath: path) {
      print("Log file: \(path)")
      print("---")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
      process.arguments = ["-20", path]
      process.standardOutput = FileHandle.standardOutput
      try? process.run()
      process.waitUntilExit()
    } else {
      print("No log file found at \(path)")
      print("Run 'make install' to set up the helper daemon.")
    }
  }

  static func printUsage() {
    print("Usage: smcfan <command> [args...]")
    print("")
    print("Commands:")
    print("  list              List all fans with current status and temps")
    print("  set <fan> <rpm>   Set fan speed to specified RPM")
    print("  auto <fan>        Return fan to automatic control")
    print("  read <key>        Read value of SMC key")
    print("  keys [prefix]     Enumerate all SMC keys (optionally filter by prefix)")
    print("  log               Show daemon log file (last 20 lines)")
    print("  help, -h, --help  Show this help message")
  }
}
