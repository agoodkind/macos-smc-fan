//
//  SMCFanHelperApp.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import AppLog
import Foundation

@main
struct SMCFanHelperMain {
    static func main() {
        AppLog.bootstrap(subsystem: "io.goodkind.fan")
        BuildInfo.commit = generatedGitCommit
        BuildInfo.version = generatedGitVersion
        BuildInfo.dirty = generatedGitDirty
        autoreleasepool {
            let helper = SMCFanHelper()
            helper.start()
        }
    }
}
