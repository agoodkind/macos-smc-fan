//
//  SensorAggregate.swift
//  SMCFanKit
//
//  Averages a set of temperature sensors (e.g. the CPU core sensors behind a
//  cpu_core_average), dropping implausible readings, so every consumer that
//  reports or acts on the aggregate gets the same number. Pure math, unit
//  tested.
//

import Foundation

/// Aggregates of several temperature sensors that ignore implausible
/// readings, such as power-gated cores reporting a few degrees Celsius.
public enum SensorAggregate {

  /// Readings at or below this are not a temperature of running silicon.
  /// Witnessed on Mac16,7 2026-09-05: the six P-core sensors (Tp*) report
  /// 2.2-3.4C while those cores are power-gated, the E-cores read 60C at the
  /// same moment. Averaging the gated cores in dragged cpu_core_average from
  /// 68C to 17C within one 2s poll and pinned the ramp at minimum RPM under
  /// load. 10C is below any plausible chip temperature in a room and above every
  /// gated-core artefact seen, so it separates the two without tuning.
  public static let plausibleFloorC: Float = 10

  /// Mean of the plausible readings. `nil` when no reading is plausible
  /// (or none was given) - the caller treats that as "sensor unavailable"
  /// and fails safe to auto rather than ramping on garbage.
  public static func average(_ readings: [Float], floorC: Float = plausibleFloorC) -> Float? {
    let plausible = readings.filter { $0 > floorC && $0 < 150 }
    guard !plausible.isEmpty else { return nil }
    return plausible.reduce(0, +) / Float(plausible.count)
  }
}
