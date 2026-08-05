//
//  RequestScopeTestHelper.swift
//  SMCFanXPCClientTests
//
//  Created by Codex <noreply@openai.com> on 2026-08-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SMCFanProtocol

private let requestTestFanCount: UInt = 2

// MARK: - RequestCounts

struct RequestCounts: Equatable, Sendable {
  var open = 0, register = 0, fanCount = 0, setFanAuto = 0
}

// MARK: - AutoRequest

struct AutoRequest: Equatable, Sendable {
  let fanIndex: UInt
  let priority: Int
}

// MARK: - RequestScopeTestHelper

final class RequestScopeTestHelper: NSObject, SMCFanHelperProtocol, @unchecked Sendable {
  enum AutoReply {
    case conflict
    case success
    case withhold
  }

  enum BasicReply {
    case failure(String)
    case success
    case withhold
  }

  private let autoReply: AutoReply
  private let autoRequests: AsyncStream<Void>
  private let autoRequestContinuation: AsyncStream<Void>.Continuation
  private let fanCountReply: BasicReply
  private let fanCountRequests: AsyncStream<Void>
  private let fanCountRequestContinuation: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private let openReply: BasicReply
  private let openRequests: AsyncStream<Void>
  private let openRequestContinuation: AsyncStream<Void>.Continuation
  private var storedCounts = RequestCounts()
  private var storedLastAutoRequest: AutoRequest?
  private var storedLastRegistration: String?
  private var withheldAutoReply: ((Bool, Bool, String?) -> Void)?

  init(
    autoReply: AutoReply,
    fanCountReply: BasicReply = .success,
    openReply: BasicReply = .success
  ) {
    let (autoRequestStream, autoContinuation) = AsyncStream.makeStream(of: Void.self)
    let (fanCountRequestStream, fanCountContinuation) = AsyncStream.makeStream(of: Void.self)
    let (openRequestStream, openContinuation) = AsyncStream.makeStream(of: Void.self)
    self.autoReply = autoReply
    self.autoRequests = autoRequestStream
    self.autoRequestContinuation = autoContinuation
    self.fanCountReply = fanCountReply
    self.fanCountRequests = fanCountRequestStream
    self.fanCountRequestContinuation = fanCountContinuation
    self.openReply = openReply
    self.openRequests = openRequestStream
    self.openRequestContinuation = openContinuation
  }

  var counts: RequestCounts {
    lock.lock()
    let snapshot = storedCounts
    lock.unlock()
    return snapshot
  }

  var lastAutoRequest: AutoRequest? {
    lock.lock()
    let latestRequest = storedLastAutoRequest
    lock.unlock()
    return latestRequest
  }

  var lastRegistration: String? {
    lock.lock()
    let registration = storedLastRegistration
    lock.unlock()
    return registration
  }

  func smcGetIdentity(reply: SMCFanHelperIdentityReply) {
    reply(true, "0.4.1-test", "43", "abcdef0123456789", "0123456789abcdef", 1, nil)
  }

  func smcOpen(reply: (Bool, String?) -> Void) {
    lock.lock()
    storedCounts.open += 1
    lock.unlock()
    openRequestContinuation.yield()
    switch openReply {
    case .failure(let message):
      reply(false, message)
    case .success:
      reply(true, nil)
    case .withhold:
      break
    }
  }

  func smcClose(reply: (Bool, String?) -> Void) {
    reply(true, nil)
  }

  func smcReadKey(_: String, reply: (Bool, Float, String?) -> Void) {
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

  func smcWriteKey(_: String, value _: Float, reply: (Bool, String?) -> Void) {
    reply(false, "Not implemented")
  }

  func smcGetFanCount(reply: (Bool, UInt, String?) -> Void) {
    lock.lock()
    storedCounts.fanCount += 1
    lock.unlock()
    fanCountRequestContinuation.yield()
    switch fanCountReply {
    case .failure(let message):
      reply(false, 0, message)
    case .success:
      reply(true, requestTestFanCount, nil)
    case .withhold:
      break
    }
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
    _ fanIndex: UInt,
    priority: Int,
    reply: @escaping (Bool, Bool, String?) -> Void
  ) {
    lock.lock()
    storedCounts.setFanAuto += 1
    storedLastAutoRequest = AutoRequest(fanIndex: fanIndex, priority: priority)
    if case .withhold = autoReply {
      withheldAutoReply = reply
    }
    lock.unlock()
    autoRequestContinuation.yield()

    switch autoReply {
    case .conflict:
      reply(false, true, "owned by lmd")
    case .success:
      reply(true, false, nil)
    case .withhold:
      break
    }
  }

  func smcEnumerateKeys(reply: ([String]) -> Void) {
    reply([])
  }

  func smcRegisterClient(name: String, reply: (Bool, String?) -> Void) {
    lock.lock()
    storedCounts.register += 1
    storedLastRegistration = name
    lock.unlock()
    reply(true, nil)
  }

  func smcGetOwnership(reply: ([UInt], [String], [Int], [Double]) -> Void) {
    reply([], [], [], [])
  }

  func waitForAutoRequest() async {
    for await _ in autoRequests {
      return
    }
  }

  func waitForFanCountRequest() async {
    for await _ in fanCountRequests {
      return
    }
  }

  func waitForOpenRequest() async {
    for await _ in openRequests {
      return
    }
  }

  func releaseAutoReply() {
    lock.lock()
    let reply = withheldAutoReply
    withheldAutoReply = nil
    lock.unlock()
    reply?(true, false, nil)
  }
}
