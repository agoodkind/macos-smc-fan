//
//  Commands.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCCommon

/// Shared command implementations used by both ArgumentParser and simple CLI
enum Commands {
    
    static func list() async throws {
        let client = try XPCClient()
        try await client.open()
        
        let count = try await client.getFanCount()
        print("Fans: \(count)")
        
        for i in 0..<count {
            let info = try await client.getFanInfo(i)
            print(
                "Fan \(i): \(Int(info.actualRPM)) RPM " +
                "(Target: \(Int(info.targetRPM)), " +
                "Min: \(Int(info.minRPM)), " +
                "Max: \(Int(info.maxRPM)), " +
                "Mode: \(info.manualMode ? "Manual" : "Auto"))"
            )
        }
    }
    
    static func set(fan: Int, rpm: Float) async throws {
        let client = try XPCClient()
        try await client.open()
        try await client.setFanRPM(UInt(fan), rpm: rpm)
        print("Set fan \(fan) to \(Int(rpm)) RPM")
    }
    
    static func auto(fan: Int) async throws {
        let client = try XPCClient()
        try await client.open()
        try await client.setFanAuto(UInt(fan))
        print("Set fan \(fan) to auto mode")
    }
    
    static func read(key: String) async throws {
        let client = try XPCClient()
        try await client.open()
        let value = try await client.readKey(key)
        print("\(key) = \(value)")
    }
    
    static func printUsage() {
        print("Usage: smcfan <command> [args...]")
        print("")
        print("Commands:")
        print("  list              List all fans with current status (default)")
        print("  set <fan> <rpm>   Set fan speed to specified RPM")
        print("  auto <fan>        Return fan to automatic control")
        print("  read <key>        Read value of SMC key")
        print("  help, -h, --help  Show this help message")
    }
}
