//
//  HardwareExpectations.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-15.
//  Copyright © 2026
//

import Foundation

/// Hardware-specific behavioral expectations for integration tests.
/// Each model describes how the SMC firmware actually behaves,
/// which varies across Apple Silicon generations.
///
/// To add a new model:
/// 1. Run `sudo smcfan list` to see fan count, min/max RPM
/// 2. Run `sudo smcfan read F0md` and `sudo smcfan read F0Md` to find mode key casing
/// 3. Run `sudo smcfan read Ftst` to check Ftst availability
/// 4. Run `sudo smcfan set 0 1000` then `sudo smcfan list` to observe below-min behavior
/// 5. Add a new static let below and append to allKnown
struct HardwareExpectations: Sendable {
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
}

enum BelowMinBehavior: Sendable {
  /// Firmware preserves the exact target value written (e.g., Target: 1000)
  case preserved
  /// Firmware clamps target to hardware minimum (e.g., Target: 2317)
  case clampedToMin
}

enum AutoModeTargetBehavior: Sendable {
  /// Target shows 0 (system control)
  case zero
  /// Target shows the hardware min RPM (thermalmonitord sets it)
  case minRPM
  /// Either 0 or min RPM depending on thermal state
  case zeroOrMinRPM
}

extension HardwareExpectations {

  static let m4Max = HardwareExpectations(
    chipName: "M4 Max",
    modelIdentifier: "Mac16,6",
    modeKeyFormat: "F%dMd",
    ftstPresent: true,
    fanCount: 2,
    reportedMinRPM: 2500,
    reportedMaxRPM: 8500,
    belowMinBehavior: .preserved,
    autoModeTarget: .zeroOrMinRPM,
    rpmTolerance: 300
  )

  static let m5Max = HardwareExpectations(
    chipName: "M5 Max",
    modelIdentifier: "Mac17,7",
    modeKeyFormat: "F%dmd",
    ftstPresent: false,
    fanCount: 2,
    reportedMinRPM: 2317,
    reportedMaxRPM: 7826,
    belowMinBehavior: .clampedToMin,
    autoModeTarget: .minRPM,
    rpmTolerance: 200
  )

  static let allKnown: [HardwareExpectations] = [m4Max, m5Max]

  static func detect() -> HardwareExpectations? {
    let model = currentModelIdentifier()
    return allKnown.first { $0.modelIdentifier == model }
  }

  private static func currentModelIdentifier() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(
      decoding: model.prefix(while: { $0 != 0 }).map { UInt8($0) },
      as: UTF8.self
    )
  }

  static var currentModel: String {
    currentModelIdentifier()
  }
}
