//
//  ReadKeysTests.swift
//  SMCFanXPCClientTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-07-27.
//  Copyright © 2026, all rights reserved.
//
//  Unit tests for the reply-array contract `readKeys` enforces before
//  pairing each requested key with its result. No live helper is needed:
//  `buildKeyReadResults` is the pure pairing/validation step pulled out of
//  the XPC reply closure.
//

import Testing

@testable import SMCFanXPCClient

@Suite("SMCFanXPCClient.readKeys contract")
struct ReadKeysTests {
  @Test("matching array lengths pair each key with its result in order")
  func matchingLengthsPairInOrder() throws {
    let results = try SMCFanXPCClient.buildKeyReadResults(
      keys: ["FNum", "F0Ac"],
      successes: [true, false],
      values: [3, 0],
      errors: ["", "key not found"]
    )

    #expect(results.map(\.key) == ["FNum", "F0Ac"])
    #expect(results[0].success)
    #expect(results[0].value == 3)
    #expect(results[0].error.isEmpty)
    #expect(!results[1].success)
    #expect(results[1].error == "key not found")
  }

  @Test("a short reply throws instead of silently truncating")
  func shortReplyThrows() {
    #expect(throws: SMCXPCError.self) {
      _ = try SMCFanXPCClient.buildKeyReadResults(
        keys: ["FNum", "F0Ac", "F0Mn"],
        successes: [true, false],
        values: [3, 0],
        errors: ["", "key not found"]
      )
    }
  }

  @Test("a long reply throws instead of silently ignoring the extra entries")
  func longReplyThrows() {
    #expect(throws: SMCXPCError.self) {
      _ = try SMCFanXPCClient.buildKeyReadResults(
        keys: ["FNum"],
        successes: [true, false],
        values: [3, 0],
        errors: ["", ""]
      )
    }
  }
}
