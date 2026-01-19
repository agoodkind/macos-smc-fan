import Foundation
import Security
import ServiceManagement
#if !canImport_smcfan_config
import SMCCommon  // Import for HELPER_ID
#endif

@main
struct SMCFanInstaller {
    static func main() {
        let config = SMCFanConfiguration.default
        print("Installing privileged helper: \(config.helperBundleID)")
        
        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(
            nil,
            nil,
            [],
            &authRef
        )
        
        guard status == errAuthorizationSuccess, let authRef = authRef else {
            print("AuthorizationCreate failed: \(status)")
            exit(1)
        }
        
        let flags: AuthorizationFlags = [
            .interactionAllowed,
            .preAuthorize,
            .extendRights
        ]
        
        status = kSMRightBlessPrivilegedHelper.withCString { rightPtr in
            var authItem = AuthorizationItem(
                name: rightPtr,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            
            return withUnsafeMutablePointer(to: &authItem) { itemPtr in
                var authRights = AuthorizationRights(
                    count: 1,
                    items: itemPtr
                )
                
                return AuthorizationCopyRights(
                    authRef,
                    &authRights,
                    nil,
                    flags,
                    nil
                )
            }
        }
        
        guard status == errAuthorizationSuccess else {
            print("AuthorizationCopyRights failed: \(status)")
            AuthorizationFree(authRef, [])
            exit(1)
        }
        
        var error: Unmanaged<CFError>?
        let success = SMJobBless(
            kSMDomainSystemLaunchd,
            config.helperBundleID as CFString,
            authRef,
            &error
        )
        
        AuthorizationFree(authRef, [])
        
        guard success else {
            if let error = error?.takeRetainedValue() {
                print("SMJobBless failed: \(error)")
            }
            exit(1)
        }
        
        print("Helper installed successfully!")
    }
}
