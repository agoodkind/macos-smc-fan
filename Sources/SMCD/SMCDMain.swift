//
//  SMCDMain.swift
//  smcd
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//
//  Entry point for the user space SMC fan arbiter. Owns the single XPC
//  connection to the privileged smcfanhelper via SMCFanXPCClient and
//  hosts an NSXPCListener on the SMCD mach service for user space
//  clients.
//

import AppLog
import Foundation
import SMCDCore
import SMCFanProtocol
import SMCFanXPCClient

private let log = AppLog.make(category: "SMCDMain")

@main
enum SMCDMain {
  static func main() {
    AppLog.bootstrap(subsystem: "io.goodkind.fan")

    let config = SMCFanConfiguration.default
    let helper: SMCFanXPCClient
    do {
      helper = try SMCFanXPCClient()
    } catch {
      log.fault(
        "smcd.helper_client_init_failed error=\(error.localizedDescription, privacy: .public)"
      )
      exit(1)
    }

    let controller = SMCDController(helper: helper)
    let listener = NSXPCListener(machServiceName: config.smcdBundleID)
    listener.delegate = controller
    listener.resume()

    log.notice(
      "smcd.started mach_service=\(config.smcdBundleID, privacy: .public) helper=\(config.helperBundleID, privacy: .public)"
    )

    RunLoop.current.run()
  }
}
