//
//  Config.swift
//  SMCFanApp
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation

/// Configuration for SMC Fan Control
public struct SMCFanConfiguration: Sendable {
  /// Bundle identifier for the XPC helper service
  public let helperBundleID: String

  public init(helperBundleID: String) {
    self.helperBundleID = helperBundleID
  }

  /// Default configuration, populated from build settings via Config.generated.swift
  public static let `default` = SMCFanConfiguration(
    helperBundleID: generatedHelperBundleID
  )
}
