//
//  ResumeGuardTests.swift
//  SMCFanXPCClientTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-20.
//  Copyright © 2026
//
//  Unit tests for the exactly once semantics of ResumeGuard. The XPC client's
//  continuation safety depends on this invariant.
//

import Testing
import Foundation
@testable import SMCFanXPCClient

@Suite("ResumeGuard")
struct ResumeGuardTests {
  @Test("first tryResume fires the action")
  func firstFires() {
    let guardGate = ResumeGuard()
    var count = 0
    guardGate.tryResume { count += 1 }
    #expect(count == 1)
    #expect(guardGate.hasFired)
  }

  @Test("second tryResume is a no op")
  func secondIsNoOp() {
    let guardGate = ResumeGuard()
    var count = 0
    guardGate.tryResume { count += 1 }
    guardGate.tryResume { count += 1 }
    #expect(count == 1)
  }

  @Test("concurrent tryResume fires exactly once")
  func concurrentFiresOnce() async {
    let guardGate = ResumeGuard()
    let counter = Counter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<64 {
        group.addTask {
          guardGate.tryResume { counter.increment() }
        }
      }
    }
    #expect(counter.value == 1)
  }
}

/// Thread safe counter for the concurrent test.
private final class Counter: @unchecked Sendable {
  private var _value = 0
  private let lock = NSLock()
  func increment() {
    lock.lock()
    _value += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    let v = _value
    lock.unlock()
    return v
  }
}
