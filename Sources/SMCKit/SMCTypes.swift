//
//  SMCTypes.swift
//  SMCKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-24.
//  Copyright © 2026
//

import Foundation

// MARK: - SMC Command

/// SMC command selectors for IOConnectCallStructMethod
public enum SMCCommand: UInt8 {
  case kernelIndex = 2
  case readBytes = 5
  case writeBytes = 6
  case readIndex = 8
  case readKeyInfo = 9
}

// MARK: - SMC Error

/// Swift-native error type for SMC operations
public enum SMCError: LocalizedError, Sendable {
  case notOpen
  case connectionFailed
  case timeout
  case ioKit(kern_return_t)
  case firmware(SMCResultCode)

  public var errorDescription: String? {
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

// MARK: - SMC Result Code

/// SMC firmware result codes (from VirtualSMC SDK - AppleSmc.h)
/// These are returned in output.result field, distinct from IOKit return values.
public enum SMCResultCode: UInt8, CustomStringConvertible, Sendable {
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

  public var description: String {
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

// MARK: - SMC Data Structures

/// 80-byte structure matching AppleSMC kernel interface
public struct SMCParamStruct {
  public typealias Bytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  )

  public struct Version {
    public var major: UInt8 = 0
    public var minor: UInt8 = 0
    public var build: UInt8 = 0
    public var reserved: UInt8 = 0
    public var release: UInt16 = 0

    public init() {}
  }

  public struct PLimitData {
    public var version: UInt16 = 0
    public var length: UInt16 = 0
    public var cpuPLimit: UInt32 = 0
    public var gpuPLimit: UInt32 = 0
    public var memPLimit: UInt32 = 0

    public init() {}
  }

  public struct KeyInfo {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0

    public init() {}
  }

  public var key: UInt32 = 0
  public var vers = Version()
  public var pLimitData = PLimitData()
  public var keyInfo = KeyInfo()
  public var padding: UInt16 = 0
  public var result: UInt8 = 0
  public var status: UInt8 = 0
  public var data8: UInt8 = 0
  public var data32: UInt32 = 0
  public var bytes: Bytes32 = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  )

  public init() {}
}
