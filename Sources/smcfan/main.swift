import Foundation
#if !canImport_smcfan_config
import SMCCommon  // SPM build
#endif

actor ExitCode {
    private var value: Int32 = 0
    
    func set(_ newValue: Int32) {
        value = newValue
    }
    
    func get() -> Int32 {
        value
    }
}

func printUsage(_ programName: String) {
    print("Usage: \(programName) <command> [args...]")
    print("\nCommands:")
    print("  list              List all fans with current status")
    print("  set <fan> <rpm>   Set fan speed to specified RPM")
    print("  auto <fan>        Return fan to automatic control")
    print("  read <key>        Read value of SMC key")
    print("  help              Show this help message")
}

@main
struct SMCFan {
    static func main() async {
        let args = CommandLine.arguments
        
        guard args.count >= 2 else {
            printUsage(args[0])
            exit(1)
        }
        
        let command = args[1]
        let config = SMCFanConfiguration.default
        
        let connection = NSXPCConnection(
            machServiceName: config.helperBundleID,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: SMCFanHelperProtocol.self
        )
        connection.resume()
        
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({
            error in
            print("XPC connection failed: \(error)")
            exit(1)
        }) as? SMCFanHelperProtocol else {
            print("Failed to create proxy")
            exit(1)
        }
        
        let exitCode = ExitCode()
        
        await withCheckedContinuation { continuation in
            proxy.smcOpen { success, error in
            guard success else {
                if let error = error {
                    print("Failed to open SMC: \(error)")
                }
                Task { await exitCode.set(1) }
                continuation.resume()
                return
            }
            
            switch command {
            case "list":
                    proxy.smcGetFanCount { success, count, error in
                        guard success else {
                            if let error = error {
                                print("Failed to get fan count: \(error)")
                            }
                            Task { await exitCode.set(1) }
                            continuation.resume()
                            return
                        }
                        
                        print("Fans: \(count)")
                        
                        let group = DispatchGroup()
                        
                        for i in 0..<count {
                            group.enter()
                            proxy.smcGetFanInfo(i) {
                                success, actualRPM, targetRPM, minRPM, maxRPM, manualMode, error in
                                if success {
                                    let info = FanInfo(
                                        actualRPM: actualRPM,
                                        targetRPM: targetRPM,
                                        minRPM: minRPM,
                                        maxRPM: maxRPM,
                                        manualMode: manualMode
                                    )
                                    print(
                                        "Fan \(i): \(Int(info.actualRPM)) RPM " +
                                        "(Target: \(Int(info.targetRPM)), " +
                                        "Min: \(Int(info.minRPM)), " +
                                        "Max: \(Int(info.maxRPM)), " +
                                        "Mode: \(info.manualMode ? "Manual" : "Auto"))"
                                    )
                                } else {
                                    print("Fan \(i): Error reading info")
                                }
                                group.leave()
                            }
                        }
                        
                        group.notify(queue: .global()) {
                            continuation.resume()
                        }
                    }
                
            case "set":
                guard args.count >= 4 else {
                    print("Usage: smcfan set <fan> <rpm>")
                    Task { await exitCode.set(1) }
                    continuation.resume()
                    return
                }
                
                guard let fan = Int(args[2]),
                      let rpm = Float(args[3]) else {
                    print("Invalid fan or RPM value")
                    Task { await exitCode.set(1) }
                    continuation.resume()
                    return
                }
                
                proxy.smcSetFanRPM(UInt(fan), rpm: rpm) { success, error in
                    if success {
                        print("Set fan \(fan) to \(Int(rpm)) RPM")
                    } else {
                        if let error = error {
                            print("Failed to set speed: \(error)")
                        }
                        Task { await exitCode.set(1) }
                    }
                    continuation.resume()
                }
                
            case "auto":
                guard args.count >= 3 else {
                    print("Usage: smcfan auto <fan>")
                    Task { await exitCode.set(1) }
                    continuation.resume()
                    return
                }
                
                guard let fan = Int(args[2]) else {
                    print("Invalid fan value")
                    Task { await exitCode.set(1) }
                    continuation.resume()
                    return
                }
                
                proxy.smcSetFanAuto(UInt(fan)) { success, error in
                    if success {
                        print("Set fan \(fan) to auto mode")
                    } else {
                        if let error = error {
                            print("Failed to set auto mode: \(error)")
                        }
                        Task { await exitCode.set(1) }
                    }
                    continuation.resume()
                }
                
            case "read":
                guard args.count >= 3 else {
                    print("Usage: smcfan read <key>")
                    Task { await exitCode.set(1) }
                    continuation.resume()
                    return
                }
                
                let key = args[2]
                proxy.smcReadKey(key) { success, value, error in
                    if success {
                        print("\(key) = \(value)")
                    } else {
                        if let error = error {
                            print("Failed to read key: \(error)")
                        }
                        Task { await exitCode.set(1) }
                    }
                    continuation.resume()
                }
                
            default:
                printUsage(args[0])
                Task { await exitCode.set(1) }
                continuation.resume()
            }
            }
        }
        
        connection.invalidate()
        exit(await exitCode.get())
    }
}
