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
  /// Bundle identifier for the privileged SMC XPC helper (LaunchDaemon).
  public let helperBundleID: String
  /// Bundle identifier for the user space smcd arbiter LaunchAgent.
  public let smcdBundleID: String

  public init(helperBundleID: String, smcdBundleID: String = "io.goodkind.smcd") {
    self.helperBundleID = helperBundleID
    self.smcdBundleID = smcdBundleID
  }

  /// Default configuration, populated from build settings via Config.generated.swift
  public static let `default` = SMCFanConfiguration(
    helperBundleID: generatedHelperBundleID
  )
}
