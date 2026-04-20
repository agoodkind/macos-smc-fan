//
//  FanControl.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-14.
//  Copyright © 2026
//

import AppLog
import Foundation
import SMCKit

private let log = AppLog.make(category: "FanControl")

// MARK: - Fan Control Strategy

/// Strategy used to enable manual fan control
public enum FanControlStrategy: Sendable {
    /// Direct mode key write succeeded
    case direct

    /// Ftst (force test) unlock was required
    case ftstUnlock
}

// MARK: - Fan Controller

/// Manages fan control operations on SMC hardware.
public class FanController {
    public let connection: SMCConnection
    public let config: SMCHardwareConfig

    public init(connection: SMCConnection) throws {
        self.connection = connection
        self.config = try SMCHardwareConfig.detectHardwareKeys(connection: connection)
    }

    public init(connection: SMCConnection, hardwareConfig: SMCHardwareConfig) {
        self.connection = connection
        self.config = hardwareConfig
    }

    // MARK: - Control Operations

    /// Enable manual fan control mode for a specific fan.
    public func enableManualMode(fanIndex: Int) throws -> FanControlStrategy {
        let modeKey = SMCFanKey.key(config.modeKeyFormat, fan: fanIndex)

        do {
            try connection.writeKey(modeKey, bytes: [1])
            log.debug("fan.manual.enabled fan=\(fanIndex, privacy: .public) modeKey=\(modeKey, privacy: .public) strategy=direct")
            return .direct
        } catch {
            log.debug("fan.manual.direct.failed fan=\(fanIndex, privacy: .public) modeKey=\(modeKey, privacy: .public) ftstAvailable=\(config.ftstAvailable, privacy: .public)")
            guard config.ftstAvailable else {
                log.error("fan.manual.failed fan=\(fanIndex, privacy: .public) reason=no-ftst")
                throw SMCError.firmware(.notFound)
            }
        }

        log.debug("fan.manual.ftst.start fan=\(fanIndex, privacy: .public)")
        try unlockFanControlSync(fanIndex: fanIndex)
        log.debug("fan.manual.enabled fan=\(fanIndex, privacy: .public) strategy=ftstUnlock")
        return .ftstUnlock
    }

    /// Synchronously unlock fan control using Ftst (force test) sequence.
    public func unlockFanControlSync(
        fanIndex: Int = 0,
        maxRetries: Int = 100,
        timeout: TimeInterval = 10.0
    ) throws {
        log.debug("fan.ftst.write fan=\(fanIndex, privacy: .public) value=1")
        try connection.writeKey(SMCFanKey.forceTest, bytes: [1])

        Thread.sleep(forTimeInterval: 0.5)

        let modeKey = SMCFanKey.key(config.modeKeyFormat, fan: fanIndex)
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)

        var attempt = 0
        for _ in 0..<maxRetries {
            attempt += 1
            do {
                try connection.writeKey(modeKey, bytes: [1])
                let elapsed = Date().timeIntervalSince(start)
                log.debug("fan.ftst.unlocked fan=\(fanIndex, privacy: .public) attempts=\(attempt, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                return
            } catch {
                if Date() >= deadline {
                    let elapsed = Date().timeIntervalSince(start)
                    log.error("fan.ftst.timeout fan=\(fanIndex, privacy: .public) attempts=\(attempt, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                    throw SMCError.timeout
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        log.error("fan.ftst.exhausted fan=\(fanIndex, privacy: .public) maxRetries=\(maxRetries, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
        throw SMCError.timeout
    }

    /// Asynchronously unlock fan control using Ftst (force test) sequence.
    public func unlockFanControl(
        fanIndex: Int = 0,
        maxRetries: Int = 100,
        timeout: TimeInterval = 10.0
    ) async throws {
        log.debug("fan.ftst.write fan=\(fanIndex, privacy: .public) value=1")
        try connection.writeKey(SMCFanKey.forceTest, bytes: [1])

        try await Task.sleep(nanoseconds: 500_000_000)

        let modeKey = SMCFanKey.key(config.modeKeyFormat, fan: fanIndex)
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)

        var attempt = 0
        for _ in 0..<maxRetries {
            attempt += 1
            do {
                try connection.writeKey(modeKey, bytes: [1])
                let elapsed = Date().timeIntervalSince(start)
                log.debug("fan.ftst.unlocked fan=\(fanIndex, privacy: .public) attempts=\(attempt, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                return
            } catch {
                if Date() >= deadline {
                    let elapsed = Date().timeIntervalSince(start)
                    log.error("fan.ftst.timeout fan=\(fanIndex, privacy: .public) attempts=\(attempt, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                    throw SMCError.timeout
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        log.error("fan.ftst.exhausted fan=\(fanIndex, privacy: .public) maxRetries=\(maxRetries, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
        throw SMCError.timeout
    }

    /// Reset fan control by disabling force test mode.
    public func resetFanControl() throws {
        log.debug("fan.ftst.reset value=0")
        try connection.writeKey(SMCFanKey.forceTest, bytes: [0])
        log.notice("fan.control.reset.done")
    }
}
