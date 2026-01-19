import Foundation
import SMCCommon

/// Manages XPC connection to the privileged helper
class XPCClient {
    private let connection: NSXPCConnection
    private let proxy: SMCFanHelperProtocol
    
    init() throws {
        let config = SMCFanConfiguration.default
        
        connection = NSXPCConnection(
            machServiceName: config.helperBundleID,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SMCFanHelperProtocol.self)
        connection.resume()
        
        guard let p = connection.remoteObjectProxyWithErrorHandler({ error in
            print("XPC connection failed: \(error)")
            exit(1)
        }) as? SMCFanHelperProtocol else {
            throw NSError(
                domain: "XPCError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create proxy"]
            )
        }
        
        proxy = p
    }
    
    deinit {
        connection.invalidate()
    }
    
    // MARK: - SMC Operations
    
    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.smcOpen { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SMCError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Unknown error"]
                    ))
                }
            }
        }
    }
    
    func getFanCount() async throws -> UInt {
        try await withCheckedThrowingContinuation { continuation in
            proxy.smcGetFanCount { success, count, error in
                if success {
                    continuation.resume(returning: count)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SMCError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Unknown error"]
                    ))
                }
            }
        }
    }
    
    func getFanInfo(_ index: UInt) async throws -> FanInfo {
        try await withCheckedThrowingContinuation { continuation in
            proxy.smcGetFanInfo(index) { success, actual, target, min, max, manual, error in
                if success {
                    continuation.resume(returning: FanInfo(
                        actualRPM: actual,
                        targetRPM: target,
                        minRPM: min,
                        maxRPM: max,
                        manualMode: manual
                    ))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SMCError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Unknown error"]
                    ))
                }
            }
        }
    }
    
    func setFanRPM(_ index: UInt, rpm: Float) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.smcSetFanRPM(index, rpm: rpm) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SMCError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Unknown error"]
                    ))
                }
            }
        }
    }
    
    func setFanAuto(_ index: UInt) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.smcSetFanAuto(index) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SMCError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Unknown error"]
                    ))
                }
            }
        }
    }
    
    func readKey(_ key: String) async throws -> Float {
        try await withCheckedThrowingContinuation { continuation in
            proxy.smcReadKey(key) { success, value, error in
                if success {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SMCError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error ?? "Unknown error"]
                    ))
                }
            }
        }
    }
}
