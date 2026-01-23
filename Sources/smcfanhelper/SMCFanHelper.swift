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
        
        // Unlock fan control for this specific fan (required for Apple Silicon)
        // This also sets the fan to manual mode
        let unlockResult = smcUnlockFanControl(smcConnection, fanIndex: Int(fanIndex))
        guard unlockResult == kIOReturnSuccess else {
            reply(false, "Failed to unlock: 0x\(String(unlockResult, radix: 16))")
            return
        }
        
        // Set target RPM
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
        
        // Check how many fans are currently in manual mode (mode == 1)
        let (numResult, numBytes, _) = smcRead(smcConnection, key: SMC_KEY_FNUM)
        guard numResult == kIOReturnSuccess && !numBytes.isEmpty else {
            reply(false, "Failed to read fan count")
            return
        }
        
        let fanCount = Int(numBytes[0])
        var manualFanCount = 0
        
        for i in 0..<fanCount {
            let checkKey = String(format: SMC_KEY_FAN_MODE, i)
            let (_, checkBytes, _) = smcRead(smcConnection, key: checkKey)
            if !checkBytes.isEmpty && checkBytes[0] == 1 {
                manualFanCount += 1
            }
        }
        
        // If this is the last manual fan, reset Ftst first to return control to thermalmonitord
        // This will cause mode to transition from 1 -> 0 -> 3 (system mode)
        if manualFanCount <= 1 {
            let resetResult = smcWrite(smcConnection, key: SMC_KEY_FAN_TEST, value: [0], size: 1)
            if resetResult != kIOReturnSuccess {
                NSLog("SMCFanHelper: Warning - failed to reset Ftst: 0x%x", resetResult)
            }
            NSLog("SMCFanHelper: Reset Ftst, returning control to thermalmonitord")
        } else {
            // Other fans are still manual, just set this fan's mode to 0 (auto)
            let modeKey = String(format: SMC_KEY_FAN_MODE, Int(fanIndex))
            let modeResult = smcWrite(smcConnection, key: modeKey, value: [0], size: 1)
            if modeResult != kIOReturnSuccess {
                NSLog("SMCFanHelper: Warning - failed to set auto mode: 0x%x", modeResult)
            }
            
            // Reset target to 0 to let system decide
            let targetKey = String(format: SMC_KEY_FAN_TARGET, Int(fanIndex))
            let writeVal = floatToBytes(0, size: 4)
            let _ = smcWrite(smcConnection, key: targetKey, value: writeVal, size: 4)
        }
        
        NSLog("SMCFanHelper: Set fan %lu to automatic", fanIndex)
        reply(true, nil)
    }
}
