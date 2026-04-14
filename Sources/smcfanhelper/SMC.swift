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

#if !DIRECT_BUILD
  import SMCCommon
#endif

// MARK: - SMC Types

/// SMC command selectors for IOConnectCallStructMethod
private enum SMCCommand: UInt8 {
  case kernelIndex = 2
  case readBytes = 5
  case writeBytes = 6
  case readIndex = 8
  case readKeyInfo = 9
}

/// Swift-native error type for SMC operations
enum SMCError: LocalizedError, Sendable {
  case notOpen
  case connectionFailed
  case timeout
  case ioKit(kern_return_t)
  case firmware(SMCResultCode)

  var errorDescription: String? {
    switch self {
    case .notOpen:
      return "SMC connection not open"
    case .connectionFailed:
      return "Failed to open AppleSMC"
    case .timeout:
      return "Operation timed out"
    case .ioKit(let code):
      return "IOKit error: 0x\(String(code, radix: 16))"
    case .firmware(let code):
      return "SMC firmware error: \(code)"
    }
  }
}

/// SMC firmware result codes (from VirtualSMC SDK - AppleSmc.h)
/// These are returned in output.result field, distinct from IOKit return values.
enum SMCResultCode: UInt8, CustomStringConvertible, Sendable {
  case success = 0x00
  case error = 0x01
  case commCollision = 0x80  // Communication collision
  case spuriousData = 0x81  // Unexpected data
  case badCommand = 0x82  // Firmware rejected (e.g., write to F%dMd in Mode 3)
  case badParameter = 0x83  // Invalid parameter value
  case notFound = 0x84  // Key does not exist
  case notReadable = 0x85  // Key is write-only
  case notWritable = 0x86  // Key is read-only
  case keySizeMismatch = 0x87  // Data size mismatch
  case framingError = 0x88  // Protocol framing error
  case badArgumentError = 0x89  // Bad argument to SMC function

  var description: String {
    let name =
      switch self {
      case .success: "success"
      case .error: "error"
      case .commCollision: "commCollision"
      case .spuriousData: "spuriousData"
      case .badCommand: "badCommand"
      case .badParameter: "badParameter"
      case .notFound: "notFound"
      case .notReadable: "notReadable"
      case .notWritable: "notWritable"
      case .keySizeMismatch: "keySizeMismatch"
      case .framingError: "framingError"
      case .badArgumentError: "badArgumentError"
      }
    return "\(name) (0x\(String(rawValue, radix: 16)))"
  }
}

/// Well-known SMC keys for fan control
enum SMCFanKey {
  static let count = "FNum"
  static let actual = "F%dAc"
  static let target = "F%dTg"
  static let minimum = "F%dMn"
  static let maximum = "F%dMx"
  static let forceTest = "Ftst"

  // Mode key casing varies across hardware generations.
  // Probed at runtime; see SMCHardwareConfig.
  static let modeLower = "F%dmd"
  static let modeUpper = "F%dMd"

  static func key(_ template: String, fan: Int) -> String {
    String(format: template, fan)
  }
}

/// Hardware-specific SMC key configuration, detected at runtime.
struct SMCHardwareConfig {
  let modeKeyFormat: String
  let ftstAvailable: Bool
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
final class SMCConnection: @unchecked Sendable {

  private let connection: io_connect_t
  private(set) var hwConfig: SMCHardwareConfig

  // MARK: Initialization

  init() throws {
    Log.debug("BEGIN opening AppleSMC IOService")
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
      Log.debug("IOServiceGetMatchingServices failed")
      throw SMCError.connectionFailed
    }

    let service = IOIteratorNext(iterator)
    guard service != 0 else {
      Log.debug("no AppleSMC service found")
      throw SMCError.connectionFailed
    }
    defer { IOObjectRelease(service) }

    var conn: io_connect_t = 0
    let openResult = IOServiceOpen(service, mach_task_self_, 0, &conn)
    guard openResult == kIOReturnSuccess else {
      Log.info("IOServiceOpen failed 0x\(String(openResult, radix: 16))")
      throw SMCError.connectionFailed
    }

    Log.debug("IOServiceOpen succeeded conn=\(conn)")
    self.connection = conn
    self.hwConfig = SMCHardwareConfig(modeKeyFormat: SMCFanKey.modeLower, ftstAvailable: false)
    self.hwConfig = detectHardwareKeys()

    let pv = ProcessInfo.processInfo
    Log.info(
      "\(pv.operatingSystemVersionString) model=\(Self.hardwareModel()) pid=\(getpid()) euid=\(geteuid())"
    )
    Log.info("modeKey=\(hwConfig.modeKeyFormat) ftstAvailable=\(hwConfig.ftstAvailable)")
  }

  private func detectHardwareKeys() -> SMCHardwareConfig {
    Log.debug("BEGIN probing mode key casing and Ftst")
    // Probe mode key casing
    var modeKey = SMCFanKey.modeLower
    for candidate in [SMCFanKey.modeLower, SMCFanKey.modeUpper] {
      let testKey = SMCFanKey.key(candidate, fan: 0)
      Log.debug("probing candidate \(testKey)")
      if let (bytes, size) = try? readKey(testKey), size > 0 {
        modeKey = candidate
        Log.info("mode key is \(testKey)")
        Log.debug("mode key \(testKey) size=\(size) bytes=\(bytes)")
        break
      } else {
        Log.debug("candidate \(testKey) not found or empty")
      }
    }

    // Probe Ftst availability
    var ftst = false
    if let (ftstBytes, size) = try? readKey(SMCFanKey.forceTest), size > 0 {
      ftst = true
      Log.info("Ftst available")
      Log.debug("Ftst size=\(size) bytes=\(ftstBytes)")
    } else {
      Log.info("Ftst not available, direct mode writes expected")
    }

    Log.debug("END modeKeyFormat=\(modeKey) ftstAvailable=\(ftst)")
    return SMCHardwareConfig(modeKeyFormat: modeKey, ftstAvailable: ftst)
  }

  private static func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
  }

  deinit {
    Log.debug("closing conn=\(connection)")
    IOServiceClose(connection)
  }

  // MARK: Public Interface

  /// Read raw bytes from an SMC key
  func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
    Log.debug("BEGIN key=\(key)")
    let (param, output) = try fetchKeyInfo(key)

    let dataSize = output.keyInfo.dataSize
    var readParam = param
    readParam.keyInfo.dataSize = dataSize
    readParam.data8 = SMCCommand.readBytes.rawValue

    let readOutput = try callSMC(input: readParam)

    let bytes = withUnsafeBytes(of: readOutput.bytes) {
      Array($0.prefix(Int(dataSize)))
    }
    Log.debug("OK key=\(key) size=\(dataSize) bytes=\(bytes)")
    return (bytes, dataSize)
  }

  /// Write raw bytes to an SMC key
  func writeKey(_ key: String, bytes: [UInt8]) throws {
    Log.debug("BEGIN key=\(key) bytes=\(bytes)")
    let (param, output) = try fetchKeyInfo(key)

    var writeParam = param
    writeParam.data8 = SMCCommand.writeBytes.rawValue
    writeParam.keyInfo.dataSize = output.keyInfo.dataSize
    writeParam.bytes = bytesToTuple(bytes)

    let writeOutput = try callSMC(input: writeParam)

    if writeOutput.result != SMCResultCode.success.rawValue {
      Log.debug("FAILED key=\(key) smc_result=0x\(String(writeOutput.result, radix: 16))")
      guard let resultCode = SMCResultCode(rawValue: writeOutput.result) else {
        throw SMCError.firmware(.error)
      }
      throw SMCError.firmware(resultCode)
    } else {
      Log.debug("OK key=\(key)")
    }
  }

  /// Enumerate all SMC keys by reading the #KEY count and iterating with readIndex.
  func enumerateKeys() -> [String] {
    Log.debug("BEGIN")
    guard let (countBytes, countSize) = try? readKey("#KEY"), countSize >= 4 else {
      Log.warning("failed to read #KEY count")
      return []
    }
    let totalKeys = countBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
    Log.info("#KEY reports \(totalKeys) keys")

    var keys: [String] = []
    for i in 0..<totalKeys {
      var inp = SMCParamStruct()
      inp.data8 = SMCCommand.readIndex.rawValue
      inp.data32 = UInt32(i)
      guard let out = try? callSMC(input: inp) else {
        Log.debug("readIndex(\(i)) failed")
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
    Log.debug("END found \(keys.count) keys")
    return keys
  }

  // MARK: Private Helpers

  private func fetchKeyInfo(
    _ key: String
  ) throws -> (param: SMCParamStruct, output: SMCParamStruct) {
    Log.debug("BEGIN key=\(key)")
    var param = SMCParamStruct()
    param.key = fourCharCode(from: key)
    param.data8 = SMCCommand.readKeyInfo.rawValue
    let output = try callSMC(input: param)
    if output.result != 0 {
      Log.debug(
        "FAILED key=\(key) result=0x\(String(output.result, radix: 16)) dataSize=\(output.keyInfo.dataSize) dataType=0x\(String(output.keyInfo.dataType, radix: 16))"
      )
    } else {
      Log.debug(
        "OK key=\(key) dataSize=\(output.keyInfo.dataSize) dataType=0x\(String(output.keyInfo.dataType, radix: 16)) attrs=0x\(String(output.keyInfo.dataAttributes, radix: 16))"
      )
    }
    return (param, output)
  }

  private func callSMC(input: SMCParamStruct) throws -> SMCParamStruct {
    var inp = SMCParamStruct()
    _ = withUnsafeMutableBytes(of: &inp) { memset($0.baseAddress!, 0, $0.count) }
    inp.key = input.key
    inp.data8 = input.data8
    inp.keyInfo.dataSize = input.keyInfo.dataSize
    inp.bytes = input.bytes
    var out = SMCParamStruct()
    _ = withUnsafeMutableBytes(of: &out) { memset($0.baseAddress!, 0, $0.count) }
    var outSize = MemoryLayout<SMCParamStruct>.stride

    let inpRaw = withUnsafeBytes(of: inp) { Array($0) }
    let keyBytes = [inpRaw[0], inpRaw[1], inpRaw[2], inpRaw[3]]
    let keyStr = String(keyBytes.reversed().map { Character(UnicodeScalar($0)) })
    Log.debug("\(keyStr) cmd=\(inp.data8) input[0..48]=\(Array(inpRaw[0..<48]))")

    let result = IOConnectCallStructMethod(
      connection,
      UInt32(SMCCommand.kernelIndex.rawValue),
      &inp,
      MemoryLayout<SMCParamStruct>.stride,
      &out,
      &outSize
    )

    let outRaw = withUnsafeBytes(of: out) { Array($0) }
    Log.debug(
      "\(keyStr) cmd=\(inp.data8) iokit=0x\(String(result, radix: 16)) output[0..48]=\(Array(outRaw[0..<48]))"
    )

    guard result == kIOReturnSuccess else {
      Log.debug("\(keyStr) cmd=\(inp.data8) IOKit FAILURE 0x\(String(result, radix: 16))")
      throw SMCError.ioKit(result)
    }
    return out
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
