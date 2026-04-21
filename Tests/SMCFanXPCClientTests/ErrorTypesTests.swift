//
//  ErrorTypesTests.swift
//  SMCFanXPCClientTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//

import Testing
@testable import SMCFanXPCClient

@Suite("SMCFanXPCClient error types")
struct ErrorTypesTests {
  @Test("SMCXPCError carries message")
  func xpcErrorMessage() {
    let err = SMCXPCError("something went wrong")
    #expect(err.errorDescription == "something went wrong")
  }

  @Test("SMCXPCError defaults when nil")
  func xpcErrorNil() {
    let err = SMCXPCError(nil)
    #expect(err.errorDescription == "Unknown error")
  }

  @Test("SMCXPCTimeoutError formats seconds")
  func timeoutFormatting() {
    let err = SMCXPCTimeoutError(label: "setFanRPMSync[1]", seconds: 5.0)
    #expect(err.errorDescription == "SMC setFanRPMSync[1] timed out after 5.0s")
  }
}
