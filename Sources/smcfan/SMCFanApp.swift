//
//  SMCFanApp.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCCommon

@main
struct SMCFan {
  static func main() async {
    let args = CommandLine.arguments

    // Default to list if no command
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
          print("Usage: smcfan set <fan> <rpm>")
          exit(1)
        }
        try await Commands.set(fan: fan, rpm: rpm)

      case "auto":
        guard args.count >= 3, let fan = Int(args[2]) else {
          print("Usage: smcfan auto <fan>")
          exit(1)
        }
        try await Commands.auto(fan: fan)

      case "read":
        guard args.count >= 3 else {
          print("Usage: smcfan read <key>")
          exit(1)
        }
        try await Commands.read(key: args[2])

      case "-h", "--help", "help":
        Commands.printUsage()

      default:
        Commands.printUsage()
        exit(1)
      }
    } catch {
      Log.error(error.localizedDescription)
      exit(1)
    }
  }
}
