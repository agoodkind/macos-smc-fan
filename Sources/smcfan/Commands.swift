//
//  Commands.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCCommon

/// Shared command implementations used by both ArgumentParser and simple CLI
enum Commands {

  static func list() async throws {
    Log.debug("BEGIN")
    let client = try XPCClient()
    try await client.open()

    let count = try await client.getFanCount()
    print("Fans: \(count)")

    for i in 0..<count {
      Log.debug("querying fan \(i)")
      let info = try await client.getFanInfo(i)
      print(
        "Fan \(i): \(Int(info.actualRPM)) RPM " + "(Target: \(Int(info.targetRPM)), "
          + "Min: \(Int(info.minRPM)), " + "Max: \(Int(info.maxRPM)), "
          + "Mode: \(info.manualMode ? "Manual" : "Auto"))"
      )
    }
    Log.debug("END")
  }

  static func set(fan: Int, rpm: Float) async throws {
    Log.debug("BEGIN fan=\(fan) rpm=\(Int(rpm))")
    let client = try XPCClient()
    try await client.open()
    try await client.setFanRPM(UInt(fan), rpm: rpm)
    print("Set fan \(fan) to \(Int(rpm)) RPM")
    Log.debug("END")
  }

  static func auto(fan: Int) async throws {
    Log.debug("BEGIN fan=\(fan)")
    let client = try XPCClient()
    try await client.open()
    try await client.setFanAuto(UInt(fan))
    print("Set fan \(fan) to auto mode")
    Log.debug("END")
  }

  static func read(key: String) async throws {
    Log.debug("BEGIN key=\(key)")
    let client = try XPCClient()
    try await client.open()
    let value = try await client.readKey(key)
    print("\(key) = \(value)")
    Log.debug("END key=\(key) value=\(value)")
  }

  static func keys(filter: String? = nil) async throws {
    Log.debug("BEGIN filter=\(filter ?? "nil")")
    let client = try XPCClient()
    try await client.open()
    let allKeys = await client.enumerateKeys()
    let filtered = filter.map { f in allKeys.filter { $0.hasPrefix(f) } } ?? allKeys
    Log.debug("total=\(allKeys.count) filtered=\(filtered.count)")
    print("Keys: \(filtered.count)\(filter.map { " (filter: \($0))" } ?? "")")
    for key in filtered {
      let value = try? await client.readKey(key)
      print("  \(key) = \(value.map { String($0) } ?? "?")")
    }
    Log.debug("END")
  }

  static func printUsage() {
    print("Usage: smcfan <command> [args...]")
    print("")
    print("Commands:")
    print("  list              List all fans with current status (default)")
    print("  set <fan> <rpm>   Set fan speed to specified RPM")
    print("  auto <fan>        Return fan to automatic control")
    print("  read <key>        Read value of SMC key")
    print("  keys [prefix]     Enumerate all SMC keys (optionally filter by prefix)")
    print("  help, -h, --help  Show this help message")
  }
}
