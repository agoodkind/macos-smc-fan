//
//  HardwareExpectations.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-15.
//  Copyright © 2026, all rights reserved.
//

import Foundation

/// Hardware-specific behavioral expectations for integration tests.
/// Each model's expectations are stored as a plist in Tests/IntegrationTests/Fixtures/.
///
/// To add a new model:
/// 1. Run `sudo smcfan list` to see fan count, min/max RPM
/// 2. Run `sudo smcfan read F0md` and `sudo smcfan read F0Md` to find mode key casing
/// 3. Run `sudo smcfan read Ftst` to check Ftst availability
/// 4. Run `sudo smcfan set 0 1000` then `sudo smcfan list` to observe below-min behavior
/// 5. Copy an existing plist in Fixtures/, name it with your hw.model (e.g., Mac18,3.plist)
/// 6. Fill in the values and submit a PR
struct HardwareExpectations: Codable, Sendable {
  let chipName: String
  let modelIdentifier: String
  let modeKeyFormat: String
  let ftstPresent: Bool
  let fanCount: Int
  let reportedMinRPM: Int
  let reportedMaxRPM: Int
  let belowMinBehavior: BelowMinBehavior
  let autoModeTarget: AutoModeTargetBehavior
  let rpmTolerance: Int
  let manualWakesOtherFans: Bool
  let rampFromIdleSeconds: TimeInterval
}

/// Decoded from a plist `<string>` whose value is the camelCase case name.
/// Custom Codable keeps that wire format while leaving the enum without a
/// `String` raw type, so the case-name lint rules do not conflict.
enum BelowMinBehavior: Codable, Sendable {
  /// Firmware clamps target to hardware minimum (e.g., Target: 2317)
  case clampedToMin
  /// Firmware preserves the exact target value written (e.g., Target: 1000)
  case preserved

  init(from decoder: any Decoder) throws {
    let wire = try decoder.singleValueContainer().decode(String.self)
    switch wire {
    case "clampedToMin":
      self = .clampedToMin
    case "preserved":
      self = .preserved
    default:
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unknown BelowMinBehavior: \(wire)")
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .clampedToMin:
      try container.encode("clampedToMin")
    case .preserved:
      try container.encode("preserved")
    }
  }
}

/// See `BelowMinBehavior` for why this uses custom Codable instead of a
/// `String` raw type.
enum AutoModeTargetBehavior: Codable, Sendable {
  /// Target shows the hardware min RPM (thermalmonitord sets it)
  case minRPM
  /// Target shows 0 (system control)
  case zero
  /// Either 0 or min RPM depending on thermal state
  case zeroOrMinRPM

  init(from decoder: any Decoder) throws {
    let wire = try decoder.singleValueContainer().decode(String.self)
    switch wire {
    case "minRPM":
      self = .minRPM
    case "zero":
      self = .zero
    case "zeroOrMinRPM":
      self = .zeroOrMinRPM
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Unknown AutoModeTargetBehavior: \(wire)"
        )
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .minRPM:
      try container.encode("minRPM")
    case .zero:
      try container.encode("zero")
    case .zeroOrMinRPM:
      try container.encode("zeroOrMinRPM")
    }
  }
}

extension HardwareExpectations {

  /// Load expectations for the current hardware from the Fixtures directory.
  /// Returns nil if no plist exists for this model.
  static func detect() -> HardwareExpectations? {
    let model = currentModel
    let fixturesDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    let plistURL = fixturesDir.appendingPathComponent("\(model).plist")

    guard FileManager.default.fileExists(atPath: plistURL.path) else {
      return nil
    }

    do {
      let data = try Data(contentsOf: plistURL)
      return try PropertyListDecoder().decode(HardwareExpectations.self, from: data)
    } catch {
      fputs("[HardwareExpectations] Failed to decode \(plistURL.lastPathComponent): \(error)\n", stderr)
      return nil
    }
  }

  static var currentModel: String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(
      bytes: model.prefix { $0 != 0 }.map { UInt8($0) },
      encoding: .utf8
    ) ?? ""
  }
}
