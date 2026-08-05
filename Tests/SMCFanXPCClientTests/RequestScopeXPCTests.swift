//
//  RequestScopeXPCTests.swift
//  SMCFanXPCClientTests
//
//  Created by Codex <noreply@openai.com> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SMCFanProtocol
import Testing

@testable import SMCFanXPCClient

@Suite("SMCFanXPCClient request scopes")
struct RequestScopeXPCTests {
  @Test("shutdown catches a scope paused before registration")
  func shutdownCatchesScopePausedBeforeRegistration() async {
    let fixture = RequestScopeXPCFixture(blockRequestScopeRegistration: true)
    defer {
      fixture.registrationGate.release()
      fixture.shutdown()
    }
    let scopeTask = Task { fixture.client.makeRequestScope() }

    await fixture.registrationGate.waitUntilBlocked()
    fixture.client.shutdown()
    fixture.registrationGate.release()
    let scope = await scopeTask.value
    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }

    #expect(scope.state.isCancelled)
    #expect(await fanCountOutcome(from: requestTask) == .cancelled)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts())
  }

  @Test("normal scope creation remains usable")
  func normalScopeCreationRemainsUsable() async {
    let fixture = RequestScopeXPCFixture()
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()
    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }

    #expect(!scope.state.isCancelled)
    #expect(await fanCountOutcome(from: requestTask) == .value(2))
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1, fanCount: 1))
  }

  @Test("shutdown stays terminal and idempotent for later scopes")
  func shutdownStaysTerminalAndIdempotentForLaterScopes() async {
    let fixture = RequestScopeXPCFixture()
    defer { fixture.shutdown() }
    let activeScope = fixture.client.makeRequestScope()
    let activeRequest = Task { try await fixture.client.getFanCount(scope: activeScope) }

    #expect(await fanCountOutcome(from: activeRequest) == .value(2))
    fixture.client.shutdown()
    fixture.client.shutdown()
    let invalidationObserved = await fixture.connectionAcceptor.waitForInvalidationObservation()
    let laterScope = fixture.client.makeRequestScope()
    let requestTask = Task { try await fixture.client.getFanCount(scope: laterScope) }

    #expect(activeScope.state.isCancelled)
    #expect(laterScope.state.isCancelled)
    #expect(await fanCountOutcome(from: requestTask) == .cancelled)
    #expect(invalidationObserved)
    #expect(fixture.connectionAcceptor.invalidationCount == 1)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1, fanCount: 1))
  }

  @Test("cancellation before dispatch sends nothing and creates no replacement")
  func cancellationBeforeConnectionClaimCreatesAndDispatchesNothing() async {
    let fixture = RequestScopeXPCFixture(blockedClaim: 1)
    defer { fixture.shutdown() }
    let scope: SMCFanXPCRequestScope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }
    await fixture.claimGate.waitUntilBlocked()
    fixture.client.cancelRequests(in: scope)
    await fixture.claimGate.release()

    #expect(await fanCountOutcome(from: requestTask) == .cancelled)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts())

    let repeatedRequest = Task { try await fixture.client.getFanCount(scope: scope) }
    #expect(await fanCountOutcome(from: repeatedRequest) == .cancelled)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts())
  }

  @Test("connection invalidation makes the scope terminal")
  func connectionInvalidationMakesScopeTerminal() async {
    let fixture = RequestScopeXPCFixture()
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    fixture.connectionFactory.invalidateConnection(at: 0)
    let cancellationObserved = await waitForCancellation(of: scope)
    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }

    #expect(cancellationObserved)
    #expect(await fanCountOutcome(from: requestTask) == .cancelled)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts())
  }

  @Test("cancellation after open prevents fan count dispatch")
  func cancellationAfterOpenPreventsFanCountDispatch() async {
    let fixture = RequestScopeXPCFixture(blockedClaim: 2)
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }
    await fixture.claimGate.waitUntilBlocked()
    fixture.client.cancelRequests(in: scope)
    await fixture.claimGate.release()

    #expect(await fanCountOutcome(from: requestTask) == .cancelled)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1))
  }

  @Test("cancellation after open prevents registration and set auto")
  func cancellationAfterOpenPreventsRegistrationAndSetAuto() async {
    let fixture = RequestScopeXPCFixture(blockedClaim: 2, clientName: "fan-curve-test")
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.setFanAuto(1, scope: scope) }
    await fixture.claimGate.waitUntilBlocked()
    fixture.client.cancelRequests(in: scope)
    await fixture.claimGate.release()

    #expect(await voidOutcome(from: requestTask) == .cancelled)
    #expect(fixture.helper.counts == RequestCounts(open: 1))
  }

  @Test("cancellation after registration prevents set auto")
  func cancellationAfterRegistrationPreventsSetAuto() async {
    let fixture = RequestScopeXPCFixture(blockedClaim: 3, clientName: "fan-curve-test")
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task {
      try await fixture.client.setFanAuto(1, priority: 75, scope: scope)
    }
    await fixture.claimGate.waitUntilBlocked()
    fixture.client.cancelRequests(in: scope)
    await fixture.claimGate.release()

    #expect(await voidOutcome(from: requestTask) == .cancelled)
    #expect(fixture.helper.counts == RequestCounts(open: 1, register: 1))
  }

  @Test("active scope preserves reads writes identity and registration")
  func activeScopePreservesReadsWritesIdentityAndRegistration() async throws {
    let fixture = RequestScopeXPCFixture(clientName: "fan-curve-test")
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let fanCount = try await fixture.client.getFanCount(scope: scope)
    try await fixture.client.setFanAuto(1, priority: 75, scope: scope)
    let identity = try await fixture.client.getHelperIdentity()

    #expect(fanCount == 2)
    #expect(identity.version == "0.4.1-test")
    #expect(identity.protocolVersion == 1)
    let expectedCounts = RequestCounts(open: 1, register: 1, fanCount: 1, setFanAuto: 1)
    #expect(fixture.helper.counts == expectedCounts)
    #expect(fixture.helper.lastRegistration == "fan-curve-test")
    #expect(fixture.helper.lastAutoRequest?.fanIndex == 1)
    #expect(fixture.helper.lastAutoRequest?.priority == 75)
  }

  @Test("synchronous replies can reenter scope state")
  func synchronousRepliesCanReenterScopeState() async {
    let helper = RequestScopeTestHelper(autoReply: .success)
    let listener = NSXPCListener.anonymous()
    defer { listener.invalidate() }
    let client = SMCFanXPCClient(
      remoteProxyFactory: { _, _ in helper },
      connectionFactory: { NSXPCConnection(listenerEndpoint: listener.endpoint) }
    )
    let scope = client.makeRequestScope()

    let requestTask = Task { try await client.getFanCount(scope: scope) }
    let outcome = await fanCountOutcome(from: requestTask)

    #expect(outcome == .value(2))
    #expect(helper.counts == RequestCounts(open: 1, fanCount: 1))
    if outcome != .watchdogExpired {
      client.shutdown()
    }
  }

  @Test("scoped set auto preserves conflict errors")
  func scopedSetAutoPreservesConflictErrors() async {
    let fixture = RequestScopeXPCFixture(autoReply: .conflict)
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.setFanAuto(0, scope: scope) }

    #expect(await voidOutcome(from: requestTask) == .conflict("owned by lmd"))
  }

  @Test("scoped helper rejection remains a helper error")
  func scopedHelperRejectionRemainsHelperError() async {
    let fixture = RequestScopeXPCFixture(
      fanCountReply: .failure("Failed to open AppleSMC")
    )
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }

    #expect(await fanCountOutcome(from: requestTask) == .failure("Failed to open AppleSMC"))
  }

  @Test("scoped proxy failure throws a transport error")
  func scopedProxyFailureThrowsTransportError() async {
    let helper = RequestScopeTestHelper(autoReply: .success)
    let listener = NSXPCListener.anonymous()
    defer { listener.invalidate() }
    let client = SMCFanXPCClient(
      remoteProxyFactory: { _, errorHandler in
        errorHandler(
          NSError(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionInterrupted,
            userInfo: [NSLocalizedDescriptionKey: "Connection interrupted"]
          )
        )
        return helper
      },
      connectionFactory: { NSXPCConnection(listenerEndpoint: listener.endpoint) }
    )
    let scope = client.makeRequestScope()
    let requestTask = Task { try await client.getFanCount(scope: scope) }

    #expect(
      await fanCountOutcome(from: requestTask)
        == .transportFailure("Connection interrupted")
    )
    client.shutdown()
  }

  @Test("cancellation after dispatch resumes once and ignores a late reply")
  func cancellationAfterDispatchResumesOnceAndIgnoresLateReply() async {
    let fixture = RequestScopeXPCFixture(autoReply: .withhold)
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.setFanAuto(0, scope: scope) }
    await fixture.helper.waitForAutoRequest()
    fixture.client.cancelRequests(in: scope)

    #expect(await voidOutcome(from: requestTask) == .cancelled)
    fixture.helper.releaseAutoReply()
    await Task.yield()
    #expect(fixture.helper.counts.setFanAuto == 1)
  }

  @Test("cancelling a scope preserves a concurrent unscoped request")
  func cancellingScopePreservesConcurrentUnscopedRequest() async throws {
    let fixture = RequestScopeXPCFixture(autoReply: .withhold)
    defer { fixture.shutdown() }
    let cancelledScope = fixture.client.makeRequestScope()

    _ = try await fixture.client.getFanCount(scope: cancelledScope)
    let unscopedRequest = Task { try await fixture.client.setFanAuto(0) }
    await fixture.helper.waitForAutoRequest()
    fixture.client.cancelRequests(in: cancelledScope)
    fixture.helper.releaseAutoReply()

    #expect(await voidOutcome(from: unscopedRequest) == .succeeded)
  }

  @Test("cancelling a scope preserves a concurrent different scope")
  func cancellingScopePreservesConcurrentDifferentScope() async throws {
    let fixture = RequestScopeXPCFixture(autoReply: .withhold)
    defer { fixture.shutdown() }
    let cancelledScope = fixture.client.makeRequestScope()
    let survivingScope = fixture.client.makeRequestScope()

    _ = try await fixture.client.getFanCount(scope: cancelledScope)
    let survivingRequest = Task {
      try await fixture.client.setFanAuto(0, scope: survivingScope)
    }
    await fixture.helper.waitForAutoRequest()
    fixture.client.cancelRequests(in: cancelledScope)
    fixture.helper.releaseAutoReply()

    #expect(await voidOutcome(from: survivingRequest) == .succeeded)
  }

  @Test("shutdown invalidates the live anonymous connection")
  func shutdownInvalidatesLiveAnonymousConnection() async throws {
    let fixture = RequestScopeXPCFixture()
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    _ = try await fixture.client.getFanCount(scope: scope)
    fixture.client.shutdown()

    await fixture.connectionAcceptor.waitForInvalidation()
    #expect(fixture.connectionAcceptor.invalidationCount == 1)
  }

}
