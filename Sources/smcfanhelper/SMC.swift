//
//  SMC.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-24.
//  Copyright © 2026
//

import Foundation
import IOKit

// MARK: - SMC Constants

enum SMCSelector: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readKeyInfo = 9
}

// MARK: - SMC Key Constants

enum SMCKey {
    static let fanCount = "FNum"
    static let fanActual = "F%dAc"
    static let fanTarget = "F%dTg"
    static let fanMin = "F%dMn"
    static let fanMax = "F%dMx"
    static let fanMode = "F%dMd"
    static let fanTest = "Ftst"
}

// MARK: - SMC Data Structures

struct SMCKeyData {
    typealias BytesTuple = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
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
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: BytesTuple = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCValue {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)

    init(_ key: String) {
        self.key = key
    }
}

// MARK: - FourCharCode Extension

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { sum, character in
            sum << 8 | UInt32(character)
        }
    }

    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xFF)!) +
            String(describing: UnicodeScalar(self >> 16 & 0xFF)!) +
            String(describing: UnicodeScalar(self >> 8 & 0xFF)!) +
            String(describing: UnicodeScalar(self & 0xFF)!)
    }
}

// MARK: - SMC Class

public class SMC {
    private var conn: io_connect_t = 0

    public init?() {
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching("AppleSMC")

        let matchResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matchingDict,
            &iterator
        )
        guard matchResult == kIOReturnSuccess else {
            return nil
        }

        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)

        guard device != 0 else {
            return nil
        }

        let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)

        guard openResult == kIOReturnSuccess else {
            return nil
        }
    }

    deinit {
        if conn != 0 {
            IOServiceClose(conn)
        }
    }

    // MARK: - Public API

    public func read(key: String) -> (kern_return_t, [UInt8], UInt32) {
        var val = SMCValue(key)
        let result = readKey(&val)
        return (result, val.bytes, val.dataSize)
    }

    public func write(key: String, value: [UInt8], size: UInt32) -> kern_return_t {
        var val = SMCValue(key)
        val.dataSize = size
        val.bytes = value + Array(repeating: 0, count: 32 - value.count)
        return writeKey(val)
    }

    // MARK: - Internal SMC Operations

    private func readKey(_ value: inout SMCValue) -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = FourCharCode(fromString: value.key)
        input.data8 = SMCSelector.readKeyInfo.rawValue

        var result = call(input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        value.dataSize = output.keyInfo.dataSize
        value.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCSelector.readBytes.rawValue

        result = call(input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        withUnsafeBytes(of: &output.bytes) { srcBuffer in
            for i in 0..<Int(value.dataSize) {
                value.bytes[i] = srcBuffer[i]
            }
        }
        return kIOReturnSuccess
    }

    private func writeKey(_ value: SMCValue) -> kern_return_t {
        var input = SMCKeyData()
        var output = SMCKeyData()

        // First read to get keyInfo
        input.key = FourCharCode(fromString: value.key)
        input.data8 = SMCSelector.readKeyInfo.rawValue

        var result = call(input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        // Now write
        input.data8 = SMCSelector.writeBytes.rawValue
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.bytes = (value.bytes[0], value.bytes[1], value.bytes[2], value.bytes[3],
                       value.bytes[4], value.bytes[5], value.bytes[6], value.bytes[7],
                       value.bytes[8], value.bytes[9], value.bytes[10], value.bytes[11],
                       value.bytes[12], value.bytes[13], value.bytes[14], value.bytes[15],
                       value.bytes[16], value.bytes[17], value.bytes[18], value.bytes[19],
                       value.bytes[20], value.bytes[21], value.bytes[22], value.bytes[23],
                       value.bytes[24], value.bytes[25], value.bytes[26], value.bytes[27],
                       value.bytes[28], value.bytes[29], value.bytes[30], value.bytes[31])

        result = call(input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        return output.result == 0 ? kIOReturnSuccess : kIOReturnError
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        return IOConnectCallStructMethod(
            conn,
            UInt32(SMCSelector.kernelIndex.rawValue),
            &input,
            inputSize,
            &output,
            &outputSize
        )
    }
}
