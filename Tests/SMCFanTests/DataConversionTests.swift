//
//  DataConversionTests.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import XCTest

/// Unit tests for SMC data format conversions
/// These test the pure Swift logic without requiring hardware access
final class DataConversionTests: XCTestCase {

  // MARK: - Apple Silicon Float Format (IEEE 754, little-endian)

  func testBytesToFloat_AppleSilicon() {
    // IEEE 754 float: 2317.0 = 0x4510D000 (big-endian) = [0x00, 0xD0, 0x10, 0x45] (little-endian)
    let bytes: [UInt8] = [
      0x00, 0xD0, 0x10, 0x45, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
    let result = bytesToFloat(bytes, size: 4)
    XCTAssertEqual(result, 2317.0, accuracy: 0.1)
  }

  func testBytesToFloat_AppleSilicon_HighRPM() {
    // 7826.0 RPM (typical max)
    var expected: Float = 7826.0
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    withUnsafeBytes(of: &expected) { srcBytes in
      for i in 0..<4 { bytes[i] = srcBytes[i] }
    }

    let result = bytesToFloat(bytes, size: 4)
    XCTAssertEqual(result, 7826.0, accuracy: 0.1)
  }

  func testFloatToBytes_AppleSilicon() {
    let bytes = floatToBytes(2317.0, size: 4)
    XCTAssertEqual(bytes.count, 4)

    // Convert back to verify
    var paddedBytes = bytes
    paddedBytes.append(contentsOf: [UInt8](repeating: 0, count: 28))
    let result = bytesToFloat(paddedBytes, size: 4)
    XCTAssertEqual(result, 2317.0, accuracy: 0.1)
  }

  func testFloatToBytes_Roundtrip_AppleSilicon() {
    let testValues: [Float] = [0.0, 1000.0, 2317.0, 5000.0, 7826.0]

    for value in testValues {
      let bytes = floatToBytes(value, size: 4)
      var paddedBytes = bytes
      paddedBytes.append(contentsOf: [UInt8](repeating: 0, count: 28))
      let result = bytesToFloat(paddedBytes, size: 4)
      XCTAssertEqual(result, value, accuracy: 0.01, "Roundtrip failed for \(value)")
    }
  }

  // MARK: - Intel fpe2 Format (14.2 fixed-point, big-endian)

  func testBytesToFloat_Intel_fpe2() {
    // fpe2: 2317 RPM = 2317 * 4 = 9268 = 0x2434
    // Big-endian: [0x24, 0x34]
    let bytes: [UInt8] = [
      0x24, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]
    let result = bytesToFloat(bytes, size: 2)
    XCTAssertEqual(result, 2317.0, accuracy: 0.5)
  }

  func testFloatToBytes_Intel_fpe2() {
    let bytes = floatToBytes(2317.0, size: 2)
    XCTAssertEqual(bytes.count, 2)

    // Verify: 2317 * 4 = 9268 = 0x2434
    XCTAssertEqual(bytes[0], 0x24)
    XCTAssertEqual(bytes[1], 0x34)
  }

  func testFloatToBytes_Roundtrip_Intel() {
    let testValues: [Float] = [0.0, 1000.0, 2317.0, 5000.0, 7826.0]

    for value in testValues {
      let bytes = floatToBytes(value, size: 2)
      var paddedBytes = bytes
      paddedBytes.append(contentsOf: [UInt8](repeating: 0, count: 30))
      let result = bytesToFloat(paddedBytes, size: 2)
      // fpe2 has 0.25 RPM resolution, so allow 0.5 tolerance
      XCTAssertEqual(result, value, accuracy: 0.5, "Roundtrip failed for \(value)")
    }
  }

  // MARK: - Edge Cases

  func testBytesToFloat_ZeroRPM() {
    let bytes: [UInt8] = Array(repeating: 0, count: 32)

    XCTAssertEqual(bytesToFloat(bytes, size: 4), 0.0)
    XCTAssertEqual(bytesToFloat(bytes, size: 2), 0.0)
  }

  func testFloatToBytes_ZeroRPM() {
    let bytes4 = floatToBytes(0.0, size: 4)
    let bytes2 = floatToBytes(0.0, size: 2)

    XCTAssertTrue(bytes4.allSatisfy { $0 == 0 })
    XCTAssertTrue(bytes2.allSatisfy { $0 == 0 })
  }
}

// MARK: - Test Helpers (duplicated from main.swift for testing)
// In a real project, these would be in a shared module

private func bytesToFloat(_ bytes: [UInt8], size: UInt32) -> Float {
  if size == 4 {
    return bytes.withUnsafeBytes { $0.load(as: Float.self) }
  } else {
    let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    return Float(raw) / 4.0
  }
}

private func floatToBytes(_ value: Float, size: UInt32) -> [UInt8] {
  var result = [UInt8](repeating: 0, count: Int(size))
  if size == 4 {
    withUnsafeBytes(of: value) { bytes in
      for i in 0..<4 { result[i] = bytes[i] }
    }
  } else {
    let raw = UInt16(value * 4.0)
    result[0] = UInt8(raw >> 8)
    result[1] = UInt8(raw & 0xFF)
  }
  return result
}
