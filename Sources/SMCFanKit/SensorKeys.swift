//
//  SensorKeys.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-15.
//  Copyright © 2026
//

import Foundation

// MARK: - Sensor Types

public enum SensorGroup: String, Sendable {
  case cpu = "CPU"
  case gpu = "GPU"
  case system = "System"
  case memory = "Memory"
}

public enum SensorType: String, Sendable {
  case temperature = "Temperature"
  case voltage = "Voltage"
  case power = "Power"
  case current = "Current"
}

// MARK: - Sensor Definition

public struct SensorKey: Sendable {
  public let key: String
  public let name: String
  public let group: SensorGroup
  public let type: SensorType

  public init(key: String, name: String, group: SensorGroup, type: SensorType) {
    self.key = key
    self.name = name
    self.group = group
    self.type = type
  }
}

// MARK: - Sensor Catalog

public enum SensorCatalog {

  // MARK: Cross-Platform (Intel + Apple Silicon)

  public static let crossPlatform: [SensorKey] = [
    // CPU
    SensorKey(key: "TC0D", name: "CPU diode", group: .cpu, type: .temperature),
    SensorKey(key: "TC0E", name: "CPU virtual", group: .cpu, type: .temperature),
    SensorKey(key: "TC0F", name: "CPU filtered", group: .cpu, type: .temperature),
    SensorKey(key: "TC0H", name: "CPU heatsink", group: .cpu, type: .temperature),
    SensorKey(key: "TC0P", name: "CPU proximity", group: .cpu, type: .temperature),
    SensorKey(key: "TCAD", name: "CPU package", group: .cpu, type: .temperature),

    // GPU
    SensorKey(key: "TCGC", name: "GPU Intel Graphics", group: .gpu, type: .temperature),
    SensorKey(key: "TG0D", name: "GPU diode", group: .gpu, type: .temperature),
    SensorKey(key: "TG0H", name: "GPU heatsink", group: .gpu, type: .temperature),
    SensorKey(key: "TG0P", name: "GPU proximity", group: .gpu, type: .temperature),

    // System
    SensorKey(key: "Tm0P", name: "Mainboard", group: .system, type: .temperature),
    SensorKey(key: "TW0P", name: "Airport", group: .system, type: .temperature),
    SensorKey(key: "TL0P", name: "Display", group: .system, type: .temperature),
    SensorKey(key: "Ts0P", name: "System sensor 1", group: .system, type: .temperature),
    SensorKey(key: "Ts1P", name: "System sensor 2", group: .system, type: .temperature),
    SensorKey(key: "TN0D", name: "Northbridge diode", group: .system, type: .temperature),
    SensorKey(key: "TN0H", name: "Northbridge heatsink", group: .system, type: .temperature),
    SensorKey(key: "TB1T", name: "Battery", group: .system, type: .temperature),

    // Voltage
    SensorKey(key: "VCAC", name: "CPU IA", group: .cpu, type: .voltage),
    SensorKey(key: "VCSC", name: "CPU System Agent", group: .cpu, type: .voltage),
    SensorKey(key: "VG0C", name: "GPU", group: .gpu, type: .voltage),
    SensorKey(key: "VM0R", name: "Memory", group: .memory, type: .voltage),
    SensorKey(key: "VD0R", name: "DC In", group: .system, type: .voltage),

    // Power
    SensorKey(key: "PC0C", name: "CPU Core", group: .cpu, type: .power),
    SensorKey(key: "PCPC", name: "CPU Package", group: .cpu, type: .power),
    SensorKey(key: "PCTR", name: "CPU Total", group: .cpu, type: .power),
    SensorKey(key: "PG0C", name: "GPU", group: .gpu, type: .power),
    SensorKey(key: "PSTR", name: "System Total", group: .system, type: .power),
    SensorKey(key: "PPBR", name: "Battery", group: .system, type: .power),
    SensorKey(key: "PDTR", name: "DC In", group: .system, type: .power),

    // Current
    SensorKey(key: "IC0R", name: "CPU", group: .cpu, type: .current),
    SensorKey(key: "IG0R", name: "GPU", group: .gpu, type: .current),
    SensorKey(key: "ID0R", name: "DC In", group: .system, type: .current),
    SensorKey(key: "IBAC", name: "Battery", group: .system, type: .current),
  ]

  // MARK: M1 Generation

  public static let m1: [SensorKey] = [
    SensorKey(key: "Tp09", name: "CPU E-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0T", name: "CPU E-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp01", name: "CPU P-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp05", name: "CPU P-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0D", name: "CPU P-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0H", name: "CPU P-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0L", name: "CPU P-core 5", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0P", name: "CPU P-core 6", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0X", name: "CPU P-core 7", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0b", name: "CPU P-core 8", group: .cpu, type: .temperature),
    SensorKey(key: "Tg05", name: "GPU 1", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0D", name: "GPU 2", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0L", name: "GPU 3", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0T", name: "GPU 4", group: .gpu, type: .temperature),
    SensorKey(key: "Tm02", name: "Memory 1", group: .memory, type: .temperature),
    SensorKey(key: "Tm06", name: "Memory 2", group: .memory, type: .temperature),
    SensorKey(key: "Tm08", name: "Memory 3", group: .memory, type: .temperature),
    SensorKey(key: "Tm09", name: "Memory 4", group: .memory, type: .temperature),
  ]

  // MARK: M2 Generation

  public static let m2: [SensorKey] = [
    SensorKey(key: "Tp1h", name: "CPU E-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp1t", name: "CPU E-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp1p", name: "CPU E-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tp1l", name: "CPU E-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp01", name: "CPU P-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp05", name: "CPU P-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp09", name: "CPU P-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0D", name: "CPU P-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0X", name: "CPU P-core 5", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0b", name: "CPU P-core 6", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0f", name: "CPU P-core 7", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0j", name: "CPU P-core 8", group: .cpu, type: .temperature),
    SensorKey(key: "Tg0f", name: "GPU 1", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0j", name: "GPU 2", group: .gpu, type: .temperature),
  ]

  // MARK: M3 Generation

  public static let m3: [SensorKey] = [
    SensorKey(key: "Te05", name: "CPU E-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Te0L", name: "CPU E-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Te0P", name: "CPU E-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Te0S", name: "CPU E-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tf04", name: "CPU P-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tf09", name: "CPU P-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tf0A", name: "CPU P-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tf0B", name: "CPU P-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tf0D", name: "CPU P-core 5", group: .cpu, type: .temperature),
    SensorKey(key: "Tf0E", name: "CPU P-core 6", group: .cpu, type: .temperature),
    SensorKey(key: "Tf44", name: "CPU P-core 7", group: .cpu, type: .temperature),
    SensorKey(key: "Tf49", name: "CPU P-core 8", group: .cpu, type: .temperature),
    SensorKey(key: "Tf4A", name: "CPU P-core 9", group: .cpu, type: .temperature),
    SensorKey(key: "Tf4B", name: "CPU P-core 10", group: .cpu, type: .temperature),
    SensorKey(key: "Tf4D", name: "CPU P-core 11", group: .cpu, type: .temperature),
    SensorKey(key: "Tf4E", name: "CPU P-core 12", group: .cpu, type: .temperature),
    SensorKey(key: "Tf14", name: "GPU 1", group: .gpu, type: .temperature),
    SensorKey(key: "Tf18", name: "GPU 2", group: .gpu, type: .temperature),
    SensorKey(key: "Tf19", name: "GPU 3", group: .gpu, type: .temperature),
    SensorKey(key: "Tf1A", name: "GPU 4", group: .gpu, type: .temperature),
    SensorKey(key: "Tf24", name: "GPU 5", group: .gpu, type: .temperature),
    SensorKey(key: "Tf28", name: "GPU 6", group: .gpu, type: .temperature),
    SensorKey(key: "Tf29", name: "GPU 7", group: .gpu, type: .temperature),
    SensorKey(key: "Tf2A", name: "GPU 8", group: .gpu, type: .temperature),
  ]

  // MARK: M4 Generation

  public static let m4: [SensorKey] = [
    SensorKey(key: "Te05", name: "CPU E-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Te0S", name: "CPU E-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Te09", name: "CPU E-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Te0H", name: "CPU E-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp01", name: "CPU P-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp05", name: "CPU P-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp09", name: "CPU P-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0D", name: "CPU P-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0V", name: "CPU P-core 5", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0Y", name: "CPU P-core 6", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0b", name: "CPU P-core 7", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0e", name: "CPU P-core 8", group: .cpu, type: .temperature),
    SensorKey(key: "Tg1U", name: "GPU 1", group: .gpu, type: .temperature),
    SensorKey(key: "Tg1k", name: "GPU 2", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0K", name: "GPU 3", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0L", name: "GPU 4", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0d", name: "GPU 5", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0e", name: "GPU 6", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0j", name: "GPU 7", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0k", name: "GPU 8", group: .gpu, type: .temperature),
    SensorKey(key: "Tm0p", name: "Memory 1", group: .memory, type: .temperature),
    SensorKey(key: "Tm1p", name: "Memory 2", group: .memory, type: .temperature),
    SensorKey(key: "Tm2p", name: "Memory 3", group: .memory, type: .temperature),
  ]

  // MARK: M5 Generation

  public static let m5: [SensorKey] = [
    SensorKey(key: "Tp00", name: "CPU S-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp04", name: "CPU S-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp08", name: "CPU S-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0C", name: "CPU S-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0G", name: "CPU S-core 5", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0K", name: "CPU S-core 6", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0O", name: "CPU P-core 1", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0R", name: "CPU P-core 2", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0U", name: "CPU P-core 3", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0X", name: "CPU P-core 4", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0a", name: "CPU P-core 5", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0d", name: "CPU P-core 6", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0g", name: "CPU P-core 7", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0j", name: "CPU P-core 8", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0m", name: "CPU P-core 9", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0p", name: "CPU P-core 10", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0u", name: "CPU P-core 11", group: .cpu, type: .temperature),
    SensorKey(key: "Tp0y", name: "CPU P-core 12", group: .cpu, type: .temperature),
    SensorKey(key: "Tg0U", name: "GPU 1", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0X", name: "GPU 2", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0d", name: "GPU 3", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0g", name: "GPU 4", group: .gpu, type: .temperature),
    SensorKey(key: "Tg0j", name: "GPU 5", group: .gpu, type: .temperature),
    SensorKey(key: "Tg1Y", name: "GPU 6", group: .gpu, type: .temperature),
    SensorKey(key: "Tg1c", name: "GPU 7", group: .gpu, type: .temperature),
    SensorKey(key: "Tg1g", name: "GPU 8", group: .gpu, type: .temperature),
  ]

  /// All platform-specific sensor arrays keyed by hw.model prefix.
  /// The detection logic tries platform-specific keys first, then cross-platform.
  public static func keysForCurrentHardware() -> [SensorKey] {
    let model = hardwareModel()
    let platformKeys: [SensorKey]

    if model.hasPrefix("Mac17") {
      platformKeys = m5
    } else if model.hasPrefix("Mac16") {
      platformKeys = m4
    } else if model.hasPrefix("Mac15") || model.hasPrefix("Mac14") {
      platformKeys = m3
    } else if model.hasPrefix("Mac13") {
      platformKeys = m2
    } else if model.hasPrefix("Mac12") || model.hasPrefix("MacBookPro18") || model.hasPrefix("MacBookAir10") {
      platformKeys = m1
    } else {
      platformKeys = []
    }

    return platformKeys + crossPlatform
  }

  private static func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
  }
}
