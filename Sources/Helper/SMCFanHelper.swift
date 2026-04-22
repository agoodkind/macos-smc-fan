//
//  SMCFanHelper.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import AppLog
import Foundation
import IOKit
import SMCFanKit
import SMCKit

private let log = AppLog.make(category: "Helper")

class SMCFanHelper: NSObject, NSXPCListenerDelegate, SMCFanHelperProtocol, @unchecked Sendable {
    private let listener: NSXPCListener
    private var fanController: FanController?
    private let fanVerifyLock = NSLock()
    private var fanVerifyTasks: [UInt: Task<Void, Never>] = [:]
    private let arbitrator = FanArbitrator()

    /// Resolves the `ObjectIdentifier` of the `NSXPCConnection` that is
    /// handling the current call. Every incoming method on this class is
    /// invoked by NSXPC while `NSXPCConnection.current()` is set to the
    /// caller's connection, so this gives the helper a stable per client
    /// identity for arbitration.
    private var callerID: ObjectIdentifier? {
        guard let conn = NSXPCConnection.current() else { return nil }
        return ObjectIdentifier(conn)
    }

    override init() {
        let config = SMCFanConfiguration.default
        listener = NSXPCListener(machServiceName: config.helperBundleID)
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
        log.notice("helper.started bundleID=\(SMCFanConfiguration.default.helperBundleID, privacy: .public)")
        RunLoop.current.run()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let pid = newConnection.processIdentifier
        let id = ObjectIdentifier(newConnection)
        log.info("xpc.connection.accepted pid=\(pid, privacy: .public) euid=\(newConnection.effectiveUserIdentifier, privacy: .public)")
        newConnection.exportedInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = { [weak self] in
            log.info("xpc.connection.closed pid=\(pid, privacy: .public)")
            self?.arbitrator.cleanupClient(id: id)
        }

        newConnection.interruptionHandler = {
            log.info("xpc.connection.interrupted pid=\(pid, privacy: .public)")
        }

        newConnection.resume()
        return true
    }

    // MARK: - Connection Management

    private func ensureConnected() throws {
        if fanController == nil {
            let conn = try SMCConnection()
            fanController = try FanController(connection: conn)
            log.debug("smc.connection.established")
        }
    }

    // MARK: - SMCFanHelperProtocol

    func smcOpen(reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureConnected()
            reply(true, nil)
        } catch {
            log.error("smc.open.failed error=\(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func smcClose(reply: @escaping (Bool, String?) -> Void) {
        fanController = nil
        log.debug("smc.connection.released")
        reply(true, nil)
    }

    func smcReadKey(_ key: String, reply: @escaping (Bool, Float, String?) -> Void) {
        do {
            try ensureConnected()
            guard let fanController = fanController else {
                reply(false, 0, "Connection not established")
                return
            }
            let (value, size) = try fanController.connection.readKey(key)
            let floatVal = SMCDataFormat.float(from: value, size: size)
            log.debug("smc.key.read key=\(key, privacy: .public) value=\(floatVal, privacy: .public) size=\(size, privacy: .public)")
            reply(true, floatVal, nil)
        } catch {
            log.debug("smc.key.read.failed key=\(key, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reply(false, 0, error.localizedDescription)
        }
    }

    func smcWriteKey(_ key: String, value: Float, reply: @escaping (Bool, String?) -> Void) {
        do {
            try ensureConnected()
            guard let fanController = fanController else {
                reply(false, "Connection not established")
                return
            }
            let (_, size) = try fanController.connection.readKey(key)
            let writeVal = SMCDataFormat.bytes(from: value, size: size)
            try fanController.connection.writeKey(key, bytes: writeVal)
            log.debug("smc.key.write key=\(key, privacy: .public) value=\(value, privacy: .public) size=\(size, privacy: .public)")
            reply(true, nil)
        } catch {
            log.debug("smc.key.write.failed key=\(key, privacy: .public) value=\(value, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func smcGetFanCount(reply: @escaping (Bool, UInt, String?) -> Void) {
        do {
            try ensureConnected()
            guard let fanController = fanController else {
                reply(false, 0, "Connection not established")
                return
            }
            let (value, _) = try fanController.connection.readKey(SMCFanKey.count)
            let count = UInt(value[0])
            log.debug("smc.fan.count count=\(count, privacy: .public)")
            reply(true, count, nil)
        } catch {
            log.error("smc.fan.count.failed error=\(error.localizedDescription, privacy: .public)")
            reply(false, 0, error.localizedDescription)
        }
    }

    func smcGetFanInfo(
        _ fanIndex: UInt,
        reply: @escaping (Bool, Float, Float, Float, Float, Bool, String?) -> Void
    ) {
        do {
            try ensureConnected()

            let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) ?? 0
            let targetRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.target) ?? 0
            let minRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.minimum) ?? 0
            let maxRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.maximum) ?? 0

            let manualMode: Bool
            do {
                guard let fanController = fanController else { throw SMCError.notOpen }
                let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
                let (modeValue, _) = try fanController.connection.readKey(modeKey)
                manualMode = modeValue[0] == 1
            } catch {
                log.debug("smc.fan.mode.read.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                manualMode = false
            }

            log.debug("smc.fan.info fan=\(fanIndex, privacy: .public) actual=\(Int(actualRPM), privacy: .public) target=\(Int(targetRPM), privacy: .public) min=\(Int(minRPM), privacy: .public) max=\(Int(maxRPM), privacy: .public) manual=\(manualMode, privacy: .public)")
            reply(true, actualRPM, targetRPM, minRPM, maxRPM, manualMode, nil)
        } catch {
            log.error("smc.fan.info.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reply(false, 0, 0, 0, 0, false, error.localizedDescription)
        }
    }

    private func readFloat(fanIndex: UInt, keyFormat: String) -> Float? {
        let key = SMCFanKey.key(keyFormat, fan: Int(fanIndex))
        guard let fanController = fanController else { return nil }
        do {
            let (value, size) = try fanController.connection.readKey(key)
            return SMCDataFormat.float(from: value, size: size)
        } catch {
            log.debug("smc.key.read.failed key=\(key, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func smcSetFanRPM(
        _ fanIndex: UInt,
        rpm: Float,
        priority: Int,
        reply: @escaping (Bool, Bool, String?) -> Void
    ) {
        guard let clientID = self.callerID else {
            log.error("smc.fan.setrpm.no_connection fan=\(fanIndex, privacy: .public)")
            reply(false, false, "No XPC connection context")
            return
        }

        switch arbitrator.decideClaim(fan: fanIndex, priority: priority, clientID: clientID) {
        case .rejected(let ownerName, let ownerPriority):
            log.debug(
                "smc.fan.setrpm.preempted fan=\(fanIndex, privacy: .public) owner=\(ownerName, privacy: .public) owner_priority=\(ownerPriority, privacy: .public) caller_priority=\(priority, privacy: .public)"
            )
            reply(false, true, "preempted by \(ownerName) at priority \(ownerPriority)")
            return
        case .accepted(let clientName):
            log.info(
                "smc.fan.accepted fan=\(fanIndex, privacy: .public) rpm=\(Int(rpm), privacy: .public) client=\(clientName, privacy: .public) priority=\(priority, privacy: .public)"
            )
        }

        do {
            try ensureConnected()
        } catch {
            log.error("smc.fan.setrpm.connect.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reply(false, false, error.localizedDescription)
            return
        }

        guard let fanController = fanController else {
            reply(false, false, "Connection not established")
            return
        }

        let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
        let alreadyManual: Bool
        do {
            let (modeBytes, _) = try fanController.connection.readKey(modeKey)
            alreadyManual = !modeBytes.isEmpty && modeBytes[0] == 1
        } catch {
            log.debug("smc.fan.mode.read.failed fan=\(fanIndex, privacy: .public) assuming=auto")
            alreadyManual = false
        }

        if !alreadyManual {
            do {
                let strategy = try fanController.enableManualMode(fanIndex: Int(fanIndex))
                log.notice("fan.manual.enabled fan=\(fanIndex, privacy: .public) strategy=\(String(describing: strategy), privacy: .public)")
            } catch {
                log.error("fan.manual.enable.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                reply(false, false, error.localizedDescription)
                return
            }
        }

        let key = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
        let value = SMCDataFormat.bytes(from: rpm, size: 4)

        do {
            try fanController.connection.writeKey(key, bytes: value)
            log.notice("fan.rpm.set fan=\(fanIndex, privacy: .public) rpm=\(Int(rpm), privacy: .public)")
            reply(true, false, nil)

            let capturedFanIndex = fanIndex
            let capturedRPM = rpm
            fanVerifyLock.lock()
            fanVerifyTasks[capturedFanIndex]?.cancel()
            let newTask: Task<Void, Never> = Task { [weak self] in
                await self?.verifyFanSpeed(fanIndex: capturedFanIndex, targetRPM: capturedRPM)
            }
            fanVerifyTasks[capturedFanIndex] = newTask
            fanVerifyLock.unlock()
        } catch {
            log.error("fan.rpm.set.failed fan=\(fanIndex, privacy: .public) rpm=\(Int(rpm), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reply(false, false, error.localizedDescription)
        }
    }

    private func verifyFanSpeed(
        fanIndex: UInt,
        targetRPM: Float,
        timeout: TimeInterval = 30.0,
        interval: TimeInterval = 2.0
    ) async {
        let startTime = Date()
        let tolerance: Float = 0.10

        while Date().timeIntervalSince(startTime) < timeout {
            if Task.isCancelled {
                log.debug("fan.verify.cancelled fan=\(fanIndex, privacy: .public)")
                return
            }

            guard let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) else {
                log.error("fan.verify.lost fan=\(fanIndex, privacy: .public)")
                return
            }

            let diff = abs(actualRPM - targetRPM) / max(targetRPM, 1)
            log.debug("fan.verify.ramping fan=\(fanIndex, privacy: .public) actual=\(Int(actualRPM), privacy: .public) target=\(Int(targetRPM), privacy: .public) diff=\(String(format: "%.1f", diff * 100), privacy: .public)%")

            if diff <= tolerance {
                let elapsed = Date().timeIntervalSince(startTime)
                log.info("fan.verify.reached fan=\(fanIndex, privacy: .public) actual=\(Int(actualRPM), privacy: .public) target=\(Int(targetRPM), privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s")
                return
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                if error is CancellationError {
                    log.debug("fan.verify.cancelled fan=\(fanIndex, privacy: .public)")
                    return
                }
            }
        }

        if let actualRPM = readFloat(fanIndex: fanIndex, keyFormat: SMCFanKey.actual) {
            log.error("fan.verify.timeout fan=\(fanIndex, privacy: .public) actual=\(Int(actualRPM), privacy: .public) target=\(Int(targetRPM), privacy: .public) timeout=\(Int(timeout), privacy: .public)s")
        }
    }

    func smcSetFanAuto(
        _ fanIndex: UInt,
        priority: Int,
        reply: @escaping (Bool, Bool, String?) -> Void
    ) {
        guard let clientID = self.callerID else {
            log.error("smc.fan.setauto.no_connection fan=\(fanIndex, privacy: .public)")
            reply(false, false, "No XPC connection context")
            return
        }

        switch arbitrator.decideClaim(fan: fanIndex, priority: priority, clientID: clientID) {
        case .rejected(let ownerName, let ownerPriority):
            log.debug(
                "smc.fan.setauto.preempted fan=\(fanIndex, privacy: .public) owner=\(ownerName, privacy: .public) owner_priority=\(ownerPriority, privacy: .public) caller_priority=\(priority, privacy: .public)"
            )
            reply(false, true, "preempted by \(ownerName) at priority \(ownerPriority)")
            return
        case .accepted(let clientName):
            log.info(
                "smc.fan.auto.accepted fan=\(fanIndex, privacy: .public) client=\(clientName, privacy: .public) priority=\(priority, privacy: .public)"
            )
            // Setting auto is an explicit relinquish: drop ownership so
            // lower priority clients can immediately take the fan back
            // without waiting for the TTL to lapse.
            arbitrator.releaseOwnership(fan: fanIndex, clientID: clientID)
        }

        do {
            try ensureConnected()
        } catch {
            log.error("smc.fan.setauto.connect.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reply(false, false, error.localizedDescription)
            return
        }

        guard let fanController = fanController else {
            reply(false, false, "Connection not established")
            return
        }

        let fanCount: Int
        do {
            let (numBytes, _) = try fanController.connection.readKey(SMCFanKey.count)
            fanCount = Int(numBytes[0])
        } catch {
            log.error("smc.fan.count.failed error=\(error.localizedDescription, privacy: .public)")
            reply(false, false, "Failed to read fan count")
            return
        }

        var otherFansManual = 0
        for i in 0..<fanCount {
            if i == Int(fanIndex) { continue }
            let checkKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: i)
            do {
                let (checkBytes, _) = try fanController.connection.readKey(checkKey)
                if !checkBytes.isEmpty && checkBytes[0] == 1 { otherFansManual += 1 }
            } catch {
                continue
            }
        }

        let modeKey = SMCFanKey.key(fanController.config.modeKeyFormat, fan: Int(fanIndex))
        do {
            try fanController.connection.writeKey(modeKey, bytes: [0])
        } catch {
            log.error("fan.auto.mode.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: Int(fanIndex))
        let writeVal = SMCDataFormat.bytes(from: 0, size: 4)
        do {
            try fanController.connection.writeKey(targetKey, bytes: writeVal)
        } catch {
            log.error("fan.auto.target.reset.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }

        if otherFansManual > 0 {
            log.notice("fan.auto.set fan=\(fanIndex, privacy: .public) otherManual=\(otherFansManual, privacy: .public)")
        } else if fanController.config.ftstAvailable {
            do {
                let (ftstBytes, _) = try fanController.connection.readKey(SMCFanKey.forceTest)
                if !ftstBytes.isEmpty, ftstBytes[0] == 1 {
                    try fanController.resetFanControl()
                    log.notice("fan.auto.ftst.reset fan=\(fanIndex, privacy: .public)")
                }
            } catch {
                log.error("fan.auto.ftst.reset.failed fan=\(fanIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.notice("fan.auto.set fan=\(fanIndex, privacy: .public) allAuto=true noFtst=true")
        }

        reply(true, false, nil)
    }

    // MARK: - Arbitration surface

    func smcRegisterClient(name: String, reply: @escaping (Bool, String?) -> Void) {
        guard let clientID = self.callerID else {
            reply(false, "No XPC connection context")
            return
        }
        arbitrator.registerClientName(name, for: clientID)
        log.info(
            "smc.client.registered pid=\(NSXPCConnection.current()?.processIdentifier ?? 0, privacy: .public) name=\(name, privacy: .public)"
        )
        reply(true, nil)
    }

    func smcGetOwnership(
        reply: @escaping ([UInt], [String], [Int], [Double]) -> Void
    ) {
        let rows = arbitrator.getOwnershipSnapshot()
        reply(
            rows.map { $0.fanIndex },
            rows.map { $0.clientName },
            rows.map { $0.priority },
            rows.map { $0.ageSeconds }
        )
    }

    func smcEnumerateKeys(reply: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.ensureConnected()
                guard let fanController = self.fanController else {
                    reply([])
                    return
                }
                let keys = fanController.connection.enumerateKeys()
                log.debug("smc.keys.enumerated count=\(keys.count, privacy: .public)")
                reply(keys)
            } catch {
                log.error("smc.keys.enumerate.failed error=\(error.localizedDescription, privacy: .public)")
                reply([])
            }
        }
    }
}
