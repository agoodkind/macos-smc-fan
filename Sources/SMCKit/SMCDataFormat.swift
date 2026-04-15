//
//  SMCDataFormat.swift
//  SMCKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation

// MARK: - SMC Data Format Conversions

/// SMC data format conversion utilities.
///
/// Integer types (ui8, ui16, ui32) and fixed-point types (fpe2, sp78, etc.)
/// are big-endian on both Intel and Apple Silicon. This is the SMC protocol
/// convention, confirmed by the Linux kernel applesmc driver (be32_to_cpu),
/// the Asahi Linux macsmc driver (be32_to_cpu for #KEY), and the VirtualSMC
/// SDK (OSSwapHostToBigInt for all integer/fixed-point encode/decode).
///
/// Float type (flt) is native-endian (little-endian on both Intel and ARM).
/// On Intel, fan RPMs use fpe2 (2 bytes, big-endian). On Apple Silicon,
/// fan RPMs use flt (4 bytes, native-endian IEEE 754). The size parameter
/// distinguishes the two: size=4 is flt, size=2 is fpe2.
public enum SMCDataFormat: Sendable {

  // MARK: - Float / Fixed-Point

  public static func float(from bytes: [UInt8], size: UInt32) -> Float {
    if size == 4, bytes.count >= 4 {
      return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    } else if bytes.count >= 2 {
      let raw = uint16(from: bytes)
      return Float(raw) / 4.0
    } else {
      return 0
    }
  }

  public static func bytes(from value: Float, size: UInt32) -> [UInt8] {
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

  // MARK: - Unsigned Integers (big-endian, SMC protocol convention)

  public static func uint8(from bytes: [UInt8]) -> UInt8 {
    guard !bytes.isEmpty else { return 0 }
    return bytes[0]
  }

  public static func uint16(from bytes: [UInt8]) -> UInt16 {
    guard bytes.count >= 2 else { return 0 }
    return bytes.withUnsafeBytes {
      UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
    }
  }

  public static func uint32(from bytes: [UInt8]) -> UInt32 {
    guard bytes.count >= 4 else { return 0 }
    return bytes.withUnsafeBytes {
      UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
    }
  }
}
