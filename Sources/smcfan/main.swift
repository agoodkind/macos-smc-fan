import Foundation

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
    static func main() {
        let args = CommandLine.arguments
        
        guard args.count >= 2 else {
            printUsage(args[0])
            exit(1)
        }
        
        let command = args[1]
        
        let helperID = String(utf8String: HELPER_ID) ?? ""
        let connection = NSXPCConnection(
            machServiceName: helperID,
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
        
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        
        proxy.smcOpen { success, error in
            guard success else {
                if let error = error {
                    print("Failed to open SMC: \(error)")
                }
                exitCode = 1
                semaphore.signal()
                return
            }
            
            switch command {
            case "list":
                proxy.smcGetFanCount { success, count, error in
                    guard success else {
                        if let error = error {
                            print("Failed to get fan count: \(error)")
                        }
                        exitCode = 1
                        semaphore.signal()
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
                        semaphore.signal()
                    }
                }
                
            case "set":
                guard args.count >= 4 else {
                    print("Usage: smcfan set <fan> <rpm>")
                    exitCode = 1
                    semaphore.signal()
                    return
                }
                
                guard let fan = Int(args[2]),
                      let rpm = Float(args[3]) else {
                    print("Invalid fan or RPM value")
                    exitCode = 1
                    semaphore.signal()
                    return
                }
                
                proxy.smcSetFanRPM(UInt(fan), rpm: rpm) { success, error in
                    if success {
                        print("Set fan \(fan) to \(Int(rpm)) RPM")
                    } else {
                        if let error = error {
                            print("Failed to set speed: \(error)")
                        }
                        exitCode = 1
                    }
                    semaphore.signal()
                }
                
            case "auto":
                guard args.count >= 3 else {
                    print("Usage: smcfan auto <fan>")
                    exitCode = 1
                    semaphore.signal()
                    return
                }
                
                guard let fan = Int(args[2]) else {
                    print("Invalid fan value")
                    exitCode = 1
                    semaphore.signal()
                    return
                }
                
                proxy.smcSetFanAuto(UInt(fan)) { success, error in
                    if success {
                        print("Set fan \(fan) to auto mode")
                    } else {
                        if let error = error {
                            print("Failed to set auto mode: \(error)")
                        }
                        exitCode = 1
                    }
                    semaphore.signal()
                }
                
            case "read":
                guard args.count >= 3 else {
                    print("Usage: smcfan read <key>")
                    exitCode = 1
                    semaphore.signal()
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
                        exitCode = 1
                    }
                    semaphore.signal()
                }
                
            default:
                printUsage(args[0])
                exitCode = 1
                semaphore.signal()
            }
        }
        
        semaphore.wait()
        connection.invalidate()
        exit(exitCode)
    }
}
