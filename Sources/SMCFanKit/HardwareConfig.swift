//
//  HardwareConfig.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-14.
//  Copyright © 2026
//

import Foundation
import Logging
import SMCKit

// MARK: - Hardware Configuration

/// Hardware-specific SMC key configuration, detected at runtime.
public struct SMCHardwareConfig {
  /// The format string for the mode key (either "F%dmd" or "F%dMd" depending on hardware)
  public let modeKeyFormat: String

  /// Whether the Ftst (force test) key is available on this hardware
  public let ftstAvailable: Bool

  /// Initialize with explicit values
  public init(modeKeyFormat: String, ftstAvailable: Bool) {
    self.modeKeyFormat = modeKeyFormat
    self.ftstAvailable = ftstAvailable
  }
}

// MARK: - Hardware Detection

extension SMCHardwareConfig {
  /// Detect hardware-specific SMC key configuration by probing the connection.
  ///
  /// Probes mode key casing (lowercase vs uppercase 'd') and Ftst availability.
  /// Uses the provided connection to read test keys and determine hardware capabilities.
  ///
  /// - Parameter connection: An open SMCConnection to probe
  /// - Returns: A configured SMCHardwareConfig for the detected hardware
  /// - Throws: SMCError if hardware detection fails (though detection attempts graceful fallback)
  public static func detectHardwareKeys(connection: SMCConnection, logger: Logging.Logger = Logging.Logger(label: "com.smcfankit.fan")) throws -> SMCHardwareConfig {
    // Probe mode key casing
    var modeKey = SMCFanKey.modeLower
    for candidate in [SMCFanKey.modeLower, SMCFanKey.modeUpper] {
      let testKey = SMCFanKey.key(candidate, fan: 0)
      if let (_, size) = try? connection.readKey(testKey), size > 0 {
        logger.debug("mode key probe: \(testKey) -> found (size=\(size)), using format '\(candidate)'")
        modeKey = candidate
        break
      } else {
        logger.debug("mode key probe: \(testKey) -> not found")
      }
    }

    // Probe Ftst availability
    var ftst = false
    if let (_, size) = try? connection.readKey(SMCFanKey.forceTest), size > 0 {
      logger.debug("Ftst probe: found (size=\(size))")
      ftst = true
    } else {
      logger.debug("Ftst probe: not found")
    }

    logger.debug("detected config: modeKeyFormat='\(modeKey)' ftstAvailable=\(ftst)")
    return SMCHardwareConfig(modeKeyFormat: modeKey, ftstAvailable: ftst)
  }
}
