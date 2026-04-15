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
    LogBootstrap.configure(subsystem: SMCFanConfiguration.default.helperBundleID)
    autoreleasepool {
      let helper = SMCFanHelper()
      helper.start()
    }
  }
}
