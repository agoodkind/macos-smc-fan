//
//  SMCFanHelperApp.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCFanLogging

@main
struct SMCFanHelperMain {
  static func main() {
    BuildInfo.commit = generatedGitCommit
    BuildInfo.version = generatedGitVersion
    BuildInfo.dirty = generatedGitDirty
    LogBootstrap.configure(
      subsystem: SMCFanConfiguration.default.helperBundleID,
      extraHandlers: [XPCRelayLogHandler()]
    )
    autoreleasepool {
      let helper = SMCFanHelper()
      helper.start()
    }
  }
}
