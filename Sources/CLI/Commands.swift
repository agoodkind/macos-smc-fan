//
//  Commands.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import AppLog
import Foundation
import SMCFanKit
import SMCFanProtocol
import SMCFanXPCClient

private let log = AppLog.make(category: "XPCClient")

private func makeClient(priority: Int) throws -> SMCFanXPCClient {
  try SMCFanXPCClient(clientName: "smcfan-cli", defaultPriority: priority)
}

enum Commands {

  static func list(priority: Int) async throws {
    let client = try makeClient(priority: priority)
    try await client.open()

    let count = try await client.getFanCount()
    CLIOut.print("Fans: \(count)")

    for i in 0..<count {
      let info = try await client.getFanInfo(i)
      CLIOut.print(
        "Fan \(i): \(Int(info.actualRPM)) RPM (Target: \(Int(info.targetRPM)), Min: \(Int(info.minRPM)), Max: \(Int(info.maxRPM)), Mode: \(info.manualMode ? "Manual" : "Auto"))"
      )
    }

    let temps = await readSensors(client: client, type: .temperature)
    if !temps.isEmpty {
      let summary = temps.map { "\($0.sensor.key): \(String(format: "%.1f", $0.value))C" }
        .joined(separator: ", ")
      CLIOut.print("Temps: \(summary)")
    }
  }

  static func sensors(priority: Int) async throws {
    let client = try makeClient(priority: priority)
    try await client.open()

    let allKeys = SensorCatalog.keysForCurrentHardware()
    var readings: [(sensor: SensorKey, value: Float)] = []

    for sensor in allKeys {
      if let value = try? await client.readKey(sensor.key), value != 0 {
        readings.append((sensor, value))
      }
    }

    if readings.isEmpty {
      CLIOut.print("No sensors found.")
      return
    }

    let grouped = Dictionary(grouping: readings, by: { $0.sensor.type })

    for type in [SensorType.temperature, .voltage, .power, .current] {
      guard let sensors = grouped[type], !sensors.isEmpty else { continue }
      CLIOut.print("\n\(type.rawValue):")
      let byGroup = Dictionary(grouping: sensors, by: { $0.sensor.group })
      for group in [SensorGroup.cpu, .gpu, .memory, .system] {
        guard let items = byGroup[group], !items.isEmpty else { continue }
        CLIOut.print("  \(group.rawValue):")
        for item in items {
          let unit: String
          switch item.sensor.type {
          case .temperature: unit = "C"
          case .voltage: unit = "V"
          case .power: unit = "W"
          case .current: unit = "A"
          }
          CLIOut.print("    \(item.sensor.key) \(item.sensor.name): \(String(format: "%.2f", item.value)) \(unit)")
        }
      }
    }
  }

  static func set(fan: Int, rpm: Float, priority: Int) async throws {
    log.debug(
      "fan.set.start fan=\(fan, privacy: .public) rpm=\(Int(rpm), privacy: .public) priority=\(priority, privacy: .public)"
    )
    let client = try makeClient(priority: priority)
    try await client.setFanRPM(UInt(fan), rpm: rpm)
    CLIOut.print("Set fan \(fan) to \(Int(rpm)) RPM")
  }

  static func auto(fan: Int, priority: Int) async throws {
    log.debug(
      "fan.auto.start fan=\(fan, privacy: .public) priority=\(priority, privacy: .public)"
    )
    let client = try makeClient(priority: priority)
    try await client.setFanAuto(UInt(fan))
    CLIOut.print("Set fan \(fan) to auto mode")
  }

  static func read(key: String, priority: Int) async throws {
    let client = try makeClient(priority: priority)
    try await client.open()
    let value = try await client.readKey(key)
    CLIOut.print("\(key) = \(value)")
  }

  static func keys(filter: String? = nil, priority: Int) async throws {
    let client = try makeClient(priority: priority)
    try await client.open()
    let allKeys = await client.enumerateKeys()
    let filtered = filter.map { f in allKeys.filter { $0.hasPrefix(f) } } ?? allKeys
    log.debug(
      "smc.keys.enumerated total=\(allKeys.count, privacy: .public) matching=\(filtered.count, privacy: .public)"
    )
    CLIOut.print("Keys: \(filtered.count)\(filter.map { " (filter: \($0))" } ?? "")")
    for key in filtered {
      let value = try? await client.readKey(key)
      CLIOut.print("  \(key) = \(value.map { String($0) } ?? "?")")
    }
  }

  /// Live view of the helper's arbitration state. Shows which client
  /// owns each fan, at what priority, and how long ago they last wrote.
  static func owners(priority: Int) async throws {
    let client = try makeClient(priority: priority)
    let rows = try await client.getOwnership()
    if rows.isEmpty {
      CLIOut.print("No fans currently claimed.")
      return
    }
    CLIOut.print("Fan  Client                Priority  Age")
    for row in rows {
      let name = row.clientName.padding(toLength: 20, withPad: " ", startingAt: 0)
      let age = String(format: "%.1fs", row.secondsSinceLastWrite)
      CLIOut.print(
        "\(row.fanIndex)    \(name)  \(row.priority)        \(age)"
      )
    }
  }

  static func printUsage() {
    CLIOut.print("Usage: smcfan [global flags] <command> [args...]")
    CLIOut.print("")
    CLIOut.print("Commands:")
    CLIOut.print("  list              List all fans with current status and temps")
    CLIOut.print("  sensors           Show all available sensor readings")
    CLIOut.print("  set <fan> <rpm>   Set fan speed to specified RPM")
    CLIOut.print("  auto <fan>        Return fan to automatic control")
    CLIOut.print("  read <key>        Read value of SMC key")
    CLIOut.print("  keys [prefix]     Enumerate all SMC keys (optionally filter by prefix)")
    CLIOut.print("  owners            Show which client currently owns each fan")
    CLIOut.print("  help, -h, --help  Show this help message")
    CLIOut.print("")
    CLIOut.print("Global flags:")
    CLIOut.print("  --priority <N>    Priority for writes (default 100, preempts lmd and fancurve)")
  }

  // MARK: - Helpers

  private static func readSensors(
    client: SMCFanXPCClient, type: SensorType
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
