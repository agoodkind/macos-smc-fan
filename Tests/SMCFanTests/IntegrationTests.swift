//
//  IntegrationTests.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import XCTest

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

    // MARK: - Independent Fan Control Tests

    func testIndependentFanControl_SetFan1DoesNotAffectFan0() throws {
        // First reset both fans to auto
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
        Thread.sleep(forTimeInterval: 3.0)

        // Get initial state of Fan 0
        let initialExpectation = XCTestExpectation(description: "Initial state")
        runCLI(["list"]) { output, _ in
            // Verify Fan 0 exists and is in Auto mode
            XCTAssertTrue(output.contains("Fan 0:"), "Should have Fan 0")
            initialExpectation.fulfill()
        }
        wait(for: [initialExpectation], timeout: 10.0)

        // Set Fan 1 to manual
        let setExpectation = XCTestExpectation(description: "Set Fan 1")
        runCLI(["set", "1", "5000"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 2.0)

        // Verify Fan 0 is still in Auto mode
        let verifyExpectation = XCTestExpectation(description: "Verify independence")
        runCLI(["list"]) { output, _ in
            // Check Fan 0 line specifically
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                if line.contains("Fan 0:") {
                    XCTAssertTrue(line.contains("Mode: Auto"),
                                  "Fan 0 should remain in Auto mode when Fan 1 is set")
                }
                if line.contains("Fan 1:") {
                    XCTAssertTrue(line.contains("Mode: Manual"),
                                  "Fan 1 should be in Manual mode")
                    XCTAssertTrue(line.contains("Target: 5000"),
                                  "Fan 1 should have target 5000")
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "1"]) { _, _ in }
    }

    func testIndependentFanControl_BothFansManualDifferentSpeeds() throws {
        // Set Fan 0 to 4000 RPM
        let set0Expectation = XCTestExpectation(description: "Set Fan 0")
        runCLI(["set", "0", "4000"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            set0Expectation.fulfill()
        }
        wait(for: [set0Expectation], timeout: 15.0)

        // Set Fan 1 to 6000 RPM
        let set1Expectation = XCTestExpectation(description: "Set Fan 1")
        runCLI(["set", "1", "6000"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            set1Expectation.fulfill()
        }
        wait(for: [set1Expectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 2.0)

        // Verify both fans have independent targets
        let verifyExpectation = XCTestExpectation(description: "Verify targets")
        runCLI(["list"]) { output, _ in
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                if line.contains("Fan 0:") {
                    XCTAssertTrue(line.contains("Target: 4000"),
                                  "Fan 0 should have target 4000")
                    XCTAssertTrue(line.contains("Mode: Manual"),
                                  "Fan 0 should be Manual")
                }
                if line.contains("Fan 1:") {
                    XCTAssertTrue(line.contains("Target: 6000"),
                                  "Fan 1 should have target 6000")
                    XCTAssertTrue(line.contains("Mode: Manual"),
                                  "Fan 1 should be Manual")
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
    }

    func testPartialAutoMode_OneFanAutoOneManual() throws {
        // Set both fans to manual first
        runCLI(["set", "0", "5000"]) { _, _ in }
        runCLI(["set", "1", "5000"]) { _, _ in }
        Thread.sleep(forTimeInterval: 2.0)

        // Set Fan 1 to auto, Fan 0 stays manual
        let autoExpectation = XCTestExpectation(description: "Set Fan 1 auto")
        runCLI(["auto", "1"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            autoExpectation.fulfill()
        }
        wait(for: [autoExpectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 2.0)

        // Verify Fan 0 is still manual, Fan 1 is auto
        let verifyExpectation = XCTestExpectation(description: "Verify partial auto")
        runCLI(["list"]) { output, _ in
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                if line.contains("Fan 0:") {
                    XCTAssertTrue(line.contains("Mode: Manual"),
                                  "Fan 0 should still be Manual")
                }
                if line.contains("Fan 1:") {
                    XCTAssertTrue(line.contains("Mode: Auto"),
                                  "Fan 1 should be Auto")
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "0"]) { _, _ in }
    }

    func testSystemModeRestoration_AllFansAuto() throws {
        // Set a fan to manual first
        runCLI(["set", "0", "5000"]) { _, _ in }
        Thread.sleep(forTimeInterval: 2.0)

        // Set back to auto
        let autoExpectation = XCTestExpectation(description: "Set auto")
        runCLI(["auto", "0"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            autoExpectation.fulfill()
        }
        wait(for: [autoExpectation], timeout: 15.0)

        // Wait for thermalmonitord to reclaim control
        Thread.sleep(forTimeInterval: 5.0)

        // Verify fans are in auto mode with target 0
        // (on cold system, fans may drop to 0 RPM)
        let verifyExpectation = XCTestExpectation(description: "Verify system mode")
        runCLI(["list"]) { output, _ in
            XCTAssertTrue(output.contains("Mode: Auto"),
                          "Fans should be in Auto mode")
            XCTAssertTrue(output.contains("Target: 0"),
                          "Target should be 0 (system control)")
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)
    }

    // MARK: - Edge Case Tests

    func testSetZeroRPM_ManualStop() throws {
        // Setting 0 RPM should stop the fan completely while keeping manual mode
        let setExpectation = XCTestExpectation(description: "Set 0 RPM")
        runCLI(["set", "0", "0"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 2.0)

        let verifyExpectation = XCTestExpectation(description: "Verify 0 RPM")
        runCLI(["list"]) { output, _ in
            let lines = output.components(separatedBy: "\n")
            for line in lines where line.contains("Fan 0:") {
                XCTAssertTrue(line.contains("Target: 0"), "Target should be 0")
                XCTAssertTrue(line.contains("Mode: Manual"), "Mode should be Manual")
                // RPM should be 0 or very close
                if let match = line.range(of: "Fan 0: (\\d+) RPM", options: .regularExpression) {
                    let rpmStr = String(line[match]).replacingOccurrences(
                        of: "Fan 0: ", with: ""
                    ).replacingOccurrences(of: " RPM", with: "")
                    if let rpm = Int(rpmStr) {
                        XCTAssertLessThanOrEqual(rpm, 100, "RPM should be 0 or near 0")
                    }
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
        Thread.sleep(forTimeInterval: 3.0)
    }

    func testSetBelowMinRPM_Works() throws {
        // Hardware allows RPM below the reported "min" threshold
        // Reported min is ~2317, but 1000 RPM should work
        let setExpectation = XCTestExpectation(description: "Set below min")
        runCLI(["set", "0", "1000"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 3.0)

        let verifyExpectation = XCTestExpectation(description: "Verify below min")
        runCLI(["list"]) { output, _ in
            let lines = output.components(separatedBy: "\n")
            for line in lines where line.contains("Fan 0:") {
                XCTAssertTrue(line.contains("Target: 1000"), "Target should be 1000")
                // Actual RPM should be around 1000 (±100)
                if let match = line.range(of: "Fan 0: (\\d+) RPM", options: .regularExpression) {
                    let rpmStr = String(line[match]).replacingOccurrences(
                        of: "Fan 0: ", with: ""
                    ).replacingOccurrences(of: " RPM", with: "")
                    if let rpm = Int(rpmStr) {
                        XCTAssertGreaterThan(rpm, 800, "RPM should be around 1000")
                        XCTAssertLessThan(rpm, 1200, "RPM should be around 1000")
                    }
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
        Thread.sleep(forTimeInterval: 3.0)
    }

    func testSetAboveMaxRPM_ClampedToHardwareMax() throws {
        // Requesting above reported max (~7826) is clamped to hardware max (~8500)
        let setExpectation = XCTestExpectation(description: "Set above max")
        runCLI(["set", "0", "10000"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 5.0)

        let verifyExpectation = XCTestExpectation(description: "Verify clamped")
        runCLI(["list"]) { output, _ in
            let lines = output.components(separatedBy: "\n")
            for line in lines where line.contains("Fan 0:") {
                XCTAssertTrue(line.contains("Target: 10000"), "Target should be 10000")
                // Actual RPM should be clamped around 8400-8700
                if let match = line.range(of: "Fan 0: (\\d+) RPM", options: .regularExpression) {
                    let rpmStr = String(line[match]).replacingOccurrences(
                        of: "Fan 0: ", with: ""
                    ).replacingOccurrences(of: " RPM", with: "")
                    if let rpm = Int(rpmStr) {
                        XCTAssertGreaterThan(rpm, 8000, "RPM should be clamped ~8500")
                        XCTAssertLessThan(rpm, 9000, "RPM should be clamped ~8500")
                    }
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
        Thread.sleep(forTimeInterval: 3.0)
    }

    func testOtherFanWakesToAutoMin_WhenFirstFanGoesManual() throws {
        // When first fan goes manual (Ftst=1), other fans wake to their auto minimum
        // Reset both to auto first
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
        Thread.sleep(forTimeInterval: 5.0)

        // Verify both fans are at 0 RPM (system idle)
        let initialExpectation = XCTestExpectation(description: "Initial idle")
        var initialFan1RPM = 0
        runCLI(["list"]) { output, _ in
            if let match = output.range(of: "Fan 1: (\\d+) RPM", options: .regularExpression) {
                let rpmStr = String(output[match]).replacingOccurrences(
                    of: "Fan 1: ", with: ""
                ).replacingOccurrences(of: " RPM", with: "")
                initialFan1RPM = Int(rpmStr) ?? 0
            }
            initialExpectation.fulfill()
        }
        wait(for: [initialExpectation], timeout: 10.0)

        // Set Fan 0 to manual
        let setExpectation = XCTestExpectation(description: "Set Fan 0")
        runCLI(["set", "0", "5000"]) { _, exitCode in
            XCTAssertEqual(exitCode, 0)
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 15.0)
        Thread.sleep(forTimeInterval: 3.0)

        // Fan 1 should have woken to auto min (~2500 RPM)
        let verifyExpectation = XCTestExpectation(description: "Verify Fan 1 woke")
        runCLI(["list"]) { output, _ in
            let lines = output.components(separatedBy: "\n")
            for line in lines where line.contains("Fan 1:") {
                XCTAssertTrue(line.contains("Mode: Auto"), "Fan 1 should be Auto")
                // RPM should be around auto min (~2500)
                if let match = line.range(of: "Fan 1: (\\d+) RPM", options: .regularExpression) {
                    let rpmStr = String(line[match]).replacingOccurrences(
                        of: "Fan 1: ", with: ""
                    ).replacingOccurrences(of: " RPM", with: "")
                    if let rpm = Int(rpmStr) {
                        // If system was idle (0 RPM), Fan 1 should now be at auto min
                        if initialFan1RPM == 0 {
                            XCTAssertGreaterThan(rpm, 2000,
                                "Fan 1 should wake to auto min when Ftst is set")
                        }
                    }
                }
            }
            verifyExpectation.fulfill()
        }
        wait(for: [verifyExpectation], timeout: 10.0)

        // Cleanup
        runCLI(["auto", "0"]) { _, _ in }
        runCLI(["auto", "1"]) { _, _ in }
        Thread.sleep(forTimeInterval: 3.0)
    }

    // MARK: - Error Handling Tests

    func testInvalidFanIndex() throws {
        let expectation = XCTestExpectation(description: "Invalid fan")

        runCLI(["set", "99", "4000"]) { _, exitCode in
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
