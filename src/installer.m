#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import "smcfan_config.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSString *helperLabel = @HELPER_ID;

        NSLog(@"Installing privileged helper: %@", helperLabel);

        // Get authorization for privileged operations
        AuthorizationRef authRef;
        OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                              kAuthorizationFlagDefaults, &authRef);
        if (status != errAuthorizationSuccess) {
            NSLog(@"AuthorizationCreate failed: %d", status);
            return 1;
        }

        AuthorizationItem authItem = { kSMRightBlessPrivilegedHelper, 0, NULL, 0 };
        AuthorizationRights authRights = { 1, &authItem };
        AuthorizationFlags flags = kAuthorizationFlagDefaults |
                                   kAuthorizationFlagInteractionAllowed |
                                   kAuthorizationFlagPreAuthorize |
                                   kAuthorizationFlagExtendRights;

        status = AuthorizationCopyRights(authRef, &authRights, NULL, flags, NULL);
        if (status != errAuthorizationSuccess) {
            NSLog(@"AuthorizationCopyRights failed: %d", status);
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);
            return 1;
        }

        // Use SMJobBless (SMAppService has issues with plist reading)
        CFErrorRef error = NULL;
        Boolean success = SMJobBless(kSMDomainSystemLaunchd,
                                     (__bridge CFStringRef)helperLabel,
                                     authRef, &error);

        AuthorizationFree(authRef, kAuthorizationFlagDefaults);

        if (!success) {
            NSLog(@"SMJobBless failed: %@", error);
            if (error) CFRelease(error);
            return 1;
        }

        NSLog(@"Helper installed successfully!");
        return 0;
    }
}
