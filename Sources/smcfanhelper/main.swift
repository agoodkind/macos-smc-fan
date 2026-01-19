import Foundation

class SMCFanHelper: NSObject, NSXPCListenerDelegate, SMCFanHelperProtocol {
    let listener: NSXPCListener
    var smcConnection: io_connect_t = 0
    
    override init() {
        let helperID = String(utf8String: HELPER_ID) ?? ""
        self.listener = NSXPCListener(machServiceName: helperID)
        super.init()
        self.listener.delegate = self
    }
    
    func start() {
        listener.resume()
        NSLog("SMCFanHelper: Service started")
        RunLoop.current.run()
    }
    
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: SMCFanHelperProtocol.self
        )
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: NSObjectProtocol.self
        )
        
        newConnection.invalidationHandler = {
            NSLog("SMCFanHelper: Connection invalidated")
        }
        
        newConnection.interruptionHandler = {
            NSLog("SMCFanHelper: Connection interrupted")
        }
        
        newConnection.resume()
        return true
    }
    
    // MARK: - SMC Operations
    
    private func ensureSMCConnection() throws {
        if smcConnection != 0 {
            var input = SMCKeyData_t()
            var output = SMCKeyData_t()
            input.key = 0x464e756d  // FNum
            input.data8 = UInt8(SMC_CMD_READ_KEYINFO)
            
            var outputSize = MemoryLayout<SMCKeyData_t>.size
            let result = IOConnectCallStructMethod(
                smcConnection,
                UInt32(KERNEL_INDEX_SMC),
                &input,
                MemoryLayout<SMCKeyData_t>.size,
                &output,
                &outputSize
            )
            
            if result == kIOReturnSuccess {
                return  // Connection is good
            }
            
            NSLog(
                "SMCFanHelper: Connection stale (0x%x), reopening",
                result
            )
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
        
        var conn: io_connect_t = 0
        let result = smc_open(&conn)
        
        guard result == kIOReturnSuccess else {
            throw NSError(
                domain: "SMCError",
                code: Int(result),
                userInfo: [
                    NSLocalizedDescriptionKey: 
                        "Failed to open SMC: 0x\(String(result, radix: 16))"
                ]
            )
        }
        
        smcConnection = conn
    }
    
    func smcOpen(reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureSMCConnection()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }
    
    func smcClose(reply: @escaping (Bool, String?) -> Void) {
        if smcConnection == 0 {
            reply(true, nil)
            return
        }
        
        IOServiceClose(smcConnection)
        smcConnection = 0
        reply(true, nil)
    }
    
    func smcReadKey(
        _ key: String,
        reply: @escaping (Bool, Float, String?) -> Void
    ) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, 0, error.localizedDescription)
            return
        }
        
        var value: [UInt8] = Array(repeating: 0, count: 32)
        var size: UInt32 = 0
        
        let result = key.withCString { keyPtr in
            value.withUnsafeMutableBufferPointer { bufferPtr in
                smc_read_key(smcConnection, keyPtr, bufferPtr.baseAddress!, &size)
            }
        }
        
        if result == kIOReturnSuccess {
            let floatValue = value.withUnsafeBytes { bytes in
                bytes_to_float(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), size)
            }
            reply(true, floatValue, nil)
        } else {
            reply(
                false, 
                0,
                "Failed to read key \(key): 0x\(String(result, radix: 16))"
            )
        }
    }
    
    func smcWriteKey(
        _ key: String,
        value: Float,
        reply: @escaping (Bool, String?) -> Void
    ) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        
        var tempVal: [UInt8] = Array(repeating: 0, count: 32)
        var size: UInt32 = 0
        
        let readResult = key.withCString { keyPtr in
            tempVal.withUnsafeMutableBufferPointer { bufferPtr in
                smc_read_key(smcConnection, keyPtr, bufferPtr.baseAddress!, &size)
            }
        }
        
        guard readResult == kIOReturnSuccess else {
            reply(
                false,
                "Failed to read key info for \(key): " +
                "0x\(String(readResult, radix: 16))"
            )
            return
        }
        
        var writeVal: [UInt8] = Array(repeating: 0, count: 32)
        writeVal.withUnsafeMutableBufferPointer { bufferPtr in
            float_to_bytes(value, bufferPtr.baseAddress!, size)
        }
        
        let writeResult = key.withCString { keyPtr in
            writeVal.withUnsafeBytes { bytes in
                smc_write_key(smcConnection, keyPtr, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), size)
            }
        }
        
        if writeResult == kIOReturnSuccess {
            reply(true, nil)
        } else {
            reply(
                false,
                "Failed to write key \(key): " +
                "0x\(String(writeResult, radix: 16))"
            )
        }
    }
    
    func smcGetFanCount(
        reply: @escaping (Bool, UInt, String?) -> Void
    ) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, 0, error.localizedDescription)
            return
        }
        
        var value: [UInt8] = Array(repeating: 0, count: 32)
        var size: UInt32 = 0
        
        let result = SMC_KEY_FNUM.withCString { keyPtr in
            value.withUnsafeMutableBufferPointer { bufferPtr in
                smc_read_key(smcConnection, keyPtr, bufferPtr.baseAddress!, &size)
            }
        }
        
        if result == kIOReturnSuccess {
            reply(true, UInt(value[0]), nil)
        } else {
            NSLog("smcGetFanCount failed: 0x%x", result)
            reply(
                false,
                0,
                "Failed to read fan count: 0x\(String(result, radix: 16))"
            )
        }
    }
    
    func smcGetFanInfo(
        _ fanIndex: UInt,
        reply: @escaping (Bool, Float, Float, Float, Float, Bool, String?) -> Void
    ) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, 0, 0, 0, 0, false, error.localizedDescription)
            return
        }
        
        var value: [UInt8] = Array(repeating: 0, count: 32)
        var size: UInt32 = 0
        
        // Read RPM values
        let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_ACTUAL, value: &value, size: &size) ?? 0
        let targetRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_TARGET, value: &value, size: &size) ?? 0
        let minRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_MIN, value: &value, size: &size) ?? 0
        let maxRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_MAX, value: &value, size: &size) ?? 0
        
        // Read mode
        let modeKey = String(format: SMC_KEY_FAN_MODE, Int(fanIndex))
        let modeResult = modeKey.withCString { keyPtr in
            value.withUnsafeMutableBufferPointer { bufferPtr in
                smc_read_key(smcConnection, keyPtr, bufferPtr.baseAddress!, &size)
            }
        }
        
        let manualMode = (modeResult == kIOReturnSuccess && value[0] == 1)
        
        reply(true, actualRPM, targetRPM, minRPM, maxRPM, manualMode, nil)
    }
    
    private func readFloat(
        fanIndex: UInt,
        keyFormat: String,
        value: inout [UInt8],
        size: inout UInt32
    ) -> Float? {
        let key = String(format: keyFormat, Int(fanIndex))
        let result = key.withCString { keyPtr in
            value.withUnsafeMutableBufferPointer { bufferPtr in
                smc_read_key(smcConnection, keyPtr, bufferPtr.baseAddress!, &size)
            }
        }
        
        guard result == kIOReturnSuccess else { return nil }
        
        return value.withUnsafeBytes { bytes in
            bytes_to_float(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), size)
        }
    }
    
    func smcSetFanRPM(
        _ fanIndex: UInt,
        rpm: Float,
        reply: @escaping (Bool, String?) -> Void
    ) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        
        let unlockResult = smc_unlock_fan_control(
            smcConnection,
            100,
            10.0
        )
        
        guard unlockResult == kIOReturnSuccess else {
            reply(
                false,
                "Failed to unlock fan control: " +
                "0x\(String(unlockResult, radix: 16))"
            )
            return
        }
        
        let key = String(format: SMC_KEY_FAN_TARGET, Int(fanIndex))
        var value: [UInt8] = Array(repeating: 0, count: 32)
        
        withUnsafeBytes(of: rpm) { bytes in
            for (i, byte) in bytes.enumerated() where i < 4 {
                value[i] = byte
            }
        }
        
        let writeResult = key.withCString { keyPtr in
            value.withUnsafeBytes { bytes in
                smc_write_key(smcConnection, keyPtr, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 4)
            }
        }
        
        guard writeResult == kIOReturnSuccess else {
            reply(
                false,
                "Failed to set target RPM: " +
                "0x\(String(writeResult, radix: 16))"
            )
            return
        }
        
        NSLog("SMCFanHelper: Set fan %lu to %.0f RPM", fanIndex, rpm)
        reply(true, nil)
    }
    
    func smcSetFanAuto(
        _ fanIndex: UInt,
        reply: @escaping (Bool, String?) -> Void
    ) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        
        let unlockResult = smc_unlock_fan_control(
            smcConnection,
            100,
            10.0
        )
        
        guard unlockResult == kIOReturnSuccess else {
            reply(
                false,
                "Failed to unlock fan control: " +
                "0x\(String(unlockResult, radix: 16))"
            )
            return
        }
        
        let minKey = String(format: SMC_KEY_FAN_MIN, Int(fanIndex))
        var value: [UInt8] = Array(repeating: 0, count: 32)
        var size: UInt32 = 0
        
        let readResult = minKey.withCString { keyPtr in
            value.withUnsafeMutableBufferPointer { bufferPtr in
                smc_read_key(smcConnection, keyPtr, bufferPtr.baseAddress!, &size)
            }
        }
        
        var minRPM: Float = 2317.0
        if readResult == kIOReturnSuccess && size == 4 {
            value.withUnsafeBytes { bytes in
                minRPM = bytes.load(as: Float.self)
            }
        }
        
        let targetKey = String(format: SMC_KEY_FAN_TARGET, Int(fanIndex))
        var writeVal: [UInt8] = Array(repeating: 0, count: 32)
        
        withUnsafeBytes(of: minRPM) { bytes in
            for (i, byte) in bytes.enumerated() where i < 4 {
                writeVal[i] = byte
            }
        }
        
        let writeResult = targetKey.withCString { keyPtr in
            writeVal.withUnsafeBytes { bytes in
                smc_write_key(smcConnection, keyPtr, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 4)
            }
        }
        
        guard writeResult == kIOReturnSuccess else {
            reply(
                false,
                "Failed to set min RPM: " +
                "0x\(String(writeResult, radix: 16))"
            )
            return
        }
        
        NSLog(
            "SMCFanHelper: Set fan %lu to minimum (%.0f RPM)",
            fanIndex,
            minRPM
        )
        reply(true, nil)
    }
}

@main
struct SMCFanHelperMain {
    static func main() {
        autoreleasepool {
            let helper = SMCFanHelper()
            helper.start()
        }
    }
}
