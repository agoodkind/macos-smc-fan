//
//  HardwareConfig.swift
//  SMCFanKit
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-14.
//  Copyright © 2026
//

import AppLog
import Foundation
import SMCKit

private let log = AppLog.make(category: "FanControl")

// MARK: - Hardware Configuration

/// Hardware-specific SMC key configuration, detected at runtime.
public struct SMCHardwareConfig {
    /// The format string for the mode key (either "F%dmd" or "F%dMd" depending on hardware)
    public let modeKeyFormat: String

    /// Whether the Ftst (force test) key is available on this hardware
    public let ftstAvailable: Bool

    /// Initialize with explicit values
    public init(modeKeyFormat: String, ftstAvailable: Bool) {
        self.modeKeyFormat = modeKeyFormat
        self.ftstAvailable = ftstAvailable
    }
}

// MARK: - Hardware Detection

extension SMCHardwareConfig {
    /// Detect hardware-specific SMC key configuration by probing the connection.
    public static func detectHardwareKeys(connection: SMCConnection) throws -> SMCHardwareConfig {
        var modeKey = SMCFanKey.modeLower
        for candidate in [SMCFanKey.modeLower, SMCFanKey.modeUpper] {
            let testKey = SMCFanKey.key(candidate, fan: 0)
            if let (_, size) = try? connection.readKey(testKey), size > 0 {
                log.debug("hw.probe.modeKey key=\(testKey, privacy: .public) found=true size=\(size, privacy: .public) format=\(candidate, privacy: .public)")
                modeKey = candidate
                break
            } else {
                log.debug("hw.probe.modeKey key=\(testKey, privacy: .public) found=false")
            }
        }

        var ftst = false
        if let (_, size) = try? connection.readKey(SMCFanKey.forceTest), size > 0 {
            log.debug("hw.probe.ftst found=true size=\(size, privacy: .public)")
            ftst = true
        } else {
            log.debug("hw.probe.ftst found=false")
        }

        log.debug("hw.detected modeKeyFormat=\(modeKey, privacy: .public) ftstAvailable=\(ftst, privacy: .public)")
        return SMCHardwareConfig(modeKeyFormat: modeKey, ftstAvailable: ftst)
    }
}
