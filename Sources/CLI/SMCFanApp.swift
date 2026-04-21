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

/// Parsed CLI invocation: a command and its positional arguments, plus
/// backend selection flags.
struct CLIInvocation {
  var command: String?
  var positional: [String] = []
  var direct: Bool = false
  var priority: Int = 100
}

func parseCLI(_ argv: [String]) -> CLIInvocation {
  var inv = CLIInvocation()
  var i = 1
  while i < argv.count {
    let arg = argv[i]
    switch arg {
    case "--direct":
      inv.direct = true
    case "--via-smcd":
      inv.direct = false
    case "--priority":
      if i + 1 < argv.count, let value = Int(argv[i + 1]) {
        inv.priority = value
        i += 1
      } else {
        CLIOut.err("Missing integer value for --priority")
        exit(2)
      }
    default:
      if inv.command == nil {
        inv.command = arg
      } else {
        inv.positional.append(arg)
      }
    }
    i += 1
  }
  return inv
}

@main
struct SMCFan {
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
        try await Commands.list(direct: inv.direct, priority: inv.priority)

      case "set":
        guard inv.positional.count >= 2,
              let fan = Int(inv.positional[0]),
              let rpm = Float(inv.positional[1])
        else {
          CLIOut.err("Usage: smcfan set <fan> <rpm>")
          exit(1)
        }
        try await Commands.set(fan: fan, rpm: rpm, direct: inv.direct, priority: inv.priority)

      case "auto":
        guard inv.positional.count >= 1, let fan = Int(inv.positional[0]) else {
          CLIOut.err("Usage: smcfan auto <fan>")
          exit(1)
        }
        try await Commands.auto(fan: fan, direct: inv.direct, priority: inv.priority)

      case "read":
        guard inv.positional.count >= 1 else {
          CLIOut.err("Usage: smcfan read <key>")
          exit(1)
        }
        try await Commands.read(key: inv.positional[0], direct: inv.direct, priority: inv.priority)

      case "keys":
        let filter = inv.positional.first
        try await Commands.keys(filter: filter, direct: inv.direct, priority: inv.priority)

      case "sensors":
        try await Commands.sensors(direct: inv.direct, priority: inv.priority)

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
