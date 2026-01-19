import XCTest
import Foundation

/// Integration tests that require the helper daemon to be installed and running
/// These tests interact with actual hardware and require root privileges
///
/// Run via: sudo make test-integration
/// NOT via: swift test (these will be skipped)
final class IntegrationTests: XCTestCase {
    
    private var helperConnection: NSXPCConnection?
    
    // Skip if not running as integration test
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Check if running with privileges
        guard geteuid() == 0 else {
            // Skip integration tests when running via `swift test`
            // These require: sudo make test-integration
            throw XCTSkip("Integration tests require root. Run: sudo make test-integration")
        }
        
        // Check if helper is installed
        let helperPath = "/Library/LaunchDaemons/io.goodkind.smcfanhelper.plist"
        guard FileManager.default.fileExists(atPath: helperPath) else {
            throw XCTSkip("Helper not installed. Run: make install")
        }
    }
    
    override func tearDown() {
        helperConnection?.invalidate()
        helperConnection = nil
        super.tearDown()
    }
    
    // MARK: - XPC Connection Tests
    
    func testHelperConnection() throws {
        let connection = NSXPCConnection(
            machServiceName: "io.goodkind.smcfanhelper",
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: NSObjectProtocol.self
        )
        connection.resume()
        
        // Connection should not be nil
        XCTAssertNotNil(connection)
        
        connection.invalidate()
    }
    
    // MARK: - Fan Read Tests
    
    func testReadFanCount() throws {
        let expectation = XCTestExpectation(description: "Read fan count")
        var fanCount: UInt = 0
        
        runCLI(["list"]) { output, exitCode in
            XCTAssertEqual(exitCode, 0, "CLI should exit with 0")
            
            // Parse "Fans: X" from output
            if let match = output.range(of: "Fans: (\\d+)", options: .regularExpression) {
                let numberStr = output[match].dropFirst(6)
                fanCount = UInt(numberStr) ?? 0
            }
            
            XCTAssertGreaterThan(fanCount, 0, "Should have at least 1 fan")
            XCTAssertLessThanOrEqual(fanCount, 4, "Should have at most 4 fans")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testReadFanInfo() throws {
        let expectation = XCTestExpectation(description: "Read fan info")
        
        runCLI(["list"]) { output, exitCode in
            XCTAssertEqual(exitCode, 0)
            
            // Should contain RPM info
            XCTAssertTrue(output.contains("RPM"), "Output should contain RPM values")
            XCTAssertTrue(output.contains("Min:"), "Output should contain min RPM")
            XCTAssertTrue(output.contains("Max:"), "Output should contain max RPM")
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    // MARK: - Fan Write Tests
    
    func testSetFanRPM() throws {
        let expectation = XCTestExpectation(description: "Set fan RPM")
        
        // Set to a moderate RPM
        runCLI(["set", "0", "4000"]) { output, exitCode in
            XCTAssertEqual(exitCode, 0, "Set command should succeed")
            XCTAssertTrue(output.contains("Set fan 0"), "Should confirm fan was set")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 15.0)
        
        // Verify the change
        let verifyExpectation = XCTestExpectation(description: "Verify RPM")
        
        // Wait for fan to ramp up
        Thread.sleep(forTimeInterval: 2.0)
        
        runCLI(["list"]) { output, exitCode in
            XCTAssertEqual(exitCode, 0)
            XCTAssertTrue(output.contains("Target: 4000"), "Target should be 4000 RPM")
            verifyExpectation.fulfill()
        }
        
        wait(for: [verifyExpectation], timeout: 10.0)
    }
    
    func testSetFanAuto() throws {
        let expectation = XCTestExpectation(description: "Set fan auto")
        
        runCLI(["auto", "0"]) { output, exitCode in
            XCTAssertEqual(exitCode, 0, "Auto command should succeed")
            XCTAssertTrue(output.contains("auto mode"), "Should confirm auto mode")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 15.0)
    }
    
    // MARK: - Full Cycle Test
    
    func testFullCycle_SetAndReset() throws {
        // 1. Get initial state
        let initialExpectation = XCTestExpectation(description: "Initial state")
        runCLI(["list"]) { output, _ in
            // Just verify we can read
            XCTAssertTrue(output.contains("Fan 0:"))
            initialExpectation.fulfill()
        }
        wait(for: [initialExpectation], timeout: 10.0)
        
        // 2. Set to high RPM
        let setExpectation = XCTestExpectation(description: "Set high")
        runCLI(["set", "0", "5500"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 15.0)
        
        // 3. Wait and verify increase
        Thread.sleep(forTimeInterval: 3.0)
        
        let verifyExpectation = XCTestExpectation(description: "Verify high")
        runCLI(["list"]) { output, _ in
            XCTAssertTrue(output.contains("Target: 5500"))
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)
        
        // 4. Reset to auto
        let resetExpectation = XCTestExpectation(description: "Reset")
        runCLI(["auto", "0"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            resetExpectation.fulfill()
        }
        wait(for: [resetExpectation], timeout: 15.0)
    }
    
    // MARK: - Error Handling Tests
    
    func testInvalidFanIndex() throws {
        let expectation = XCTestExpectation(description: "Invalid fan")
        
        runCLI(["set", "99", "4000"]) { output, exitCode in
            // Should fail gracefully
            XCTAssertNotEqual(exitCode, 0, "Should fail for invalid fan index")
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    // MARK: - Helpers
    
    private func runCLI(_ args: [String], completion: @escaping (String, Int32) -> Void) {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "Products/smcfan")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            completion(output, process.terminationStatus)
        } catch {
            completion("Error: \(error)", 1)
        }
    }
}
