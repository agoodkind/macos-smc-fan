//
//  SMCFanHelper+BatchRead.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//

import SMCFanKit
import SMCKit

// MARK: - Batch key read

extension SMCFanHelper {
  /// Reads multiple SMC keys in a single XPC round trip. See
  /// `SMCFanHelperProtocol.smcReadKeys` for the reply array contract: three
  /// arrays the same length as `keys`, one entry per requested key.
  ///
  /// Internal rather than public because this repo's lint configuration
  /// enables both `extension_access_modifier` and its inverse, so no public
  /// member can satisfy both inside an extension. `SMCFanHelper` keeps the
  /// public protocol method and delegates here.
  func batchReadKeys(_ keys: [String], reply: ([Bool], [Float], [String]) -> Void) {
    var successes: [Bool] = []
    var values: [Float] = []
    var errors: [String] = []
    successes.reserveCapacity(keys.count)
    values.reserveCapacity(keys.count)
    errors.reserveCapacity(keys.count)

    do {
      try ensureConnected()
    } catch {
      log.error(
        "smc.keys.read.connect.failed error=\(error.localizedDescription, privacy: .public)"
      )
      reply(
        [Bool](repeating: false, count: keys.count),
        [Float](repeating: 0, count: keys.count),
        [String](repeating: error.localizedDescription, count: keys.count)
      )
      return
    }

    guard let fanController else {
      reply(
        [Bool](repeating: false, count: keys.count),
        [Float](repeating: 0, count: keys.count),
        [String](repeating: "Connection not established", count: keys.count)
      )
      return
    }

    var failedCount = 0
    for key in keys {
      do {
        let (value, size) = try fanController.connection.readKey(key)
        values.append(SMCDataFormat.float(from: value, size: size))
        successes.append(true)
        errors.append("")
      } catch {
        // Deliberately not logged per key. The per-key reply already carries
        // the reason, and per-key logging on this path is what produced
        // 49,030 log lines an hour in the consuming agent.
        failedCount += 1
        successes.append(false)
        values.append(0)
        errors.append(error.localizedDescription)
        continue
      }
    }

    log.debug(
      "smc.keys.read count=\(keys.count, privacy: .public) failed=\(failedCount, privacy: .public)"
    )
    reply(successes, values, errors)
  }
}
