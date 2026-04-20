//
//  SMCFanApp.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import AppLog
import Foundation
import SMCFanProtocol

private let log = AppLog.make(category: "XPCClient")

@main
struct SMCFan {
    static func main() async {
        AppLog.bootstrap(subsystem: "io.goodkind.fan")
        BuildInfo.commit = generatedGitCommit
        BuildInfo.version = generatedGitVersion
        BuildInfo.dirty = generatedGitDirty

        let args = CommandLine.arguments

        guard args.count >= 2 else {
            try? await Commands.list()
            return
        }

        let command = args[1]

        do {
            switch command {
            case "list":
                try await Commands.list()

            case "set":
                guard args.count >= 4,
                    let fan = Int(args[2]),
                    let rpm = Float(args[3])
                else {
                    CLIOut.err("Usage: smcfan set <fan> <rpm>")
                    exit(1)
                }
                try await Commands.set(fan: fan, rpm: rpm)

            case "auto":
                guard args.count >= 3, let fan = Int(args[2]) else {
                    CLIOut.err("Usage: smcfan auto <fan>")
                    exit(1)
                }
                try await Commands.auto(fan: fan)

            case "read":
                guard args.count >= 3 else {
                    CLIOut.err("Usage: smcfan read <key>")
                    exit(1)
                }
                try await Commands.read(key: args[2])

            case "keys":
                try await Commands.keys(filter: args.count >= 3 ? args[2] : nil)

            case "sensors":
                try await Commands.sensors()

            case "-h", "--help", "help":
                Commands.printUsage()

            default:
                Commands.printUsage()
                exit(1)
            }
        } catch {
            log.error("command.failed command=\(command, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            CLIOut.err("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
