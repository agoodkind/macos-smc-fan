//
//  FanCLIClient.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-21.
//  Copyright © 2026
//
//  CLI level abstraction that hides which backend the CLI is talking to.
//  The same command surface works whether the user wants arbitrated writes
//  through `smcd` (default) or a direct diagnostic bypass through the
//  privileged helper (`--direct`).
//

import AppLog
import Foundation
import SMCDClient
import SMCFanProtocol
import SMCFanXPCClient

private let log = AppLog.make(category: "XPCClient")

/// Unified read + write surface used by every CLI command. Both concrete
/// backends satisfy this protocol.
protocol FanCLIClient: Sendable {
  func getFanCount() async throws -> UInt
  func getFanInfo(_ index: UInt) async throws -> FanInfo
  func setFanRPM(_ index: UInt, rpm: Float) async throws
  func setFanAuto(_ index: UInt) async throws
  func readKey(_ key: String) async throws -> Float
  func enumerateKeys() async -> [String]
}

extension SMCFanXPCClient: FanCLIClient {}
extension SMCDClient: FanCLIClient {}

/// Selects the backend for the current CLI invocation and returns a ready
/// to use client. The direct path opens the privileged SMC session; the
/// smcd path lets the arbiter manage that.
func makeCLIClient(direct: Bool, priority: Int) async throws -> FanCLIClient {
  if direct {
    log.debug("cli.backend backend=direct priority=n/a")
    let client = try SMCFanXPCClient()
    try await client.open()
    return client
  }
  log.debug("cli.backend backend=smcd priority=\(priority, privacy: .public)")
  return SMCDClient(clientName: "smcfan-cli", defaultPriority: priority)
}
