// Sources/AppLog/BuildInfo.swift
//
// Moved from SMCFanLogging/LogBootstrap.swift.
// Emitted as a single process.started notice in AppLog.bootstrap.

import CryptoKit
import Foundation

public enum BuildInfo {
    public nonisolated(unsafe) static var commit = "unknown"
    public nonisolated(unsafe) static var version = "dev"
    public nonisolated(unsafe) static var dirty = "false"

    public static func buildHash() -> String {
        guard let exe = Bundle.main.executableURL,
            let data = try? Data(contentsOf: exe)
        else { return "unknown" }
        let digest = SHA256.hash(data: data)
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
