//
//  InstallerApp.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026
//

import AppLog
import Foundation
import Security
import ServiceManagement

private let log = AppLog.make(category: "Installer")

@main
struct SMCFanInstaller {
    static func main() {
        AppLog.bootstrap(subsystem: "io.goodkind.fan")
        BuildInfo.commit = generatedGitCommit
        BuildInfo.version = generatedGitVersion
        BuildInfo.dirty = generatedGitDirty

        let config = SMCFanConfiguration.default
        log.notice("installer.started bundleID=\(config.helperBundleID, privacy: .public)")

        if #available(macOS 13.0, *) {
            let plistName = "\(config.helperBundleID).plist"
            log.info("installer.bundle.path path=\(Bundle.main.bundlePath, privacy: .public)")
            log.info("installer.plist.name name=\(plistName, privacy: .public)")

            let daemonPlistPath =
                Bundle.main.bundlePath + "/Contents/Library/LaunchDaemons/\(plistName)"
            log.info("installer.plist.path path=\(daemonPlistPath, privacy: .public) exists=\(FileManager.default.fileExists(atPath: daemonPlistPath), privacy: .public)")

            let helperPath = Bundle.main.bundlePath + "/Contents/MacOS/\(config.helperBundleID)"
            log.info("installer.helper.path path=\(helperPath, privacy: .public) exists=\(FileManager.default.fileExists(atPath: helperPath), privacy: .public)")

            let service = SMAppService.daemon(plistName: plistName)
            let status = service.status
            log.info("installer.service.status status=\(String(describing: status), privacy: .public)")

            switch status {
            case .enabled:
                log.notice("installer.already.enabled")
                return
            case .notFound:
                log.info("installer.status.notFound attempting=registration")
            case .notRegistered:
                log.info("installer.status.notRegistered action=register")
            case .requiresApproval:
                log.notice("installer.requires.approval action=openSystemSettings")
                SMAppService.openSystemSettingsLoginItems()
                return
            @unknown default:
                log.info("installer.status.unknown attempting=registration")
            }

            do {
                try service.register()
                log.notice("installer.registered")
            } catch {
                log.error("installer.register.failed error=\(error.localizedDescription, privacy: .public)")
                SMAppService.openSystemSettingsLoginItems()
            }

            log.notice("installer.waiting.approval")
            while service.status != .enabled {
                log.debug("installer.status.polling status=\(String(describing: service.status), privacy: .public)")
                sleep(1)
            }

            log.notice("installer.enabled")
            return
        }

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
                    log.error("installer.smjobless.failed error=\(String(describing: err), privacy: .public)")
                }
                exit(1)
            }

            log.notice("installer.smjobless.succeeded")

        } catch {
            log.error("installer.auth.failed error=\(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }
}
