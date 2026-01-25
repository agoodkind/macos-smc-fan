//
//  SMC.swift
//  SMCFanHelper
//
//  Low-level interface to Apple's System Management Controller via IOKit.
//
//  Created by Alex Goodkind on 2026-01-24.
//

import Foundation
import IOKit

// MARK: - SMC Types

/// SMC command selectors for IOConnectCallStructMethod
private enum SMCCommand: UInt8 {
  case kernelIndex = 2
  case readBytes = 5
  case writeBytes = 6
  case readKeyInfo = 9
}

/// SMC firmware result codes (from VirtualSMC SDK - AppleSmc.h)
/// These are returned in output.result field, distinct from IOKit return values.
enum SMCResultCode: UInt8 {
  case success = 0x00
  case error = 0x01
  case commCollision = 0x80       // Communication collision
  case spuriousData = 0x81        // Unexpected data
  case badCommand = 0x82          // Firmware rejected (e.g., write to F%dMd in Mode 3)
  case badParameter = 0x83        // Invalid parameter value
  case notFound = 0x84            // Key does not exist
  case notReadable = 0x85         // Key is write-only
  case notWritable = 0x86         // Key is read-only
  case keySizeMismatch = 0x87     // Data size mismatch
  case framingError = 0x88        // Protocol framing error
  case badArgumentError = 0x89    // Bad argument to SMC function
}

/// Well-known SMC keys for fan control
enum SMCFanKey {
  static let count = "FNum"
  static let actual = "F%dAc"
  static let target = "F%dTg"
  static let minimum = "F%dMn"
  static let maximum = "F%dMx"
  static let mode = "F%dMd"
  static let forceTest = "Ftst"

  static func key(_ template: String, fan: Int) -> String {
    String(format: template, fan)
  }
}

// MARK: - SMC Data Structures

/// 80-byte structure matching AppleSMC kernel interface
private struct SMCParamStruct {
  typealias Bytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  )

  struct Version {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
  }

  struct PLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
  }

  struct KeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
  }

  var key: UInt32 = 0
  var vers = Version()
  var pLimitData = PLimitData()
  var keyInfo = KeyInfo()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: Bytes32 = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  )
}

// MARK: - SMC Interface

/// Interface to Apple's System Management Controller
final class SMCConnection {

  private let connection: io_connect_t

  // MARK: Initialization

  init?() {
    var iterator: io_iterator_t = 0
    defer { IOObjectRelease(iterator) }

    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC"),
        &iterator
      ) == kIOReturnSuccess
    else {
      return nil
    }

    let service = IOIteratorNext(iterator)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var conn: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
      return nil
    }

    self.connection = conn
  }

  deinit {
    IOServiceClose(connection)
  }

  // MARK: Public Interface

  /// Read raw bytes from an SMC key
  func readKey(_ key: String) -> (kern_return_t, [UInt8], UInt32) {
    var param = SMCParamStruct()
    var output = SMCParamStruct()

    let result = fetchKeyInfo(key, into: &param, output: &output)
    guard result == kIOReturnSuccess else { return (result, [], 0) }

    let dataSize = output.keyInfo.dataSize
    param.keyInfo.dataSize = dataSize
    param.data8 = SMCCommand.readBytes.rawValue

    let readResult = callSMC(input: &param, output: &output)
    guard readResult == kIOReturnSuccess else { return (readResult, [], 0) }

    let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(dataSize))) }
    return (kIOReturnSuccess, bytes, dataSize)
  }

  /// Write raw bytes to an SMC key
  func writeKey(_ key: String, bytes: [UInt8]) -> kern_return_t {
    var param = SMCParamStruct()
    var output = SMCParamStruct()

    let result = fetchKeyInfo(key, into: &param, output: &output)
    guard result == kIOReturnSuccess else { return result }

    param.data8 = SMCCommand.writeBytes.rawValue
    param.keyInfo.dataSize = output.keyInfo.dataSize
    param.bytes = bytesToTuple(bytes)

    let writeResult = callSMC(input: &param, output: &output)
    guard writeResult == kIOReturnSuccess else { return writeResult }

    // IOKit may return success even when SMC firmware rejects the write
    return output.result == SMCResultCode.success.rawValue ? kIOReturnSuccess : kIOReturnError
  }

  // MARK: Private Helpers

  private func fetchKeyInfo(
    _ key: String, into param: inout SMCParamStruct, output: inout SMCParamStruct
  ) -> kern_return_t {
    param.key = fourCharCode(from: key)
    param.data8 = SMCCommand.readKeyInfo.rawValue
    return callSMC(input: &param, output: &output)
  }

  private func callSMC(input: inout SMCParamStruct, output: inout SMCParamStruct) -> kern_return_t {
    var outputSize = MemoryLayout<SMCParamStruct>.stride
    return IOConnectCallStructMethod(
      connection,
      UInt32(SMCCommand.kernelIndex.rawValue),
      &input,
      MemoryLayout<SMCParamStruct>.stride,
      &output,
      &outputSize
    )
  }

  private func fourCharCode(from string: String) -> UInt32 {
    precondition(string.count == 4, "SMC keys must be exactly 4 characters")
    return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private func bytesToTuple(_ array: [UInt8]) -> SMCParamStruct.Bytes32 {
    var padded = array + Array(repeating: 0, count: max(0, 32 - array.count))
    if padded.count > 32 { padded = Array(padded.prefix(32)) }

    return (
      padded[0], padded[1], padded[2], padded[3],
      padded[4], padded[5], padded[6], padded[7],
      padded[8], padded[9], padded[10], padded[11],
      padded[12], padded[13], padded[14], padded[15],
      padded[16], padded[17], padded[18], padded[19],
      padded[20], padded[21], padded[22], padded[23],
      padded[24], padded[25], padded[26], padded[27],
      padded[28], padded[29], padded[30], padded[31]
    )
  }
}
