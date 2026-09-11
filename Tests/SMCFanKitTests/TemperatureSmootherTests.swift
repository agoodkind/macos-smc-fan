//
//  TemperatureSmootherTests.swift
//  SMCFanKitTests
//
//  Timestamps are plain monotonic seconds, so every case controls elapsed
//  time exactly.
//

import Foundation
import Testing

@testable import SMCFanKit

@Suite("TemperatureSmoother")
struct TemperatureSmootherTests {

  private let t0: TimeInterval = 1000

  @Test("first sample passes through unchanged")
  func firstSamplePassthrough() {
    let smoother = TemperatureSmoother(tau: 20)
    let out = smoother.update(50, now: t0)
    #expect(out == 50)
  }

  @Test("a step input converges with the expected time constant")
  func stepConverges() {
    // alpha = min(1, dt / tau): linear in elapsed time, clamped at 1.
    let smoother = TemperatureSmoother(tau: 20)
    _ = smoother.update(45, now: t0)

    // After half a tau (10s), alpha = 0.5: 45 + 0.5 * (75 - 45) = 60.
    let afterHalfTau = smoother.update(75, now: t0 + 10)!
    #expect(abs(afterHalfTau - 60) < 0.01)

    // A full tau or more since the last sample clamps alpha to 1.
    let afterOneTau = smoother.update(75, now: t0 + 10 + 20)!
    #expect(abs(afterOneTau - 75) < 0.01)
  }

  @Test("a single spike moves the output by at most a tau-proportional fraction")
  func spikeIsDamped() {
    let smoother = TemperatureSmoother(tau: 20)
    _ = smoother.update(50, now: t0)

    // One 2s poll later a 10C spike arrives: alpha = 2 / 20 = 0.1, so the
    // output moves by ~1C, not 10C.
    let out = smoother.update(60, now: t0 + 2)!
    #expect(out > 50 && out < 52)
  }

  @Test("tau of 0 disables smoothing")
  func tauZeroDisablesSmoothing() {
    let smoother = TemperatureSmoother(tau: 0)
    _ = smoother.update(50, now: t0)
    let out = smoother.update(90, now: t0 + 2)
    #expect(out == 90)
  }

  @Test("an implausible (nil) reading leaves the smoothed value unchanged")
  func nilReadingHoldsLastValue() {
    let smoother = TemperatureSmoother(tau: 20)
    _ = smoother.update(55, now: t0)
    let held = smoother.update(nil, now: t0 + 2)
    #expect(held == 55)
  }

  @Test("nil before any sample returns nil")
  func nilBeforeAnySampleReturnsNil() {
    let smoother = TemperatureSmoother(tau: 20)
    #expect(smoother.update(nil) == nil)
  }

  @Test("a timestamp that does not advance is ignored")
  func nonAdvancingTimeIsIgnored() {
    let smoother = TemperatureSmoother(tau: 20)
    _ = smoother.update(50, now: t0)
    #expect(smoother.update(90, now: t0) == 50)
    #expect(smoother.update(90, now: t0 - 5) == 50)

    // The next real interval is measured from the last accepted sample.
    let out = smoother.update(60, now: t0 + 2)!
    #expect(out > 50 && out < 52)
  }

  @Test("reset clears state, next sample passes through again")
  func resetClearsState() {
    let smoother = TemperatureSmoother(tau: 20)
    _ = smoother.update(50, now: t0)
    _ = smoother.update(80, now: t0 + 2)
    smoother.reset()
    let out = smoother.update(20, now: t0 + 4)
    #expect(out == 20)
  }
}
