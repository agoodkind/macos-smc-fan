//
//  SMCConnection.swift
//  SMCKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-24.
//  Copyright © 2026
//

import Foundation
import IOKit
import os

// MARK: - Logging Helpers

private let smcLog = OSLog(subsystem: "com.smckit", category: "smc")

private func logDebug(_ message: String, function: String = #function) {
  os_log(.debug, log: smcLog, "%{public}s: %{public}s", function, message)
}

private func logError(_ message: String, function: String = #function) {
  os_log(.error, log: smcLog, "%{public}s: %{public}s", function, message)
}

// MARK: - SMC Interface

/// Interface to Apple's System Management Controller
public final class SMCConnection: @unchecked Sendable {

  private let connection: io_connect_t

  // MARK: Initialization

  public init() throws {
    var iterator: io_iterator_t = 0
    defer { IOObjectRelease(iterator) }

    let mainPort: mach_port_t
    if #available(macOS 12.0, *) {
      mainPort = kIOMainPortDefault
    } else {
      mainPort = kIOMasterPortDefault
    }

    guard
      IOServiceGetMatchingServices(
        mainPort,
        IOServiceMatching("AppleSMC"),
        &iterator
      ) == kIOReturnSuccess
    else {
      throw SMCError.connectionFailed
    }

    let service = IOIteratorNext(iterator)
    guard service != 0 else {
      throw SMCError.connectionFailed
    }
    defer { IOObjectRelease(service) }

    var conn: io_connect_t = 0
    let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
    guard openResult == kIOReturnSuccess else {
      throw SMCError.connectionFailed
    }

    self.connection = conn

    let model = SMCConnection.hardwareModel()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    logDebug("connection=\(conn) model=\(model) os=\(osVersion)")
  }

  deinit {
    IOServiceClose(connection)
  }

  // MARK: Public Interface

  /// Read raw bytes from an SMC key
  public func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
    let (param, output) = try fetchKeyInfo(key)

    let dataSize = output.keyInfo.dataSize
    var readParam = param
    readParam.keyInfo.dataSize = dataSize
    readParam.data8 = SMCCommand.readBytes.rawValue

    let readOutput = try callSMC(input: readParam)

    let bytes = withUnsafeBytes(of: readOutput.bytes) {
      Array($0.prefix(Int(dataSize)))
    }

    let preview = bytes.prefix(4).map { String(format: "0x%02x", $0) }.joined(separator: " ")
    logDebug("key=\(key) size=\(dataSize) bytes=[\(preview)\(bytes.count > 4 ? "..." : "")]")

    return (bytes, dataSize)
  }

  /// Write raw bytes to an SMC key
  public func writeKey(_ key: String, bytes: [UInt8]) throws {
    let preview = bytes.prefix(4).map { String(format: "0x%02x", $0) }.joined(separator: " ")
    logDebug("key=\(key) bytes=[\(preview)\(bytes.count > 4 ? "..." : "")]")

    let (param, output) = try fetchKeyInfo(key)

    var writeParam = param
    writeParam.data8 = SMCCommand.writeBytes.rawValue
    writeParam.keyInfo.dataSize = output.keyInfo.dataSize
    writeParam.bytes = bytesToTuple(bytes)

    let writeOutput = try callSMC(input: writeParam)

    if writeOutput.result != SMCResultCode.success.rawValue {
      guard let resultCode = SMCResultCode(rawValue: writeOutput.result) else {
        logError("key=\(key) unknown result=0x\(String(writeOutput.result, radix: 16))")
        throw SMCError.firmware(.error)
      }
      logError("key=\(key) firmware error=\(resultCode)")
      throw SMCError.firmware(resultCode)
    }

    logDebug("key=\(key) write succeeded")
  }

  /// Enumerate all SMC keys by reading the #KEY count and iterating with readIndex.
  public func enumerateKeys() -> [String] {
    guard let (countBytes, countSize) = try? readKey("#KEY"), countSize >= 4 else {
      logError("failed to read #KEY count")
      return []
    }
    let totalKeys = countBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
    logDebug("total key count=\(totalKeys)")

    var keys: [String] = []
    for i in 0..<totalKeys {
      var inp = SMCParamStruct()
      inp.data8 = SMCCommand.readIndex.rawValue
      inp.data32 = UInt32(i)
      guard let out = try? callSMC(input: inp) else {
        continue
      }
      let keyU32 = out.key
      let chars = [
        Character(UnicodeScalar((keyU32 >> 24) & 0xFF)!),
        Character(UnicodeScalar((keyU32 >> 16) & 0xFF)!),
        Character(UnicodeScalar((keyU32 >> 8) & 0xFF)!),
        Character(UnicodeScalar(keyU32 & 0xFF)!),
      ]
      keys.append(String(chars))
    }

    logDebug("enumerated \(keys.count) keys")
    return keys
  }

  /// Get the hardware model string
  public static func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
  }

  // MARK: Public Helpers

  /// Fetch key information from SMC
  public func fetchKeyInfo(
    _ key: String
  ) throws -> (param: SMCParamStruct, output: SMCParamStruct) {
    var param = SMCParamStruct()
    param.key = fourCharCode(from: key)
    param.data8 = SMCCommand.readKeyInfo.rawValue
    let output = try callSMC(input: param)

    let dataType = withUnsafeBytes(of: output.keyInfo.dataType.bigEndian) {
      String(bytes: $0, encoding: .ascii) ?? "????"
    }
    if output.result != SMCResultCode.success.rawValue {
      let resultDesc = SMCResultCode(rawValue: output.result).map { "\($0)" } ?? "0x\(String(output.result, radix: 16))"
      logError("key=\(key) result=\(resultDesc) dataSize=\(output.keyInfo.dataSize) dataType=\(dataType)")
    } else {
      logDebug("key=\(key) dataSize=\(output.keyInfo.dataSize) dataType=\(dataType)")
    }

    return (param, output)
  }

  /// Call SMC with input parameters and return output
  public func callSMC(input: SMCParamStruct) throws -> SMCParamStruct {
    var inp = SMCParamStruct()
    _ = withUnsafeMutableBytes(of: &inp) { memset($0.baseAddress!, 0, $0.count) }
    inp.key = input.key
    inp.data8 = input.data8
    inp.keyInfo.dataSize = input.keyInfo.dataSize
    inp.bytes = input.bytes
    var out = SMCParamStruct()
    _ = withUnsafeMutableBytes(of: &out) { memset($0.baseAddress!, 0, $0.count) }
    var outSize = MemoryLayout<SMCParamStruct>.stride

    let result = IOConnectCallStructMethod(
      connection,
      UInt32(SMCCommand.kernelIndex.rawValue),
      &inp,
      MemoryLayout<SMCParamStruct>.stride,
      &out,
      &outSize
    )

    guard result == kIOReturnSuccess else {
      logError("IOKit error=0x\(String(result, radix: 16)) key=0x\(String(inp.key, radix: 16))")
      throw SMCError.ioKit(result)
    }

    if out.result != SMCResultCode.success.rawValue {
      let resultDesc = SMCResultCode(rawValue: out.result).map { "\($0)" } ?? "0x\(String(out.result, radix: 16))"
      logDebug("SMC result=\(resultDesc) for key=0x\(String(inp.key, radix: 16))")
    }

    return out
  }

  /// Convert a 4-character string to UInt32
  public func fourCharCode(from string: String) -> UInt32 {
    precondition(string.count == 4, "SMC keys must be exactly 4 characters")
    return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  /// Convert a byte array to a 32-byte tuple
  public func bytesToTuple(_ array: [UInt8]) -> SMCParamStruct.Bytes32 {
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
