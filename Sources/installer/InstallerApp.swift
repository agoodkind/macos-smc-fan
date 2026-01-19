import Foundation
import Security
import ServiceManagement
import SMCCommon

@main
struct SMCFanInstaller {
    static func main() {
        let config = SMCFanConfiguration.default
        print("Installing privileged helper: \(config.helperBundleID)")
        
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
