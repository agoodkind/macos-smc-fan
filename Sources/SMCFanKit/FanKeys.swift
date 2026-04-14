//
//  FanKeys.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-14.
//  Copyright © 2026
//

import Foundation
import SMCKit

// MARK: - Fan Key Constants

/// Well-known SMC keys for fan control
public enum SMCFanKey {
  public static let count = "FNum"
  public static let actual = "F%dAc"
  public static let target = "F%dTg"
  public static let minimum = "F%dMn"
  public static let maximum = "F%dMx"
  public static let forceTest = "Ftst"

  // Mode key casing varies across hardware generations.
  // Probed at runtime; see SMCHardwareConfig.
  public static let modeLower = "F%dmd"
  public static let modeUpper = "F%dMd"

  /// Format a fan key template with the fan index
  /// - Parameters:
  ///   - template: The key template (e.g., "F%dAc")
  ///   - fan: The fan index
  /// - Returns: The formatted key (e.g., "F0Ac")
  public static func key(_ template: String, fan: Int) -> String {
    String(format: template, fan)
  }
}
