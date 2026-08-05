//
//  RequestScopeCancellationXPCTests.swift
//  SMCFanXPCClientTests
//
//  Created by Codex <noreply@openai.com> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SMCFanXPCClient

private let scopedTimeoutTestSeconds: TimeInterval = 0.05
private let watchdogCancellationReleaseSeconds: TimeInterval = 0.25

@Suite("SMCFanXPCClient request scope cancellation")
struct RequestScopeCancellationXPCTests {
  @Test("task cancellation terminates a standalone scoped request")
  func taskCancellationTerminatesStandaloneScopedRequest() async {
    let fixture = RequestScopeXPCFixture(autoReply: .withhold)
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.setFanAuto(0, scope: scope) }
    await fixture.helper.waitForAutoRequest()
    requestTask.cancel()

    #expect(await voidOutcome(from: requestTask) == .cancelled)
    #expect(scope.state.isCancelled)
    #expect(fixture.connectionFactory.creationCount == 1)
  }

  @Test("reply winning before task cancellation preserves the scope")
  func replyWinningBeforeTaskCancellationPreservesScope() async {
    let fixture = RequestScopeXPCFixture(blockedCompletion: 2)
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()
    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }

    await fixture.completionGate.waitUntilBlocked()
    requestTask.cancel()

    #expect(!scope.state.isCancelled)
    await fixture.completionGate.release()
    #expect(await fanCountOutcome(from: requestTask) == .value(2))

    let repeatedRequest = Task { try await fixture.client.getFanCount(scope: scope) }
    #expect(await fanCountOutcome(from: repeatedRequest) == .value(2))
    #expect(!scope.state.isCancelled)
    #expect(fixture.connectionAcceptor.invalidationCount == 0)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1, fanCount: 2))
  }

  @Test("timeout winning before task cancellation stays terminal")
  func timeoutWinningBeforeTaskCancellationStaysTerminal() async {
    let fixture = RequestScopeXPCFixture(
      blockedCompletion: 2,
      fanCountReply: .withhold,
      syncTimeout: scopedTimeoutTestSeconds
    )
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()
    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }

    await fixture.completionGate.waitUntilBlocked()
    #expect(scope.state.isCancelled)
    requestTask.cancel()
    await fixture.completionGate.release()

    #expect(await fanCountOutcome(from: requestTask) == .timeout("getFanCount"))
    let invalidationObserved = await fixture.connectionAcceptor.waitForInvalidationObservation()
    #expect(scope.state.isCancelled)
    #expect(invalidationObserved)
    #expect(fixture.connectionAcceptor.invalidationCount == 1)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1, fanCount: 1))
  }

  @Test("scoped value call times out when its reply is withheld")
  func scopedValueCallTimesOutWhenReplyIsWithheld() async {
    let fixture = RequestScopeXPCFixture(
      fanCountReply: .withhold,
      syncTimeout: scopedTimeoutTestSeconds
    )
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }
    await fixture.helper.waitForFanCountRequest()

    #expect(await fanCountOutcome(from: requestTask) == .timeout("getFanCount"))
    let invalidationObserved = await fixture.connectionAcceptor.waitForInvalidationObservation()
    let repeatedRequest = Task { try await fixture.client.getFanCount(scope: scope) }

    #expect(scope.state.isCancelled)
    #expect(await fanCountOutcome(from: repeatedRequest) == .cancelled)
    #expect(invalidationObserved)
    #expect(fixture.connectionAcceptor.invalidationCount == 1)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1, fanCount: 1))
  }

  @Test("scoped void call times out when open reply is withheld")
  func scopedVoidCallTimesOutWhenOpenReplyIsWithheld() async {
    let fixture = RequestScopeXPCFixture(
      openReply: .withhold,
      syncTimeout: scopedTimeoutTestSeconds
    )
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.getFanCount(scope: scope) }
    await fixture.helper.waitForOpenRequest()

    #expect(await fanCountOutcome(from: requestTask) == .timeout("smcOpen"))
    let invalidationObserved = await fixture.connectionAcceptor.waitForInvalidationObservation()
    #expect(scope.state.isCancelled)
    #expect(invalidationObserved)
    #expect(fixture.connectionAcceptor.invalidationCount == 1)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1))
  }

  @Test("scoped arbitrated call times out when its reply is withheld")
  func scopedArbitratedCallTimesOutWhenReplyIsWithheld() async {
    let fixture = RequestScopeXPCFixture(
      autoReply: .withhold,
      syncTimeout: scopedTimeoutTestSeconds
    )
    defer { fixture.shutdown() }
    let scope = fixture.client.makeRequestScope()

    let requestTask = Task { try await fixture.client.setFanAuto(0, scope: scope) }
    await fixture.helper.waitForAutoRequest()

    #expect(await voidOutcome(from: requestTask) == .timeout("setFanAuto[0]"))
    let invalidationObserved = await fixture.connectionAcceptor.waitForInvalidationObservation()
    #expect(scope.state.isCancelled)
    #expect(invalidationObserved)
    #expect(fixture.connectionAcceptor.invalidationCount == 1)
    #expect(fixture.connectionFactory.creationCount == 1)
    #expect(fixture.helper.counts == RequestCounts(open: 1, setFanAuto: 1))
  }

  @Test("watchdog reports before a blocking cancellation handler completes")
  func watchdogReportsBeforeBlockingCancellationCompletes() async {
    let cancellationLock = TestNonrecursiveLock()
    let cancellationState = CancellationCompletionState()
    cancellationLock.lock()
    let releaseTask = Task {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).asyncAfter(
          deadline: .now() + watchdogCancellationReleaseSeconds
        ) {
          cancellationLock.unlock()
          continuation.resume()
        }
      }
    }
    let requestTask = Task<Void, Error> {
      try await withTaskCancellationHandler {
        try await Task.sleep(for: .seconds(60))
      } onCancel: {
        cancellationLock.lock()
        cancellationLock.unlock()
        cancellationState.markCompleted()
      }
    }

    let outcome = await outcomeWithWatchdog(
      from: requestTask,
      watchdogOutcome: VoidOutcome.watchdogExpired,
      watchdogSeconds: scopedTimeoutTestSeconds
    ) { _ in .succeeded }

    #expect(outcome == .watchdogExpired)
    #expect(!cancellationState.isCompleted)
    await releaseTask.value
    _ = await requestTask.result
  }
}

// MARK: - CancellationCompletionState

private final class CancellationCompletionState: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  var isCompleted: Bool {
    lock.lock()
    let current = completed
    lock.unlock()
    return current
  }

  func markCompleted() {
    lock.lock()
    completed = true
    lock.unlock()
  }
}

// MARK: - TestNonrecursiveLock

private final class TestNonrecursiveLock: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 1)

  func lock() {
    semaphore.wait()
  }

  func unlock() {
    semaphore.signal()
  }
}
