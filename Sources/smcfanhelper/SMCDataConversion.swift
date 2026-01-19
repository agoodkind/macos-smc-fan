import Foundation

// MARK: - SMC Data Format Conversions
//
// Apple Silicon uses IEEE 754 float (little-endian, 4 bytes)
// Intel uses fpe2 fixed-point (14.2 format, big-endian, 2 bytes)

/// Convert SMC bytes to Float
func bytesToFloat(_ bytes: [UInt8], size: UInt32) -> Float {
    if size == 4 {
        // Apple Silicon: IEEE 754 float (little-endian)
        return bytes.withUnsafeBytes { $0.load(as: Float.self) }
    } else {
        // Intel: fpe2 fixed-point (14.2 format, big-endian)
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Float(raw) / 4.0
    }
}

/// Convert Float to SMC bytes
func floatToBytes(_ value: Float, size: UInt32) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: Int(size))
    if size == 4 {
        // Apple Silicon: IEEE 754 float (little-endian)
        withUnsafeBytes(of: value) { bytes in
            for i in 0..<4 { result[i] = bytes[i] }
        }
    } else {
        // Intel: fpe2 fixed-point (14.2 format, big-endian)
        let raw = UInt16(value * 4.0)
        result[0] = UInt8(raw >> 8)
        result[1] = UInt8(raw & 0xFF)
    }
    return result
}
