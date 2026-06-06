//
//  FanArbitratorTests.swift
//  SMCFanKitTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-21.
//  Copyright © 2026, all rights reserved.
//
//  Priority arbitration state machine. No XPC, no threads. Tests pass
//  synthetic `ObjectIdentifier`s and compare the returned ClaimDecision.
//

import Foundation
import Testing
@testable import SMCFanKit

@Suite("FanArbitrator")
struct FanArbitratorTests {
  final class Token {}

  private func makeArbitrator(ownerTTL: TimeInterval = 10) -> FanArbitrator {
    FanArbitrator(ownerTTL: ownerTTL)
  }

  @Test("first claim on an idle fan is accepted")
  func firstClaimAccepted() {
    let arbitrator = self.makeArbitrator()
    let tok = Token()
    let id = ObjectIdentifier(tok)
    arbitrator.registerClientName("alpha", for: id)
    let result = arbitrator.decideClaim(fan: 0, priority: 10, clientID: id)
    if case .rejected = result { Issue.record("expected acceptance") }
  }

  @Test("tie priority is accepted")
  func tiePriorityAccepted() {
    let arbitrator = self.makeArbitrator()
    let x = Token()
    let y = Token()
    let xID = ObjectIdentifier(x)
    let yID = ObjectIdentifier(y)
    arbitrator.registerClientName("alpha", for: xID)
    arbitrator.registerClientName("beta", for: yID)
    _ = arbitrator.decideClaim(fan: 0, priority: 10, clientID: xID)
    let result = arbitrator.decideClaim(fan: 0, priority: 10, clientID: yID)
    if case .rejected = result { Issue.record("tie priority must be accepted") }
  }

  @Test("lower priority is rejected while owner is active")
  func lowerRejected() {
    let arbitrator = self.makeArbitrator()
    let owner = Token()
    let other = Token()
    let ownerID = ObjectIdentifier(owner)
    let otherID = ObjectIdentifier(other)
    arbitrator.registerClientName("owner", for: ownerID)
    arbitrator.registerClientName("other", for: otherID)
    _ = arbitrator.decideClaim(fan: 0, priority: 50, clientID: ownerID)
    let result = arbitrator.decideClaim(fan: 0, priority: 10, clientID: otherID)
    guard case let .rejected(name, priority) = result else {
      Issue.record("expected rejection")
      return
    }
    #expect(name == "owner")
    #expect(priority == 50)
  }

  @Test("higher priority preempts current owner")
  func higherPreempts() {
    let arbitrator = self.makeArbitrator()
    let low = Token()
    let high = Token()
    let lowID = ObjectIdentifier(low)
    let highID = ObjectIdentifier(high)
    arbitrator.registerClientName("curve", for: lowID)
    arbitrator.registerClientName("lmd", for: highID)
    _ = arbitrator.decideClaim(fan: 0, priority: 10, clientID: lowID)
    let result = arbitrator.decideClaim(fan: 0, priority: 50, clientID: highID)
    if case .rejected = result { Issue.record("higher priority must preempt") }
  }

  @Test("same client can rewrite regardless of priority drop")
  func sameClientRewrites() {
    let arbitrator = self.makeArbitrator()
    let tok = Token()
    let id = ObjectIdentifier(tok)
    arbitrator.registerClientName("self", for: id)
    _ = arbitrator.decideClaim(fan: 0, priority: 50, clientID: id)
    let result = arbitrator.decideClaim(fan: 0, priority: 20, clientID: id)
    if case .rejected = result { Issue.record("same client must not be rejected") }
  }

  @Test("lower priority accepted after owner TTL lapses")
  func ttlLapse() {
    let arbitrator = self.makeArbitrator(ownerTTL: 10)
    let owner = Token()
    let other = Token()
    let ownerID = ObjectIdentifier(owner)
    let otherID = ObjectIdentifier(other)
    arbitrator.registerClientName("owner", for: ownerID)
    arbitrator.registerClientName("other", for: otherID)
    let t0 = Date()
    _ = arbitrator.decideClaim(fan: 0, priority: 50, clientID: ownerID, now: t0)
    let beforeTTL = arbitrator.decideClaim(fan: 0, priority: 10, clientID: otherID, now: t0.addingTimeInterval(9))
    if case .accepted = beforeTTL { Issue.record("should still be rejected within TTL") }
    let afterTTL = arbitrator.decideClaim(fan: 0, priority: 10, clientID: otherID, now: t0.addingTimeInterval(11))
    if case .rejected = afterTTL { Issue.record("should be accepted after TTL lapse") }
  }

  @Test("unregistered clients still get arbitrated")
  func unregisteredWorks() {
    let arbitrator = self.makeArbitrator()
    let token = Token()
    let id = ObjectIdentifier(token)
    let result = arbitrator.decideClaim(fan: 0, priority: 10, clientID: id)
    if case .rejected = result { Issue.record("first unregistered claim should succeed") }
  }

  @Test("cleanupClient drops ownership")
  func cleanupReleasesOwnership() {
    let arbitrator = self.makeArbitrator()
    let owner = Token()
    let other = Token()
    let ownerID = ObjectIdentifier(owner)
    let otherID = ObjectIdentifier(other)
    arbitrator.registerClientName("owner", for: ownerID)
    arbitrator.registerClientName("other", for: otherID)
    _ = arbitrator.decideClaim(fan: 0, priority: 50, clientID: ownerID)
    arbitrator.cleanupClient(id: ownerID)
    // A lower priority writer should now succeed immediately.
    let result = arbitrator.decideClaim(fan: 0, priority: 10, clientID: otherID)
    if case .rejected = result { Issue.record("cleanup should release ownership") }
  }

  @Test("getOwnershipSnapshot returns active owners sorted")
  func snapshot() {
    let arbitrator = self.makeArbitrator()
    let t1 = Token()
    let t2 = Token()
    arbitrator.registerClientName("two", for: ObjectIdentifier(t2))
    arbitrator.registerClientName("one", for: ObjectIdentifier(t1))
    _ = arbitrator.decideClaim(fan: 2, priority: 50, clientID: ObjectIdentifier(t2))
    _ = arbitrator.decideClaim(fan: 0, priority: 10, clientID: ObjectIdentifier(t1))
    let rows = arbitrator.getOwnershipSnapshot()
    #expect(rows.count == 2)
    #expect(rows[0].fanIndex == 0)
    #expect(rows[0].clientName == "one")
    #expect(rows[1].fanIndex == 2)
    #expect(rows[1].clientName == "two")
  }
}
