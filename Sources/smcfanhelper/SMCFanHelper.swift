import Foundation
import IOKit
#if !DIRECT_BUILD
import SMCCommon
import libsmc
#endif

/// XPC service that handles privileged SMC operations
class SMCFanHelper: NSObject, NSXPCListenerDelegate, SMCFanHelperProtocol {
    private let listener: NSXPCListener
    private var smcConnection: io_connect_t = 0
    
    override init() {
        let config = SMCFanConfiguration.default
        self.listener = NSXPCListener(machServiceName: config.helperBundleID)
        super.init()
        self.listener.delegate = self
    }
    
    func start() {
        listener.resume()
        NSLog("SMCFanHelper: Service started")
        RunLoop.current.run()
    }
    
    // MARK: - NSXPCListenerDelegate
    
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: NSObjectProtocol.self)
        
        newConnection.invalidationHandler = {
            NSLog("SMCFanHelper: Connection invalidated")
        }
        
        newConnection.interruptionHandler = {
            NSLog("SMCFanHelper: Connection interrupted")
        }
        
        newConnection.resume()
        return true
    }
    
    // MARK: - Connection Management
    
    private func ensureSMCConnection() throws {
        if smcConnection != 0 {
            let (result, _, _) = smcRead(smcConnection, key: SMC_KEY_FNUM)
            if result == kIOReturnSuccess {
                return
            }
            
            NSLog("SMCFanHelper: Connection stale (0x%x), reopening", result)
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
        
        let (conn, result) = smcOpenConnection()
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
    
    // MARK: - SMCFanHelperProtocol
    
    func smcOpen(reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureSMCConnection()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }
    
    func smcClose(reply: @escaping (Bool, String?) -> Void) {
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
        reply(true, nil)
    }
    
    func smcReadKey(_ key: String, reply: @escaping (Bool, Float, String?) -> Void) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, 0, error.localizedDescription)
            return
        }
        
        let (result, value, size) = smcRead(smcConnection, key: key)
        
        if result == kIOReturnSuccess {
            reply(true, bytesToFloat(value, size: size), nil)
        } else {
            reply(false, 0, "Failed to read key \(key): 0x\(String(result, radix: 16))")
        }
    }
    
    func smcWriteKey(_ key: String, value: Float, reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        
        let (readResult, _, size) = smcRead(smcConnection, key: key)
        guard readResult == kIOReturnSuccess else {
            reply(false, "Failed to read key info: 0x\(String(readResult, radix: 16))")
            return
        }
        
        let writeVal = floatToBytes(value, size: size)
        let writeResult = smcWrite(smcConnection, key: key, value: writeVal, size: size)
        
        if writeResult == kIOReturnSuccess {
            reply(true, nil)
        } else {
            reply(false, "Failed to write key: 0x\(String(writeResult, radix: 16))")
        }
    }
    
    func smcGetFanCount(reply: @escaping (Bool, UInt, String?) -> Void) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, 0, error.localizedDescription)
            return
        }
        
        let (result, value, _) = smcRead(smcConnection, key: SMC_KEY_FNUM)
        
        if result == kIOReturnSuccess {
            reply(true, UInt(value[0]), nil)
        } else {
            reply(false, 0, "Failed to read fan count: 0x\(String(result, radix: 16))")
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
        
        let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_ACTUAL) ?? 0
        let targetRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_TARGET) ?? 0
        let minRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_MIN) ?? 0
        let maxRPM = readFloat(fanIndex: fanIndex, keyFormat: SMC_KEY_FAN_MAX) ?? 0
        
        let modeKey = String(format: SMC_KEY_FAN_MODE, Int(fanIndex))
        let (modeResult, modeValue, _) = smcRead(smcConnection, key: modeKey)
        let manualMode = (modeResult == kIOReturnSuccess && modeValue[0] == 1)
        
        reply(true, actualRPM, targetRPM, minRPM, maxRPM, manualMode, nil)
    }
    
    private func readFloat(fanIndex: UInt, keyFormat: String) -> Float? {
        let key = String(format: keyFormat, Int(fanIndex))
        let (result, value, size) = smcRead(smcConnection, key: key)
        guard result == kIOReturnSuccess else { return nil }
        return bytesToFloat(value, size: size)
    }
    
    func smcSetFanRPM(_ fanIndex: UInt, rpm: Float, reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        
        let unlockResult = smcUnlockFanControl(smcConnection)
        guard unlockResult == kIOReturnSuccess else {
            reply(false, "Failed to unlock: 0x\(String(unlockResult, radix: 16))")
            return
        }
        
        let key = String(format: SMC_KEY_FAN_TARGET, Int(fanIndex))
        let value = floatToBytes(rpm, size: 4)
        let writeResult = smcWrite(smcConnection, key: key, value: value, size: 4)
        
        guard writeResult == kIOReturnSuccess else {
            reply(false, "Failed to set RPM: 0x\(String(writeResult, radix: 16))")
            return
        }
        
        NSLog("SMCFanHelper: Set fan %lu to %.0f RPM", fanIndex, rpm)
        reply(true, nil)
    }
    
    func smcSetFanAuto(_ fanIndex: UInt, reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureSMCConnection()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        
        let unlockResult = smcUnlockFanControl(smcConnection)
        guard unlockResult == kIOReturnSuccess else {
            reply(false, "Failed to unlock: 0x\(String(unlockResult, radix: 16))")
            return
        }
        
        let minKey = String(format: SMC_KEY_FAN_MIN, Int(fanIndex))
        let (readResult, value, size) = smcRead(smcConnection, key: minKey)
        
        var minRPM: Float = 2317.0
        if readResult == kIOReturnSuccess && size == 4 {
            minRPM = bytesToFloat(value, size: size)
        }
        
        let targetKey = String(format: SMC_KEY_FAN_TARGET, Int(fanIndex))
        let writeVal = floatToBytes(minRPM, size: 4)
        let writeResult = smcWrite(smcConnection, key: targetKey, value: writeVal, size: 4)
        
        guard writeResult == kIOReturnSuccess else {
            reply(false, "Failed to set min RPM: 0x\(String(writeResult, radix: 16))")
            return
        }
        
        NSLog("SMCFanHelper: Set fan %lu to minimum (%.0f RPM)", fanIndex, minRPM)
        reply(true, nil)
    }
}
