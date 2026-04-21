//
//  ArbitrationTests.swift
//  SMCDCoreTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//
//  Unit tests for SMCDController.decideClaim. Priority arbitration and
//  ownership TTL are pure logic and require no running helper.
//

import Foundation
import SMCFanXPCClient
import Testing
@testable import SMCDCore

@Suite("SMCDController arbitration")
struct ArbitrationTests {
  // Synthetic client identifiers for tests. Any reference type produces a
  // stable ObjectIdentifier.
  final class Token {}

  private func makeController(ownerTTL: TimeInterval = 10) throws -> SMCDController {
    // SMCFanXPCClient init is lazy. It does not open the NSXPCConnection
    // until the first call, so tests can construct one without a running
    // smcfanhelper.
    let helper = try SMCFanXPCClient()
    return SMCDController(helper: helper, ownerTTL: ownerTTL)
  }

  @Test("first claim on an idle fan is accepted")
  func firstClaimAccepted() throws {
    let c = try self.makeController()
    let tok = Token()
    let id = ObjectIdentifier(tok)
    c.registerClientName("alpha", for: id)
    let result = c.decideClaim(fan: 0, priority: 10, clientID: id)
    if case .rejected = result { Issue.record("expected acceptance") }
  }

  @Test("tie priority is accepted")
  func tiePriorityAccepted() throws {
    let c = try self.makeController()
    let a = Token()
    let b = Token()
    let aID = ObjectIdentifier(a)
    let bID = ObjectIdentifier(b)
    c.registerClientName("alpha", for: aID)
    c.registerClientName("beta", for: bID)
    _ = c.decideClaim(fan: 0, priority: 10, clientID: aID)
    let result = c.decideClaim(fan: 0, priority: 10, clientID: bID)
    if case .rejected = result { Issue.record("tie priority must be accepted") }
  }

  @Test("lower priority is rejected while owner is active")
  func lowerRejected() throws {
    let c = try self.makeController()
    let owner = Token()
    let other = Token()
    let ownerID = ObjectIdentifier(owner)
    let otherID = ObjectIdentifier(other)
    c.registerClientName("owner", for: ownerID)
    c.registerClientName("other", for: otherID)
    _ = c.decideClaim(fan: 0, priority: 50, clientID: ownerID)
    let result = c.decideClaim(fan: 0, priority: 10, clientID: otherID)
    guard case .rejected(let name, let priority) = result else {
      Issue.record("expected rejection")
      return
    }
    #expect(name == "owner")
    #expect(priority == 50)
  }

  @Test("higher priority preempts current owner")
  func higherPreempts() throws {
    let c = try self.makeController()
    let low = Token()
    let high = Token()
    let lowID = ObjectIdentifier(low)
    let highID = ObjectIdentifier(high)
    c.registerClientName("curve", for: lowID)
    c.registerClientName("lmd", for: highID)
    _ = c.decideClaim(fan: 0, priority: 10, clientID: lowID)
    let result = c.decideClaim(fan: 0, priority: 50, clientID: highID)
    if case .rejected = result { Issue.record("higher priority must preempt") }
  }

  @Test("same client can rewrite regardless of priority drop")
  func sameClientRewrites() throws {
    let c = try self.makeController()
    let tok = Token()
    let id = ObjectIdentifier(tok)
    c.registerClientName("self", for: id)
    _ = c.decideClaim(fan: 0, priority: 50, clientID: id)
    let result = c.decideClaim(fan: 0, priority: 20, clientID: id)
    if case .rejected = result { Issue.record("same client must not be rejected") }
  }

  @Test("lower priority accepted after owner TTL lapses")
  func ttlLapse() throws {
    let c = try self.makeController(ownerTTL: 10)
    let owner = Token()
    let other = Token()
    let ownerID = ObjectIdentifier(owner)
    let otherID = ObjectIdentifier(other)
    c.registerClientName("owner", for: ownerID)
    c.registerClientName("other", for: otherID)
    let t0 = Date()
    _ = c.decideClaim(fan: 0, priority: 50, clientID: ownerID, now: t0)
    let beforeTTL = c.decideClaim(fan: 0, priority: 10, clientID: otherID, now: t0.addingTimeInterval(9))
    if case .accepted = beforeTTL { Issue.record("should still be rejected within TTL") }
    let afterTTL = c.decideClaim(fan: 0, priority: 10, clientID: otherID, now: t0.addingTimeInterval(11))
    if case .rejected = afterTTL { Issue.record("should be accepted after TTL lapse") }
  }

  @Test("unregistered clients still get arbitrated")
  func unregisteredWorks() throws {
    let c = try self.makeController()
    let a = Token()
    let aID = ObjectIdentifier(a)
    // Do not register a name. The decision must still apply.
    let result = c.decideClaim(fan: 0, priority: 10, clientID: aID)
    if case .rejected = result { Issue.record("first unregistered claim should succeed") }
  }
}
