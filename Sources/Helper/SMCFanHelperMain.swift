//
//  SMCFanHelperMain.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026, all rights reserved.
//

import AppLog
import Foundation
import SMCFanHelperCore

@main
enum SMCFanHelperMain {
  static func main() {
    BuildInfo.version = generatedMarketingVersion
    BuildInfo.build = generatedBuildNumber
    BuildInfo.commit = generatedGitCommit
    BuildInfo.dirty = generatedGitDirty
    AppLog.bootstrap(subsystem: "io.goodkind.fan")
    autoreleasepool {
      let helper = SMCFanHelper(machServiceName: SMCFanConfiguration.default.helperBundleID)
      helper.start()
    }
  }
}
