//
//  HelperIdentityXPCTests.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-08-04.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SMCFanProtocol
import Testing

@testable import SMCFanXPCClient

private let identityWatchdogSeconds: TimeInterval = 0.25

@Suite("SMCFanXPCClient helper identity")
struct HelperIdentityXPCTests {
  @Test("identity uses XPC without opening SMC")
  func identityUsesXPCWithoutOpeningSMC() async throws {
    let helper = IdentityTestHelper()
    let listener = NSXPCListener.anonymous()
    let listenerDelegate = IdentityListenerDelegate(helper: helper)
    listener.delegate = listenerDelegate
    listener.resume()
    defer { listener.invalidate() }

    let client = SMCFanXPCClient {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }
    defer { client.shutdown() }

    let identity = try await client.getHelperIdentity()

    #expect(identity.version == "0.4.0-test")
    #expect(identity.build == "42")
    #expect(identity.commit == "abcdef0123456789")
    #expect(identity.executableHash == "0123456789abcdef")
    #expect(identity.protocolVersion == 1)
    #expect(helper.openCallCount == 0)
  }

  @Test("withheld identity reply fails before the test watchdog")
  func withheldIdentityReplyFailsBeforeWatchdog() async {
    let helper = IdentityTestHelper(replyMode: .withhold)
    let listener = NSXPCListener.anonymous()
    let listenerDelegate = IdentityListenerDelegate(helper: helper)
    listener.delegate = listenerDelegate
    listener.resume()
    defer { listener.invalidate() }

    let client = SMCFanXPCClient(identityTimeout: 0.05) {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }
    defer { client.shutdown() }

    let requestTask = Task { try await client.getHelperIdentity() }
    let outcome = await identityOutcome(from: requestTask)

    #expect(outcome == .clientTimeout("getHelperIdentity"))
  }

  @Test("legacy helper without identity fails before the test watchdog")
  func legacyHelperWithoutIdentityFailsBeforeWatchdog() async {
    let helper = LegacyIdentityTestHelper()
    let listener = NSXPCListener.anonymous()
    let listenerDelegate = LegacyIdentityListenerDelegate(helper: helper)
    listener.delegate = listenerDelegate
    listener.resume()
    defer { listener.invalidate() }

    let client = SMCFanXPCClient {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }
    defer { client.shutdown() }

    let requestTask = Task { try await client.getHelperIdentity() }
    let outcome = await identityOutcome(from: requestTask)

    guard case .transportFailure = outcome else {
      Issue.record("Expected transport failure, got \(outcome)")
      return
    }
  }

  @Test("cancelling identity request resumes the caller")
  func cancellingIdentityRequestResumesCaller() async {
    let helper = IdentityTestHelper(replyMode: .withhold)
    let listener = NSXPCListener.anonymous()
    let listenerDelegate = IdentityListenerDelegate(helper: helper)
    listener.delegate = listenerDelegate
    listener.resume()
    defer { listener.invalidate() }

    let client = SMCFanXPCClient {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }
    defer { client.shutdown() }

    let requestTask = Task { try await client.getHelperIdentity() }
    let outcome = await cancellationOutcome(from: requestTask) {
      await helper.waitForIdentityRequest()
    }

    #expect(outcome == .cancelled)
  }

  @Test("cancellation sequence expires when request delivery fails")
  func cancellationSequenceExpiresWhenRequestDeliveryFails() async {
    let helper = IdentityTestHelper(replyMode: .withhold)
    let listener = NSXPCListener.anonymous()
    let listenerDelegate = IdentityListenerDelegate(
      helper: helper,
      acceptsConnections: false
    )
    listener.delegate = listenerDelegate
    listener.resume()
    defer { listener.invalidate() }

    let client = SMCFanXPCClient {
      NSXPCConnection(listenerEndpoint: listener.endpoint)
    }
    defer { client.shutdown() }

    let requestTask = Task { try await client.getHelperIdentity() }
    let outcome = await cancellationOutcome(from: requestTask) {
      await helper.waitForIdentityRequest()
    }

    #expect(outcome == .watchdogExpired)
  }
}

// MARK: - IdentityOutcome

private enum IdentityOutcome: Equatable, Sendable {
  case cancelled
  case clientFailure(String)
  case clientTimeout(String)
  case identity(SMCFanHelperIdentity)
  case transportFailure(String)
  case unexpectedFailure(String)
  case watchdogExpired
}

private func identityOutcome(
  from requestTask: Task<SMCFanHelperIdentity, Error>
) async -> IdentityOutcome {
  await withCheckedContinuation { continuation in
    let once = ResumeGuard()
    Task {
      let result = await requestTask.result
      once.tryResume {
        continuation.resume(returning: identityOutcome(from: result))
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + identityWatchdogSeconds
    ) {
      once.tryResume {
        requestTask.cancel()
        continuation.resume(returning: .watchdogExpired)
      }
    }
  }
}

private func cancellationOutcome(
  from requestTask: Task<SMCFanHelperIdentity, Error>,
  afterDelivery waitForDelivery: @escaping @Sendable () async -> Void
) async -> IdentityOutcome {
  await withCheckedContinuation { continuation in
    let once = ResumeGuard()
    let cancellationTask = Task {
      await waitForDelivery()
      requestTask.cancel()
      let result = await requestTask.result
      once.tryResume {
        continuation.resume(returning: identityOutcome(from: result))
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + identityWatchdogSeconds
    ) {
      once.tryResume {
        cancellationTask.cancel()
        requestTask.cancel()
        continuation.resume(returning: .watchdogExpired)
      }
    }
  }
}

private func identityOutcome(
  from result: Result<SMCFanHelperIdentity, Error>
) -> IdentityOutcome {
  switch result {
  case .success(let identity):
    return .identity(identity)
  case .failure(is CancellationError):
    return .cancelled
  case .failure(let error as SMCXPCTimeoutError):
    return .clientTimeout(error.label)
  case .failure(let error as SMCXPCError):
    return .clientFailure(error.message)
  case .failure(let error as SMCXPCTransportError):
    return .transportFailure(error.message)
  case .failure(let error):
    return .unexpectedFailure(error.localizedDescription)
  }
}

// MARK: - IdentityListenerDelegate

private final class IdentityListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let acceptsConnections: Bool
  private let helper: IdentityTestHelper

  init(helper: IdentityTestHelper, acceptsConnections: Bool = true) {
    self.acceptsConnections = acceptsConnections
    self.helper = helper
  }

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    guard acceptsConnections else { return false }
    newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
    newConnection.exportedObject = helper
    newConnection.resume()
    return true
  }
}

// MARK: - LegacyIdentityListenerDelegate

private final class LegacyIdentityListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let helper: LegacyIdentityTestHelper

  init(helper: LegacyIdentityTestHelper) {
    self.helper = helper
  }

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: LegacyIdentityTestProtocol.self)
    newConnection.exportedObject = helper
    newConnection.resume()
    return true
  }
}

// MARK: - LegacyIdentityTestProtocol

@objc private protocol LegacyIdentityTestProtocol {
  // periphery:ignore
  func smcOpen(reply: @escaping @Sendable (Bool, String?) -> Void)
}

// MARK: - LegacyIdentityTestHelper

private final class LegacyIdentityTestHelper: NSObject, LegacyIdentityTestProtocol {
  // periphery:ignore
  func smcOpen(reply: (Bool, String?) -> Void) {
    reply(true, nil)
  }
}

// MARK: - IdentityTestHelper

private final class IdentityTestHelper: NSObject, SMCFanHelperProtocol, @unchecked Sendable {
  enum ReplyMode {
    case success
    case withhold
  }

  private let identityRequests: AsyncStream<Void>
  private let identityRequestContinuation: AsyncStream<Void>.Continuation
  private let openCallCountLock = NSLock()
  private let replyMode: ReplyMode
  private var storedOpenCallCount = 0

  var openCallCount: Int {
    openCallCountLock.lock()
    let count = storedOpenCallCount
    openCallCountLock.unlock()
    return count
  }

  init(replyMode: ReplyMode = .success) {
    let (requestStream, requestContinuation) = AsyncStream.makeStream(of: Void.self)
    self.identityRequests = requestStream
    self.identityRequestContinuation = requestContinuation
    self.replyMode = replyMode
  }

  func smcGetIdentity(reply: SMCFanHelperIdentityReply) {
    identityRequestContinuation.yield()
    switch replyMode {
    case .success:
      reply(true, "0.4.0-test", "42", "abcdef0123456789", "0123456789abcdef", 1, nil)
    case .withhold:
      break
    }
  }

  func waitForIdentityRequest() async {
    for await _ in identityRequests {
      return
    }
  }

  func smcOpen(reply: (Bool, String?) -> Void) {
    openCallCountLock.lock()
    storedOpenCallCount += 1
    openCallCountLock.unlock()
    reply(true, nil)
  }

  func smcClose(reply: (Bool, String?) -> Void) {
    reply(true, nil)
  }

  func smcReadKey(
    _: String,
    reply: (Bool, Float, String?) -> Void
  ) {
    reply(false, 0, "Not implemented")
  }

  func smcReadKeys(
    _ keys: [String],
    reply: ([Bool], [Float], [String]) -> Void
  ) {
    reply(
      Array(repeating: false, count: keys.count),
      Array(repeating: 0, count: keys.count),
      Array(repeating: "Not implemented", count: keys.count)
    )
  }

  func smcWriteKey(
    _: String,
    value _: Float,
    reply: (Bool, String?) -> Void
  ) {
    reply(false, "Not implemented")
  }

  func smcGetFanCount(reply: (Bool, UInt, String?) -> Void) {
    reply(false, 0, "Not implemented")
  }

  func smcGetFanInfo(
    _: UInt,
    reply: (Bool, Float, Float, Float, Float, Bool, String?) -> Void
  ) {
    reply(false, 0, 0, 0, 0, false, "Not implemented")
  }

  func smcSetFanRPM(
    _: UInt,
    rpm _: Float,
    priority _: Int,
    reply: (Bool, Bool, String?) -> Void
  ) {
    reply(false, false, "Not implemented")
  }

  func smcSetFanAuto(
    _: UInt,
    priority _: Int,
    reply: (Bool, Bool, String?) -> Void
  ) {
    reply(false, false, "Not implemented")
  }

  func smcEnumerateKeys(reply: ([String]) -> Void) {
    reply([])
  }

  func smcRegisterClient(
    name _: String,
    reply: (Bool, String?) -> Void
  ) {
    reply(true, nil)
  }

  func smcGetOwnership(
    reply: ([UInt], [String], [Int], [Double]) -> Void
  ) {
    reply([], [], [], [])
  }
}
