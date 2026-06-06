//
//  SMCDataFormatTests.swift
//  SMCKitTests
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026, all rights reserved.
//

import Nimble
import XCTest
@testable import SMCKit

/// Unit tests for SMC data format conversions.
/// Tests the production SMCDataFormat code without requiring hardware access.
final class SMCDataFormatTests: XCTestCase {

  // MARK: - Apple Silicon Float Format (IEEE 754, little-endian)

  func testBytesToFloat_AppleSilicon() {
    let bytes: [UInt8] = [
      0x00, 0xD0, 0x10, 0x45, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
    let result = SMCDataFormat.float(from: bytes, size: 4)
    expect(result).to(beCloseTo(2_317.0, within: 0.1))
  }

  func testBytesToFloat_AppleSilicon_HighRPM() {
    var expected: Float = 7_826.0
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    withUnsafeBytes(of: &expected) { srcBytes in
      for i in 0..<4 { bytes[i] = srcBytes[i] }
    }
    let result = SMCDataFormat.float(from: bytes, size: 4)
    expect(result).to(beCloseTo(7_826.0, within: 0.1))
  }

  func testFloatToBytes_AppleSilicon() {
    let bytes = SMCDataFormat.bytes(from: 2_317.0, size: 4)
    expect(bytes.count) == 4

    var paddedBytes = bytes
    paddedBytes.append(contentsOf: [UInt8](repeating: 0, count: 28))
    let result = SMCDataFormat.float(from: paddedBytes, size: 4)
    expect(result).to(beCloseTo(2_317.0, within: 0.1))
  }

  func testFloatToBytes_Roundtrip_AppleSilicon() {
    let testValues: [Float] = [0.0, 1_000.0, 2_317.0, 5_000.0, 7_826.0]
    for value in testValues {
      let bytes = SMCDataFormat.bytes(from: value, size: 4)
      var paddedBytes = bytes
      paddedBytes.append(contentsOf: [UInt8](repeating: 0, count: 28))
      let result = SMCDataFormat.float(from: paddedBytes, size: 4)
      expect(result).to(beCloseTo(value, within: 0.01), description: "Roundtrip failed for \(value)")
    }
  }

  // MARK: - Intel fpe2 Format (14.2 fixed-point, big-endian)

  func testBytesToFloat_Intel_fpe2() {
    let bytes: [UInt8] = [
      0x24, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
    let result = SMCDataFormat.float(from: bytes, size: 2)
    expect(result).to(beCloseTo(2_317.0, within: 0.5))
  }

  func testFloatToBytes_Intel_fpe2() {
    let bytes = SMCDataFormat.bytes(from: 2_317.0, size: 2)
    expect(bytes.count) == 2
    expect(bytes[0]) == 0x24
    expect(bytes[1]) == 0x34
  }

  func testFloatToBytes_Roundtrip_Intel() {
    let testValues: [Float] = [0.0, 1_000.0, 2_317.0, 5_000.0, 7_826.0]
    for value in testValues {
      let bytes = SMCDataFormat.bytes(from: value, size: 2)
      var paddedBytes = bytes
      paddedBytes.append(contentsOf: [UInt8](repeating: 0, count: 30))
      let result = SMCDataFormat.float(from: paddedBytes, size: 2)
      expect(result).to(beCloseTo(value, within: 0.5), description: "Roundtrip failed for \(value)")
    }
  }

  // MARK: - Edge Cases

  func testBytesToFloat_ZeroRPM() {
    let bytes: [UInt8] = Array(repeating: 0, count: 32)
    expect(SMCDataFormat.float(from: bytes, size: 4)) == 0.0
    expect(SMCDataFormat.float(from: bytes, size: 2)) == 0.0
  }

  func testFloatToBytes_ZeroRPM() {
    let bytes4 = SMCDataFormat.bytes(from: 0.0, size: 4)
    let bytes2 = SMCDataFormat.bytes(from: 0.0, size: 2)
    expect(bytes4.allSatisfy { $0 == 0 }) == true
    expect(bytes2.allSatisfy { $0 == 0 }) == true
  }

  func testBytesToFloat_UndersizedArray() {
    // Should not crash with fewer than expected bytes
    expect(SMCDataFormat.float(from: [], size: 4)) == 0
    expect(SMCDataFormat.float(from: [1], size: 4)) == 0
    expect(SMCDataFormat.float(from: [], size: 2)) == 0
    expect(SMCDataFormat.float(from: [1], size: 2)) == 0
  }
}
