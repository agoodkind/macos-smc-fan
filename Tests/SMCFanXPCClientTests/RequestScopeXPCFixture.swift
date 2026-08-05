//
//  RequestScopeXPCFixture.swift
//  SMCFanXPCClientTests
//
//  Created by Codex <noreply@openai.com> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SMCFanProtocol

@testable import SMCFanXPCClient

private let cancellationPollIntervalMilliseconds = 5
private let cancellationPollSeconds: TimeInterval = 1
private let requestTestPriority = 50
private let requestWatchdogSeconds: TimeInterval = 5

// MARK: - FanCountOutcome

enum FanCountOutcome: Equatable, Sendable {
  case cancelled, watchdogExpired
  case failure(String)
  case timeout(String)
  case value(UInt)
}

// MARK: - VoidOutcome

enum VoidOutcome: Equatable, Sendable {
  case cancelled, succeeded, watchdogExpired
  case conflict(String)
  case failure(String)
  case timeout(String)
}

func fanCountOutcome(from requestTask: Task<UInt, Error>) async -> FanCountOutcome {
  await outcomeWithWatchdog(
    from: requestTask,
    watchdogOutcome: .watchdogExpired
  ) { result in
    switch result {
    case .success(let count):
      .value(count)
    case .failure(is CancellationError):
      .cancelled
    case .failure(let error as SMCXPCTimeoutError):
      .timeout(error.label)
    case .failure(let error):
      .failure(error.localizedDescription)
    }
  }
}

func voidOutcome(from requestTask: Task<Void, Error>) async -> VoidOutcome {
  await outcomeWithWatchdog(
    from: requestTask,
    watchdogOutcome: .watchdogExpired
  ) { result in
    switch result {
    case .success:
      .succeeded
    case .failure(is CancellationError):
      .cancelled
    case .failure(let error as SMCXPCTimeoutError):
      .timeout(error.label)
    case .failure(let error as SMCXPCConflictError):
      .conflict(error.message)
    case .failure(let error):
      .failure(error.localizedDescription)
    }
  }
}

func waitForCancellation(of scope: SMCFanXPCRequestScope) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(cancellationPollSeconds))
  while clock.now < deadline {
    if scope.state.isCancelled {
      return true
    }
    do {
      try await Task.sleep(for: .milliseconds(cancellationPollIntervalMilliseconds))
    } catch {
      return scope.state.isCancelled
    }
  }
  return scope.state.isCancelled
}

func outcomeWithWatchdog<Value: Sendable, Outcome: Sendable>(
  from requestTask: Task<Value, Error>,
  watchdogOutcome: Outcome,
  watchdogSeconds: TimeInterval = requestWatchdogSeconds,
  transform: @escaping @Sendable (Result<Value, Error>) -> Outcome
) async -> Outcome {
  await withCheckedContinuation { continuation in
    let once = ResumeGuard()
    let raceTasks = WatchdogRaceTasks()
    let resultTask = Task {
      let result = await requestTask.result
      once.tryResume {
        raceTasks.cancel()
        continuation.resume(returning: transform(result))
      }
    }
    let watchdogTask = Task {
      try await Task.sleep(for: .seconds(watchdogSeconds))
      guard !Task.isCancelled else { return }
      once.tryResume {
        raceTasks.cancel()
        continuation.resume(returning: watchdogOutcome)
        DispatchQueue.global(qos: .utility).async {
          requestTask.cancel()
        }
      }
    }
    raceTasks.install(resultTask: resultTask, watchdogTask: watchdogTask)
  }
}

// MARK: - WatchdogRaceTasks

private final class WatchdogRaceTasks: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var resultTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Error>?

  func install(resultTask: Task<Void, Never>, watchdogTask: Task<Void, Error>) {
    lock.lock()
    if cancelled {
      lock.unlock()
      resultTask.cancel()
      watchdogTask.cancel()
      return
    }
    self.resultTask = resultTask
    self.watchdogTask = watchdogTask
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let activeResultTask = self.resultTask
    let activeWatchdogTask = self.watchdogTask
    self.resultTask = nil
    self.watchdogTask = nil
    lock.unlock()
    activeResultTask?.cancel()
    activeWatchdogTask?.cancel()
  }
}

// MARK: - RequestScopeXPCFixture

final class RequestScopeXPCFixture: @unchecked Sendable {
  let claimGate: RequestEventGate
  let client: SMCFanXPCClient
  let completionGate: RequestEventGate
  let connectionFactory: CountingConnectionFactory
  let helper: RequestScopeTestHelper
  let listener: NSXPCListener
  let registrationGate: BlockingRequestScopeRegistrationGate
  let connectionAcceptor: RequestScopeListenerDelegate

  init(
    blockedClaim: Int? = nil,
    blockedCompletion: Int? = nil,
    blockRequestScopeRegistration: Bool = false,
    clientName: String? = nil,
    autoReply: RequestScopeTestHelper.AutoReply = .success,
    fanCountReply: RequestScopeTestHelper.BasicReply = .success,
    openReply: RequestScopeTestHelper.BasicReply = .success,
    syncTimeout: TimeInterval = SMCFanXPCClient.defaultSyncTimeout
  ) {
    let testHelper = RequestScopeTestHelper(
      autoReply: autoReply,
      fanCountReply: fanCountReply,
      openReply: openReply
    )
    let anonymousListener = NSXPCListener.anonymous()
    let acceptor = RequestScopeListenerDelegate(helper: testHelper)
    anonymousListener.delegate = acceptor
    anonymousListener.resume()

    let claimEventGate = RequestEventGate(blockedEvent: blockedClaim)
    let completionEventGate = RequestEventGate(blockedEvent: blockedCompletion)
    let scopeRegistrationGate = BlockingRequestScopeRegistrationGate(
      shouldBlock: blockRequestScopeRegistration
    )
    let factory = CountingConnectionFactory(endpoint: anonymousListener.endpoint)
    self.helper = testHelper
    self.listener = anonymousListener
    self.registrationGate = scopeRegistrationGate
    self.connectionAcceptor = acceptor
    self.claimGate = claimEventGate
    self.completionGate = completionEventGate
    self.connectionFactory = factory
    self.client = SMCFanXPCClient(
      clientName: clientName,
      defaultPriority: requestTestPriority,
      syncTimeout: syncTimeout,
      beforeConnectionClaim: { await claimEventGate.pauseAtEvent() },
      beforeRequestScopeRegistration: { scopeRegistrationGate.pause() },
      afterScopedRequestCompletion: { await completionEventGate.pauseAtEvent() },
      connectionFactory: { factory.makeConnection() }
    )
  }

  func shutdown() {
    client.shutdown()
    listener.invalidate()
  }
}

// MARK: - BlockingRequestScopeRegistrationGate

final class BlockingRequestScopeRegistrationGate: @unchecked Sendable {
  private let arrivals: AsyncStream<Void>
  private let arrivalContinuation: AsyncStream<Void>.Continuation
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private let shouldBlock: Bool

  init(shouldBlock: Bool) {
    let (arrivalStream, continuation) = AsyncStream.makeStream(of: Void.self)
    self.arrivals = arrivalStream
    self.arrivalContinuation = continuation
    self.shouldBlock = shouldBlock
  }

  func pause() {
    guard shouldBlock else { return }
    arrivalContinuation.yield()
    releaseSemaphore.wait()
  }

  func waitUntilBlocked() async {
    for await _ in arrivals {
      return
    }
  }

  func release() {
    releaseSemaphore.signal()
  }
}

// MARK: - RequestEventGate

actor RequestEventGate {
  private let arrivals: AsyncStream<Int>
  private let arrivalContinuation: AsyncStream<Int>.Continuation
  private let blockedEvent: Int?
  private var eventCount = 0
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(blockedEvent: Int?) {
    let (arrivalStream, continuation) = AsyncStream.makeStream(of: Int.self)
    self.arrivals = arrivalStream
    self.arrivalContinuation = continuation
    self.blockedEvent = blockedEvent
  }

  func pauseAtEvent() async {
    eventCount += 1
    let eventNumber = eventCount
    arrivalContinuation.yield(eventNumber)
    guard eventNumber == blockedEvent else { return }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    guard let targetEvent = blockedEvent else { return }
    for await currentEvent in arrivals where currentEvent == targetEvent {
      return
    }
  }

  func release() {
    let continuation = releaseContinuation
    releaseContinuation = nil
    continuation?.resume()
  }
}

// MARK: - CountingConnectionFactory

final class CountingConnectionFactory: @unchecked Sendable {
  private let endpoint: NSXPCListenerEndpoint
  private let lock = NSLock()
  private var connections: [NSXPCConnection] = []
  private var storedCreationCount = 0

  init(endpoint: NSXPCListenerEndpoint) {
    self.endpoint = endpoint
  }

  var creationCount: Int {
    lock.lock()
    let count = storedCreationCount
    lock.unlock()
    return count
  }

  func makeConnection() -> NSXPCConnection {
    lock.lock()
    storedCreationCount += 1
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connections.append(connection)
    lock.unlock()
    return connection
  }

  func invalidateConnection(at index: Int) {
    lock.lock()
    let connection = connections[index]
    lock.unlock()
    connection.invalidate()
  }
}

// MARK: - RequestScopeListenerDelegate

final class RequestScopeListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  private let helper: RequestScopeTestHelper
  private let invalidations: AsyncStream<Void>
  private let invalidationContinuation: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var storedInvalidationCount = 0

  init(helper: RequestScopeTestHelper) {
    let (invalidationStream, continuation) = AsyncStream.makeStream(of: Void.self)
    self.helper = helper
    self.invalidations = invalidationStream
    self.invalidationContinuation = continuation
  }

  var invalidationCount: Int {
    lock.lock()
    let currentCount = storedInvalidationCount
    lock.unlock()
    return currentCount
  }

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    newConnection.exportedObject = helper
    newConnection.invalidationHandler = { [weak self] in
      guard let self else { return }
      lock.lock()
      storedInvalidationCount += 1
      lock.unlock()
      invalidationContinuation.yield()
    }
    newConnection.resume()
    return true
  }

  func waitForInvalidation() async {
    for await _ in invalidations {
      return
    }
  }

  func waitForInvalidationObservation() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(cancellationPollSeconds))
    while clock.now < deadline {
      if invalidationCount > 0 {
        return true
      }
      do {
        try await Task.sleep(for: .milliseconds(cancellationPollIntervalMilliseconds))
      } catch {
        return invalidationCount > 0
      }
    }
    return invalidationCount > 0
  }
}
