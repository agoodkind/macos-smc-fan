//
//  Commands.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCFanKit
import SMCFanLogging

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

    let temps = await readSensors(client: client, type: .temperature)
    if !temps.isEmpty {
      let summary = temps.map { "\($0.sensor.key): \(String(format: "%.1f", $0.value))C" }
        .joined(separator: ", ")
      print("Temps: \(summary)")
    }
  }

  static func sensors() async throws {
    let client = try XPCClient()
    try await client.open()

    let allKeys = SensorCatalog.keysForCurrentHardware()
    var readings: [(sensor: SensorKey, value: Float)] = []

    for sensor in allKeys {
      if let value = try? await client.readKey(sensor.key), value != 0 {
        readings.append((sensor, value))
      }
    }

    if readings.isEmpty {
      print("No sensors found.")
      return
    }

    let grouped = Dictionary(grouping: readings, by: { $0.sensor.type })

    for type in [SensorType.temperature, .voltage, .power, .current] {
      guard let sensors = grouped[type], !sensors.isEmpty else { continue }
      print("\n\(type.rawValue):")
      let byGroup = Dictionary(grouping: sensors, by: { $0.sensor.group })
      for group in [SensorGroup.cpu, .gpu, .memory, .system] {
        guard let items = byGroup[group], !items.isEmpty else { continue }
        print("  \(group.rawValue):")
        for item in items {
          let unit: String
          switch item.sensor.type {
          case .temperature: unit = "C"
          case .voltage: unit = "V"
          case .power: unit = "W"
          case .current: unit = "A"
          }
          print("    \(item.sensor.key) \(item.sensor.name): \(String(format: "%.2f", item.value)) \(unit)")
        }
      }
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
    print("  sensors           Show all available sensor readings")
    print("  set <fan> <rpm>   Set fan speed to specified RPM")
    print("  auto <fan>        Return fan to automatic control")
    print("  read <key>        Read value of SMC key")
    print("  keys [prefix]     Enumerate all SMC keys (optionally filter by prefix)")
    print("  log               Show daemon log file (last 20 lines)")
    print("  help, -h, --help  Show this help message")
  }

  // MARK: - Helpers

  private static func readSensors(
    client: XPCClient, type: SensorType
  ) async -> [(sensor: SensorKey, value: Float)] {
    var results: [(sensor: SensorKey, value: Float)] = []
    for sensor in SensorCatalog.keysForCurrentHardware() where sensor.type == type {
      if let value = try? await client.readKey(sensor.key), value > 0, value < 150 {
        results.append((sensor, value))
      }
    }
    return results
  }
}
