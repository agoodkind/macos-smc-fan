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
    AppLog.bootstrap(subsystem: "io.goodkind.fan")
    BuildInfo.commit = generatedGitCommit
    BuildInfo.version = generatedGitVersion
    BuildInfo.dirty = generatedGitDirty
    autoreleasepool {
      let helper = SMCFanHelper(machServiceName: SMCFanConfiguration.default.helperBundleID)
      helper.start()
    }
  }
}
