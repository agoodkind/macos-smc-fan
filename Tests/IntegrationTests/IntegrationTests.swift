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
  private var hw: HardwareExpectations!

  override class func setUp() {
    super.setUp()
    resetAllFansToAuto()
  }

  override func setUpWithError() throws {
    try super.setUpWithError()

    guard geteuid() == 0 else {
      throw XCTSkip("Integration tests require root. Run: sudo make test-integration")
    }

    let model = HardwareExpectations.currentModel
    guard let detected = HardwareExpectations.detect() else {
      throw XCTSkip(
        "Unknown hardware model: \(model). "
          + "Add a HardwareExpectations entry to run integration tests on this machine."
      )
    }
    hw = detected
    fputs("[setup] Hardware: \(hw.chipName) (\(hw.modelIdentifier))\n", stderr)
    fflush(stderr)

    if #available(macOS 13.0, *) {
      let appPath = "/Applications/SMCFanHelper.app"
      guard FileManager.default.fileExists(atPath: appPath) else {
        throw XCTSkip("SMCFanHelper.app not found in /Applications")
      }
    } else {
      let helperPath = "/Library/LaunchDaemons/io.goodkind.smcfanhelper.plist"
      guard FileManager.default.fileExists(atPath: helperPath) else {
        throw XCTSkip("Helper not installed. Run: make install")
      }
    }
  }

  override func tearDown() {
    helperConnection?.invalidate()
    helperConnection = nil
    super.tearDown()
  }

  // MARK: - SMC Key Diagnostics
  // These run first (alphabetical) and catch hardware-level issues
  // before any fan control tests. If these fail, the rest will too,
  // and the output tells you exactly why.

  func testA_SMCKeyDiscovery() throws {
    // Probe individual keys to detect casing and availability.
    // This catches the F0Md vs F0md issue without using the `keys` enumeration command.
    let fnumResult = runCLISync(["read", "FNum"])
    XCTAssertEqual(fnumResult.exitCode, 0, "FNum key must exist")

    // Check which mode key variant exists
    let lowerResult = runCLISync(["read", "F0md"])
    let upperResult = runCLISync(["read", "F0Md"])
    let hasLowerMode = lowerResult.exitCode == 0
    let hasUpperMode = upperResult.exitCode == 0

    fputs("[test] Mode key: F0md=\(hasLowerMode) F0Md=\(hasUpperMode)\n", stderr)
    XCTAssertTrue(
      hasLowerMode || hasUpperMode, "Neither F0md nor F0Md found. Fan mode key missing from SMC.")

    // Verify against hardware expectations
    if hw.modeKeyFormat == "F%dmd" {
      XCTAssertTrue(hasLowerMode, "[\(hw.chipName)] Expected lowercase mode key")
    } else {
      XCTAssertTrue(hasUpperMode, "[\(hw.chipName)] Expected uppercase mode key")
    }

    // Check Ftst
    let ftstResult = runCLISync(["read", "Ftst"])
    let hasFtst = ftstResult.exitCode == 0
    fputs("[test] Ftst available: \(hasFtst)\n", stderr)
    XCTAssertEqual(
      hasFtst, hw.ftstPresent,
      "[\(hw.chipName)] Ftst expectation mismatch: expected=\(hw.ftstPresent) actual=\(hasFtst)")

    fputs("[test] === Hardware Config ===\n", stderr)
    fputs(
      "[test] Mode key: \(hasLowerMode ? "F%dmd (lowercase)" : "F%dMd (uppercase)")\n", stderr)
    fputs(
      "[test] Ftst: \(hasFtst ? "present (unlock sequence)" : "absent (direct mode writes)")\n",
      stderr)
    fflush(stderr)
  }

  func testA_SMCReadKeyInfo() throws {
    // Verify readKeyInfo succeeds for all expected fan keys.
    // If this fails with SmcNotFound (0x84), the key name is wrong.
    let expectedKeys = ["FNum", "F0Ac", "F0Tg", "F0Mn", "F0Mx"]

    for key in expectedKeys {
      let result = runCLISync(["read", key])
      XCTAssertEqual(
        result.exitCode, 0,
        "readKeyInfo(\(key)) failed. exit=\(result.exitCode) output=\(result.output)")
    }

    // Mode key: try both casings, at least one must work
    let lowerResult = runCLISync(["read", "F0md"])
    let upperResult = runCLISync(["read", "F0Md"])
    let modeReadable = lowerResult.exitCode == 0 || upperResult.exitCode == 0
    XCTAssertTrue(
      modeReadable,
      "Neither F0md nor F0Md readable. Lower: exit=\(lowerResult.exitCode) [\(lowerResult.output.trimmingCharacters(in: .whitespacesAndNewlines))], Upper: exit=\(upperResult.exitCode) [\(upperResult.output.trimmingCharacters(in: .whitespacesAndNewlines))]"
    )
  }

  func testA_HardwareDetectionLogs() throws {
    // Verify the helper logs hardware detection on startup.
    // The helper output should contain detection results.
    let result = runCLISync(["list"])
    XCTAssertEqual(result.exitCode, 0, "list command failed")

    // Check that hardware detection ran and reported
    let output = result.output
    let hasDetection = output.contains("detectHardwareKeys") || output.contains("modeKey=")
    if hasDetection {
      print("Hardware detection output found in helper logs")
    } else {
      print("Note: hardware detection logs not visible in CLI output (check os_log)")
    }

    // The list output itself validates that reads work
    XCTAssertTrue(output.contains("Fans:"), "list should show fan count")
    XCTAssertTrue(output.contains("Min:"), "list should show min RPM")
    XCTAssertTrue(output.contains("Max:"), "list should show max RPM")
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

    runCLISet(["set", "0", "4000"]) { output, exitCode in
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

  /// Exercises the same condition as SMCFanHelper.verifyFanSpeed: actual RPM
  /// reaches target within 10% within 30s after set.
  func testFanSpeedVerification_ActualReachesTargetWithinTolerance() throws {
    let targetRPM: Float = 4000
    let tolerance: Float = 0.10
    let timeout: TimeInterval = 30.0
    let interval: TimeInterval = 2.0

    let setExpectation = XCTestExpectation(description: "Set fan RPM")
    runCLISet(["set", "0", String(Int(targetRPM))]) { _, exitCode in
      XCTAssertEqual(exitCode, 0, "Set command should succeed")
      setExpectation.fulfill()
    }
    wait(for: [setExpectation], timeout: 15.0)

    let startTime = Date()
    var actualRPM: Float = 0

    while Date().timeIntervalSince(startTime) < timeout {
      Thread.sleep(forTimeInterval: interval)

      let pollExpectation = XCTestExpectation(description: "Poll list")
      runCLI(["list"]) { output, _ in
        if let match = output.range(of: "Fan 0: (\\d+) RPM", options: .regularExpression) {
          let rpmStr = String(output[match]).replacingOccurrences(of: "Fan 0: ", with: "")
            .replacingOccurrences(of: " RPM", with: "")
          actualRPM = Float(rpmStr) ?? 0
        }
        pollExpectation.fulfill()
      }
      wait(for: [pollExpectation], timeout: 10.0)

      let diff = abs(actualRPM - targetRPM) / max(targetRPM, 1)
      if diff <= tolerance {
        runCLI(["auto", "0"]) { _, _ in }
        return
      }
    }

    runCLI(["auto", "0"]) { _, _ in }
    XCTFail(
      "Fan 0 actual RPM \(Int(actualRPM)) did not reach target \(Int(targetRPM)) within 10% after \(timeout)s"
    )
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
    runCLISet(["set", "0", "5500"]) { _, exitCode in
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

    let setExpectation = XCTestExpectation(description: "Set Fan 1")
    runCLISet(["set", "1", "5000"]) { _, exitCode in
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
          XCTAssertTrue(
            line.contains("Mode: Auto"),
            "Fan 0 should remain in Auto mode when Fan 1 is set")
        }
        if line.contains("Fan 1:") {
          XCTAssertTrue(
            line.contains("Mode: Manual"),
            "Fan 1 should be in Manual mode")
          XCTAssertTrue(
            line.contains("Target: 5000"),
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
    let set0Expectation = XCTestExpectation(description: "Set Fan 0")
    runCLISet(["set", "0", "4000"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      set0Expectation.fulfill()
    }
    wait(for: [set0Expectation], timeout: 15.0)

    let set1Expectation = XCTestExpectation(description: "Set Fan 1")
    runCLISet(["set", "1", "6000"]) { _, exitCode in
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
          XCTAssertTrue(
            line.contains("Target: 4000"),
            "Fan 0 should have target 4000")
          XCTAssertTrue(
            line.contains("Mode: Manual"),
            "Fan 0 should be Manual")
        }
        if line.contains("Fan 1:") {
          XCTAssertTrue(
            line.contains("Target: 6000"),
            "Fan 1 should have target 6000")
          XCTAssertTrue(
            line.contains("Mode: Manual"),
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
    runCLISet(["set", "0", "5000"]) { _, _ in }
    runCLISet(["set", "1", "5000"]) { _, _ in }
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
          XCTAssertTrue(
            line.contains("Mode: Manual"),
            "Fan 0 should still be Manual")
        }
        if line.contains("Fan 1:") {
          XCTAssertTrue(
            line.contains("Mode: Auto"),
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
    runCLISet(["set", "0", "5000"]) { _, _ in }
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

    // Verify fans are in auto mode. Target depends on thermal state and hardware.
    let verifyExpectation = XCTestExpectation(description: "Verify system mode")
    runCLI(["list"]) { [hw] output, _ in
      XCTAssertTrue(
        output.contains("Mode: Auto"),
        "Fans should be in Auto mode")
      switch hw!.autoModeTarget {
      case .zero:
        XCTAssertTrue(
          output.contains("Target: 0"),
          "[\(hw!.chipName)] Target should be 0 (system control)")
      case .minRPM:
        XCTAssertTrue(
          output.contains("Target: \(hw!.reportedMinRPM)"),
          "[\(hw!.chipName)] Target should be \(hw!.reportedMinRPM) (thermalmonitord)")
      case .zeroOrMinRPM:
        let hasZero = output.contains("Target: 0")
        let hasMin = output.contains("Target: \(hw!.reportedMinRPM)")
        XCTAssertTrue(
          hasZero || hasMin,
          "[\(hw!.chipName)] Target should be 0 or \(hw!.reportedMinRPM)")
      }
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)
  }

  // MARK: - Edge Case Tests

  func testSetZeroRPM_ManualStop() throws {
    // Setting 0 RPM should stop the fan completely while keeping manual mode
    let setExpectation = XCTestExpectation(description: "Set 0 RPM")
    runCLISet(["set", "0", "0"]) { _, exitCode in
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
            XCTAssertLessThanOrEqual(rpm, 250, "RPM should be 0 or near 0")
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
    let setExpectation = XCTestExpectation(description: "Set below min")
    runCLISet(["set", "0", "1000"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      setExpectation.fulfill()
    }
    wait(for: [setExpectation], timeout: 15.0)
    Thread.sleep(forTimeInterval: 3.0)

    let verifyExpectation = XCTestExpectation(description: "Verify below min")
    runCLI(["list"]) { [hw] output, _ in
      let lines = output.components(separatedBy: "\n")
      for line in lines where line.contains("Fan 0:") {
        switch hw!.belowMinBehavior {
        case .preserved:
          XCTAssertTrue(
            line.contains("Target: 1000"),
            "[\(hw!.chipName)] Target should be preserved as 1000")
        case .clampedToMin:
          XCTAssertTrue(
            line.contains("Target: \(hw!.reportedMinRPM)"),
            "[\(hw!.chipName)] Target should be clamped to min (\(hw!.reportedMinRPM))")
        }
        if let match = line.range(of: "Fan 0: (\\d+) RPM", options: .regularExpression) {
          let rpmStr = String(line[match]).replacingOccurrences(
            of: "Fan 0: ", with: ""
          ).replacingOccurrences(of: " RPM", with: "")
          if let rpm = Int(rpmStr) {
            XCTAssertLessThanOrEqual(
              rpm, hw!.reportedMinRPM + hw!.rpmTolerance,
              "[\(hw!.chipName)] RPM should be at or below hardware min")
          }
        }
      }
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)

    runCLI(["auto", "0"]) { _, _ in }
    runCLI(["auto", "1"]) { _, _ in }
    Thread.sleep(forTimeInterval: 3.0)
  }

  func testSetAboveMaxRPM_ClampedToHardwareMax() throws {
    let setExpectation = XCTestExpectation(description: "Set above max")
    runCLISet(["set", "0", "10000"]) { _, exitCode in
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
        if let match = line.range(of: "Fan 0: (\\d+) RPM", options: .regularExpression) {
          let rpmStr = String(line[match]).replacingOccurrences(
            of: "Fan 0: ", with: ""
          ).replacingOccurrences(of: " RPM", with: "")
          if let rpm = Int(rpmStr) {
            XCTAssertGreaterThan(rpm, 2000, "RPM should reflect manual target or clamp")
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

    let setExpectation = XCTestExpectation(description: "Set Fan 0")
    runCLISet(["set", "0", "5000"]) { _, exitCode in
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
              XCTAssertGreaterThan(
                rpm, 2000,
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

  // MARK: - State Transition Tests

  /// Tests state transitions as defined in research/test_transitions.sh
  /// Records transition times and verifies state changes
  func testTransition_AutoToManual() throws {
    // Start from clean auto state
    runCLI(["auto", "0"]) { _, _ in }
    runCLI(["auto", "1"]) { _, _ in }
    Thread.sleep(forTimeInterval: 3.0)

    let expectation = XCTestExpectation(description: "Auto to Manual")
    let startTime = CFAbsoluteTimeGetCurrent()

    runCLISet(["set", "1", "5000"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0, "Set command should succeed")
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 15.0)

    waitForStateStable()

    let transitionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    print("Transition time (Auto → Manual): \(Int(transitionTime))ms")

    // Verify Fan 1 is now in Manual mode
    let verifyExpectation = XCTestExpectation(description: "Verify Manual")
    runCLI(["list"]) { output, _ in
      let lines = output.components(separatedBy: "\n")
      for line in lines where line.contains("Fan 1:") {
        XCTAssertTrue(line.contains("Mode: Manual"), "Fan 1 should be Manual")
        XCTAssertTrue(line.contains("Target: 5000"), "Fan 1 target should be 5000")
      }
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)

    // Cleanup
    runCLI(["auto", "1"]) { _, _ in }
  }

  func testTransition_BothFansManual() throws {
    // Start from clean auto state
    runCLI(["auto", "0"]) { _, _ in }
    runCLI(["auto", "1"]) { _, _ in }
    Thread.sleep(forTimeInterval: 3.0)

    let set1Expectation = XCTestExpectation(description: "Set Fan 1")
    runCLISet(["set", "1", "5000"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      set1Expectation.fulfill()
    }
    wait(for: [set1Expectation], timeout: 15.0)
    Thread.sleep(forTimeInterval: 2.0)

    let startTime = CFAbsoluteTimeGetCurrent()
    let set0Expectation = XCTestExpectation(description: "Set Fan 0")
    runCLISet(["set", "0", "6000"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      set0Expectation.fulfill()
    }
    wait(for: [set0Expectation], timeout: 15.0)

    waitForStateStable()
    let transitionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    print("Transition time (Partial → Both Manual): \(Int(transitionTime))ms")

    // Verify both fans are in Manual mode with different targets
    let verifyExpectation = XCTestExpectation(description: "Verify both manual")
    runCLI(["list"]) { output, _ in
      let lines = output.components(separatedBy: "\n")
      for line in lines {
        if line.contains("Fan 0:") {
          XCTAssertTrue(line.contains("Mode: Manual"), "Fan 0 should be Manual")
          XCTAssertTrue(line.contains("Target: 6000"), "Fan 0 target should be 6000")
        }
        if line.contains("Fan 1:") {
          XCTAssertTrue(line.contains("Mode: Manual"), "Fan 1 should be Manual")
          XCTAssertTrue(line.contains("Target: 5000"), "Fan 1 target should be 5000")
        }
      }
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)

    // Cleanup
    runCLI(["auto", "0"]) { _, _ in }
    runCLI(["auto", "1"]) { _, _ in }
  }

  func testTransition_PartialAuto() throws {
    runCLISet(["set", "0", "6000"]) { _, _ in }
    runCLISet(["set", "1", "5000"]) { _, _ in }
    Thread.sleep(forTimeInterval: 3.0)

    // Return Fan 1 to auto (Fan 0 still manual)
    let startTime = CFAbsoluteTimeGetCurrent()
    let autoExpectation = XCTestExpectation(description: "Set Fan 1 auto")
    runCLI(["auto", "1"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      autoExpectation.fulfill()
    }
    wait(for: [autoExpectation], timeout: 15.0)

    waitForStateStable()
    let transitionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    print("Transition time (Both Manual → Partial Auto): \(Int(transitionTime))ms")

    // Verify Fan 0 is Manual, Fan 1 is Auto
    let verifyExpectation = XCTestExpectation(description: "Verify partial auto")
    runCLI(["list"]) { output, _ in
      let lines = output.components(separatedBy: "\n")
      for line in lines {
        if line.contains("Fan 0:") {
          XCTAssertTrue(line.contains("Mode: Manual"), "Fan 0 should still be Manual")
        }
        if line.contains("Fan 1:") {
          XCTAssertTrue(line.contains("Mode: Auto"), "Fan 1 should be Auto")
        }
      }
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)

    // Cleanup
    runCLI(["auto", "0"]) { _, _ in }
  }

  func testTransition_SystemModeRestored() throws {
    runCLISet(["set", "0", "5000"]) { _, _ in }
    Thread.sleep(forTimeInterval: 2.0)

    // Return last fan to auto (should trigger Ftst=0)
    let startTime = CFAbsoluteTimeGetCurrent()
    let autoExpectation = XCTestExpectation(description: "Set Fan 0 auto")
    runCLI(["auto", "0"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      autoExpectation.fulfill()
    }
    wait(for: [autoExpectation], timeout: 15.0)

    // Wait for thermalmonitord to reclaim control
    Thread.sleep(forTimeInterval: 5.0)

    let transitionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    print("Transition time (Manual → System Mode): \(Int(transitionTime))ms")

    // Verify fans are in auto mode
    let verifyExpectation = XCTestExpectation(description: "Verify system mode")
    runCLI(["list"]) { output, _ in
      XCTAssertTrue(output.contains("Mode: Auto"), "Fans should be in Auto mode")
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)
  }

  func testTransition_ManualToManual_Fast() throws {
    runCLISet(["set", "0", "4000"]) { _, _ in }
    Thread.sleep(forTimeInterval: 2.0)

    let startTime = CFAbsoluteTimeGetCurrent()
    let setExpectation = XCTestExpectation(description: "Change RPM")
    runCLISet(["set", "0", "5000"]) { _, exitCode in
      XCTAssertEqual(exitCode, 0)
      setExpectation.fulfill()
    }
    wait(for: [setExpectation], timeout: 15.0)

    waitForStateStable()
    let transitionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
    print("Transition time (Manual → Manual): \(Int(transitionTime))ms")

    // Manual-to-manual should be faster than auto-to-manual
    // since Ftst is already set
    XCTAssertLessThan(
      transitionTime, 30_000,
      "Manual-to-manual transition should complete within 30s")

    // Verify new target
    let verifyExpectation = XCTestExpectation(description: "Verify new target")
    runCLI(["list"]) { output, _ in
      let lines = output.components(separatedBy: "\n")
      for line in lines where line.contains("Fan 0:") {
        XCTAssertTrue(line.contains("Target: 5000"), "Target should be 5000")
      }
      verifyExpectation.fulfill()
    }
    wait(for: [verifyExpectation], timeout: 10.0)

    // Cleanup
    runCLI(["auto", "0"]) { _, _ in }
    runCLI(["auto", "1"]) { _, _ in }
  }

  // MARK: - Transition Helper

  /// Poll until fan RPMs stabilize within tolerance (3 consecutive readings within 50 RPM).
  /// Compares mode and RPM values rather than exact string output, since RPM fluctuates
  /// by ~10-20 RPM per reading at steady state.
  private func waitForStateStable(maxPolls: Int = 30, pollInterval: TimeInterval = 0.5) {
    var previousRPMs: [Int] = []
    var previousModes: [String] = []
    var stableCount = 0
    let tolerance = 50

    for _ in 0..<maxPolls {
      Thread.sleep(forTimeInterval: pollInterval)

      let semaphore = DispatchSemaphore(value: 0)
      var currentRPMs: [Int] = []
      var currentModes: [String] = []

      runCLI(["list"]) { output, _ in
        for line in output.components(separatedBy: "\n") {
          if let match = line.range(of: "Fan \\d+: (\\d+) RPM", options: .regularExpression) {
            let rpmStr = String(line[match])
              .replacingOccurrences(of: "Fan ", with: "")
              .components(separatedBy: ":")[1]
              .trimmingCharacters(in: .whitespaces)
              .replacingOccurrences(of: " RPM", with: "")
            currentRPMs.append(Int(rpmStr) ?? 0)
          }
          if line.contains("Mode: Manual") {
            currentModes.append("Manual")
          } else if line.contains("Mode: Auto") {
            currentModes.append("Auto")
          }
        }
        semaphore.signal()
      }
      semaphore.wait()

      let modesMatch = currentModes == previousModes
      let rpmsClose = currentRPMs.count == previousRPMs.count
        && zip(currentRPMs, previousRPMs).allSatisfy { abs($0 - $1) <= tolerance }

      if modesMatch && rpmsClose {
        stableCount += 1
        if stableCount >= 3 {
          return
        }
      } else {
        stableCount = 0
      }

      previousRPMs = currentRPMs
      previousModes = currentModes
    }
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

  private static func log(_ msg: String) {
    fputs("[setUp] \(msg)\n", stderr)
    fflush(stderr)
  }

  private static func resetAllFansToAuto() {
    let path = cliPath
    var fanCount: UInt = 2

    log("resetAllFansToAuto: cliPath=\(path)")
    log("resetAllFansToAuto: calling list...")

    let listProcess = Process()
    let listPipe = Pipe()
    listProcess.executableURL = URL(fileURLWithPath: path)
    listProcess.arguments = ["list"]
    listProcess.standardOutput = listPipe
    listProcess.standardError = listPipe
    try? listProcess.run()
    log("resetAllFansToAuto: waiting for list to exit...")
    listProcess.waitUntilExit()
    log("resetAllFansToAuto: list exited with \(listProcess.terminationStatus)")
    let listData = listPipe.fileHandleForReading.readDataToEndOfFile()
    let listOutput = String(data: listData, encoding: .utf8) ?? ""
    log("resetAllFansToAuto: list output=\(listOutput)")
    if let match = listOutput.range(of: "Fans: (\\d+)", options: .regularExpression) {
      let numStr = listOutput[match].dropFirst(6)
      fanCount = UInt(numStr) ?? 2
    }

    for i in 0..<min(fanCount, 4) {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: path)
      proc.arguments = ["auto", String(i)]
      proc.standardOutput = FileHandle.nullDevice
      proc.standardError = FileHandle.nullDevice
      try? proc.run()
      proc.waitUntilExit()
    }
    Thread.sleep(forTimeInterval: 5.0)
  }

  private static var cliPath: String {
    let fileURL = URL(fileURLWithPath: #filePath)
    let repoRoot = fileURL
      .deletingLastPathComponent()  // IntegrationTests.swift -> IntegrationTests/
      .deletingLastPathComponent()  // IntegrationTests/ -> Tests/
      .deletingLastPathComponent()  // Tests/ -> repo root
    return repoRoot.appendingPathComponent("Products").appendingPathComponent("smcfan").path
  }

  private func runCLISync(_ args: [String]) -> (output: String, exitCode: Int32) {
    let cmdStr = "smcfan \(args.joined(separator: " "))"
    fputs("[sync] \(cmdStr)\n", stderr)
    fflush(stderr)

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: Self.cliPath)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""

      for line in output.components(separatedBy: "\n") where !line.isEmpty {
        fputs("[sync]   \(line)\n", stderr)
      }
      fputs("[sync] exit=\(process.terminationStatus)\n", stderr)
      fflush(stderr)

      return (output, process.terminationStatus)
    } catch {
      fputs("[sync] ERROR: \(error)\n", stderr)
      fflush(stderr)
      return ("Error: \(error)", 1)
    }
  }

  private func runCLI(_ args: [String], completion: @escaping (String, Int32) -> Void) {
    runCLIInternal(args, completion: completion)
  }

  private func runCLISet(_ args: [String], completion: @escaping (String, Int32) -> Void) {
    runCLIWithRetry(args, maxRetries: 3, retryDelay: 2.0, completion: completion)
  }

  private func runCLIWithRetry(
    _ args: [String],
    maxRetries: Int,
    retryDelay: TimeInterval,
    completion: @escaping (String, Int32) -> Void
  ) {
    var attempt = 0

    func tryRun() {
      runCLIInternal(args) { output, exitCode in
        if exitCode == 0 || attempt >= maxRetries {
          completion(output, exitCode)
        } else {
          attempt += 1
          Thread.sleep(forTimeInterval: retryDelay)
          tryRun()
        }
      }
    }
    tryRun()
  }

  private func runCLIInternal(_ args: [String], completion: @escaping (String, Int32) -> Void) {
    let cmdStr = "smcfan \(args.joined(separator: " "))"
    fputs("[cli] \(cmdStr)\n", stderr)
    fflush(stderr)

    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: Self.cliPath)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = pipe
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    do {
      try process.run()
      process.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""

      for line in output.components(separatedBy: "\n") where !line.isEmpty {
        fputs("[cli]   \(line)\n", stderr)
      }
      fputs("[cli] exit=\(process.terminationStatus)\n", stderr)
      fflush(stderr)

      completion(output, process.terminationStatus)
    } catch {
      fputs("[cli] ERROR: \(error)\n", stderr)
      fflush(stderr)
      completion("Error: \(error)", 1)
    }
  }
}
