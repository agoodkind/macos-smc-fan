//
//  InstallerApp.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import Foundation
import SMCCommon
import Security
import ServiceManagement

@main
struct SMCFanInstaller {
  static func main() {
    let config = SMCFanConfiguration.default
    print("Installing privileged helper: \(config.helperBundleID)")

    if #available(macOS 13.0, *) {
      do {
        let plistName = "\(config.helperBundleID).plist"
        print("Bundle path: \(Bundle.main.bundlePath)")
        print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
        print("Looking for plist: \(plistName)")
        let daemonPlistPath = Bundle.main.bundlePath +
          "/Contents/Library/LaunchDaemons/\(plistName)"
        print("Expected path: \(daemonPlistPath)")
        print("File exists: \(FileManager.default.fileExists(atPath: daemonPlistPath))")
        let helperPath = Bundle.main.bundlePath +
          "/Contents/MacOS/\(config.helperBundleID)"
        print("Helper path: \(helperPath)")
        print("Helper exists: \(FileManager.default.fileExists(atPath: helperPath))")
        
        let service = SMAppService.daemon(plistName: plistName)
        let status = service.status
        print("Current status: \(status)")
        
        switch status {
        case .enabled:
          print("Helper already installed and running.")
          return
        case .notFound:
          print("Status notFound, attempting registration anyway...")
        case .notRegistered:
          print("Registering daemon...")
        case .requiresApproval:
          print("Opening System Settings for approval...")
          SMAppService.openSystemSettingsLoginItems()
          print("Please enable SMCFanHelper in Login Items, then run again.")
          exit(0)
        @unknown default:
          print("Unknown status, attempting registration...")
        }
        
        do {
          try service.register()
        } catch {
          print("Registration error: \(error.localizedDescription)")
          print("Opening System Settings for manual approval...")
          SMAppService.openSystemSettingsLoginItems()
        }
        
        print("Waiting for approval... Please enable SMCFanHelper in System Settings.")
        while service.status != .enabled {
          print("Current status: \(service.status). Waiting...")
          sleep(1)
        }
        
        print("Helper installed and enabled!")
      } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
      }
      return
    }

    // Fallback for macOS < 13
    do {
      let authRef = try Authorization.requestInstallRights()
      defer { AuthorizationFree(authRef, []) }

      var error: Unmanaged<CFError>?
      let success = SMJobBless(
        kSMDomainSystemLaunchd,
        config.helperBundleID as CFString,
        authRef,
        &error
      )

      guard success else {
        if let err = error?.takeRetainedValue() {
          print("SMJobBless failed: \(err)")
        }
        exit(1)
      }

      print("Helper installed successfully!")

    } catch {
      print("Error: \(error.localizedDescription)")
      exit(1)
    }
  }
}
