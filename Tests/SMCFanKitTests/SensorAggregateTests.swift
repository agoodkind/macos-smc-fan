//
//  SensorAggregateTests.swift
//  SMCFanKitTests
//

import Foundation
import Testing

@testable import SMCFanKit

@Suite("SensorAggregate")
struct SensorAggregateTests {

  @Test("power-gated cores (2-3C) are excluded from the average")
  func gatedCoresExcluded() {
    // The exact Mac16,7 dump that pinned the ramp at min RPM: 2 E-cores hot,
    // 6 P-cores gated. Naive mean = 17.1C; the E-core mean is what MFC shows.
    let readings: [Float] = [60.41, 59.49, 3.4, 2.2, 3.4, 2.2, 2.2, 3.4]
    let avg = SensorAggregate.average(readings)
    #expect(avg != nil)
    #expect(abs(avg! - 59.95) < 0.01)
  }

  @Test("all cores active averages every reading")
  func allActiveAveraged() {
    let avg = SensorAggregate.average([70, 72, 68, 66])
    #expect(avg == 69)
  }

  @Test("no plausible reading yields nil (fail-safe, never a number)")
  func nothingPlausibleIsNil() {
    #expect(SensorAggregate.average([2.2, 3.4, 0, -1]) == nil)
    #expect(SensorAggregate.average([]) == nil)
  }

  @Test("readings above 150C are treated as sensor garbage")
  func absurdHighExcluded() {
    #expect(SensorAggregate.average([65, 999]) == 65)
  }

  @Test("floor is exclusive and configurable")
  func floorIsExclusive() {
    #expect(SensorAggregate.average([10, 50]) == 50)
    #expect(SensorAggregate.average([10, 50], floorC: 5) == 30)
  }
}
