//
//  SMCFan.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026, all rights reserved.
//

import AppLog
import Foundation
import SMCFanProtocol

private let log = AppLog.make(category: "XPCClient")

/// Exit code used for CLI usage errors such as a missing argument value.
private let usageErrorExitCode: Int32 = 2
/// The `set` command requires a fan index and an RPM target.
private let setCommandArgumentCount = 2

/// Parsed CLI invocation: a command, its positional arguments, and the
/// write priority (default high so ad hoc CLI writes preempt daemons).
struct CLIInvocation {
  var command: String?
  var positional: [String] = []
  var priority: Int = 100
}

func parseCLI(_ argv: [String]) -> CLIInvocation {
  var inv = CLIInvocation()
  var argIndex = 1
  while argIndex < argv.count {
    let arg = argv[argIndex]
    switch arg {
    case "--priority":
      if argIndex + 1 < argv.count, let value = Int(argv[argIndex + 1]) {
        inv.priority = value
        argIndex += 1
      } else {
        CLIOut.err("Missing integer value for --priority")
        exit(usageErrorExitCode)
      }
    default:
      if inv.command == nil {
        inv.command = arg
      } else {
        inv.positional.append(arg)
      }
    }
    argIndex += 1
  }
  return inv
}

@main
enum SMCFan {
  static func main() async {
    AppLog.bootstrap(subsystem: "io.goodkind.fan")
    BuildInfo.commit = generatedGitCommit
    BuildInfo.version = generatedGitVersion
    BuildInfo.dirty = generatedGitDirty

    let inv = parseCLI(CommandLine.arguments)
    let command = inv.command ?? "list"

    do {
      switch command {
      case "list":
        try await Commands.list(priority: inv.priority)

      case "set":
        guard inv.positional.count >= setCommandArgumentCount,
              let fan = Int(inv.positional[0]),
              let rpm = Float(inv.positional[1])
        else {
          CLIOut.err("Usage: smcfan set <fan> <rpm>")
          exit(1)
        }
        try await Commands.set(fan: fan, rpm: rpm, priority: inv.priority)

      case "auto":
        guard inv.positional.count >= 1, let fan = Int(inv.positional[0]) else {
          CLIOut.err("Usage: smcfan auto <fan>")
          exit(1)
        }
        try await Commands.auto(fan: fan, priority: inv.priority)

      case "read":
        guard inv.positional.count >= 1 else {
          CLIOut.err("Usage: smcfan read <key>")
          exit(1)
        }
        try await Commands.read(key: inv.positional[0], priority: inv.priority)

      case "keys":
        let filter = inv.positional.first
        try await Commands.keys(priority: inv.priority, filter: filter)

      case "sensors":
        try await Commands.sensors(priority: inv.priority)

      case "owners":
        try await Commands.owners(priority: inv.priority)

      case "-h", "--help", "help":
        Commands.printUsage()

      default:
        Commands.printUsage()
        exit(1)
      }
    } catch {
      log.error(
        "command.failed command=\(command, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      CLIOut.err("Error: \(error.localizedDescription)")
      exit(1)
    }
  }
}
