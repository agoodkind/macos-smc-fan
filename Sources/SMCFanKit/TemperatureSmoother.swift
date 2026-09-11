//
//  TemperatureSmoother.swift
//  SMCFanKit
//
//  Exponential smoothing for a temperature that feeds a fan curve.
//  On an M4 Pro, cpu_core_average sampled every 2s jumps >=5C in ~40% of
//  polls and >=10C in ~17% (P-core power-gating noise, not real thermal
//  swings), so a raw reading on a linear curve swings the fan target up to
//  ~1500 RPM per poll. A ~20s time constant, replayed against an hour of
//  real readings, cut >=300 RPM/poll steps from 685/1369 to 35 and
//  >=800 RPM steps from 439 to 0. No SMC access, no side effects.
//
//  Elapsed-time based, not a fixed per-call alpha: a poll interval is not
//  guaranteed exact (scheduling jitter, callers with different intervals),
//  so alpha is derived from the elapsed time between samples:
//  alpha = min(1, dt / tau). tau == 0 disables smoothing.
//

import Foundation

/// Smooths a stream of temperature readings with an exponential moving
/// average of time constant `tau` seconds. Not thread-safe; callers own one
/// instance per sensor stream and serialize access to it.
public final class TemperatureSmoother {

  private let tau: TimeInterval
  private var smoothed: Float?
  private var lastSampleTime: TimeInterval?

  /// - Parameter tau: time constant in seconds. `0` disables smoothing (the
  ///   output tracks the raw input on every sample).
  public init(tau: TimeInterval) {
    self.tau = max(0, tau)
  }

  /// Feed one raw reading and get back the smoothed value.
  ///
  /// - The first sample always passes through unchanged (nothing to blend
  ///   with yet).
  /// - An implausible reading (`nil`, meaning the caller had no plausible
  ///   sample this poll - see `SensorAggregate.average`) leaves the smoothed
  ///   value unchanged and returns it as-is, so one bad poll never yanks the
  ///   ramp toward a garbage reading.
  /// - Otherwise blends the new sample in with `alpha = min(1, dt / tau)`,
  ///   where `dt` is the elapsed time since the previous sample. `tau == 0`
  ///   makes `alpha` always `1`, i.e. no smoothing.
  /// - A sample whose time does not advance past the previous one is ignored
  ///   and the current value is returned unchanged.
  ///
  /// - Parameters:
  ///   - raw: the raw reading, or `nil` when no plausible reading exists.
  ///   - now: a monotonic timestamp in seconds. Defaults to
  ///     `ProcessInfo.processInfo.systemUptime`, which a wall-clock
  ///     adjustment cannot move backwards.
  /// - Returns: the smoothed value, or `nil` if there has never been a
  ///   plausible sample.
  @discardableResult
  public func update(
    _ raw: Float?, now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Float? {
    guard let raw else { return smoothed }

    guard let previous = smoothed, let lastTime = lastSampleTime else {
      smoothed = raw
      lastSampleTime = now
      return smoothed
    }

    let dt = now - lastTime
    // A non-advancing timestamp would give alpha <= 0 and re-base the next
    // interval on the wrong time; hold the value instead.
    guard dt > 0 else { return previous }
    let alpha: Float
    if tau <= 0 {
      alpha = 1
    } else {
      alpha = Float(min(1, dt / tau))
    }

    let next = previous + alpha * (raw - previous)
    smoothed = next
    lastSampleTime = now
    return next
  }

  /// Resets to a fresh, un-primed state (as if newly constructed). Call this
  /// when the sensor/mode changes, or when leaving/entering ramp - carrying
  /// a stale smoothed value across a mode switch would blend unrelated data.
  public func reset() {
    smoothed = nil
    lastSampleTime = nil
  }
}
