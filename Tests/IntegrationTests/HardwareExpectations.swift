//
//  HardwareExpectations.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-15.
//  Copyright © 2026
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

enum BelowMinBehavior: String, Codable, Sendable {
  /// Firmware preserves the exact target value written (e.g., Target: 1000)
  case preserved
  /// Firmware clamps target to hardware minimum (e.g., Target: 2317)
  case clampedToMin
}

enum AutoModeTargetBehavior: String, Codable, Sendable {
  /// Target shows 0 (system control)
  case zero
  /// Target shows the hardware min RPM (thermalmonitord sets it)
  case minRPM
  /// Either 0 or min RPM depending on thermal state
  case zeroOrMinRPM
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
      decoding: model.prefix(while: { $0 != 0 }).map { UInt8($0) },
      as: UTF8.self
    )
  }
}
