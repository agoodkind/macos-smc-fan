#import <Foundation/Foundation.h>
#import "smcfan_common.h"
#import "smcfan_config.h"

void print_usage(const char *program_name) {
    printf("Usage: %s <command> [args...]\n", program_name);
    printf("\nCommands:\n");
    printf("  list              List all fans with current status\n");
    printf("  set <fan> <rpm>   Set fan speed to specified RPM\n");
    printf("  auto <fan>        Return fan to automatic control\n");
    printf("  read <key>        Read value of SMC key\n");
    printf("  help              Show this help message\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            print_usage(argv[0]);
            return 1;
        }

        NSString *command = [NSString stringWithUTF8String:argv[1]];
        
        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:@HELPER_ID options:NSXPCConnectionPrivileged];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SMCFanHelperProtocol)];
        
        [connection resume];
        
        id<SMCFanHelperProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError * _Nonnull error) {
            printf("XPC connection failed: %s\n", [[error description] UTF8String]);
            exit(1);
        }];
        
        // Ensure SMC is open
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block int exitCode = 0;
        
        [proxy smcOpenWithReply:^(BOOL success, NSString *error) {
            if (!success) {
                printf("Failed to open SMC: %s\n", [error UTF8String]);
                exitCode = 1;
                dispatch_semaphore_signal(sema); // Abort
            } else {
                // SMC Open Success - Proceed with command
                if ([command isEqualToString:@"list"]) {
                    [proxy smcGetFanCountWithReply:^(BOOL success, NSUInteger count, NSString *error) {
                        if (!success) {
                            printf("Failed to get fan count: %s\n", [error UTF8String]);
                            exitCode = 1;
                            dispatch_semaphore_signal(sema);
                            return;
                        }
                        
                        printf("Fans: %lu\n", (unsigned long)count);
                        
                        dispatch_group_t group = dispatch_group_create();
                        
                        for (NSUInteger i = 0; i < count; i++) {
                            dispatch_group_enter(group);
                            [proxy smcGetFanInfo:i reply:^(BOOL success, NSDictionary *info, NSString *error) {
                                if (success) {
                                    printf("Fan %lu: %.0f RPM (Target: %.0f, Min: %.0f, Max: %.0f, Mode: %s)\n",
                                           (unsigned long)i,
                                           [info[@"actualRPM"] floatValue],
                                           [info[@"targetRPM"] floatValue],
                                           [info[@"minRPM"] floatValue],
                                           [info[@"maxRPM"] floatValue],
                                           [info[@"manualMode"] boolValue] ? "Manual" : "Auto");
                                } else {
                                    printf("Fan %lu: Error reading info\n", (unsigned long)i);
                                }
                                dispatch_group_leave(group);
                            }];
                        }
                        
                        dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            dispatch_semaphore_signal(sema);
                        });
                    }];
                } else if ([command isEqualToString:@"set"]) {
                    if (argc < 4) {
                        printf("Usage: smcfan set <fan> <rpm>\n");
                        exitCode = 1;
                        dispatch_semaphore_signal(sema);
                    } else {
                        int fan = atoi(argv[2]);
                        float rpm = atof(argv[3]);
                        
                        [proxy smcSetFanRPM:fan rpm:rpm reply:^(BOOL success, NSString *error) {
                            if (success) {
                                printf("Set fan %d to %.0f RPM\n", fan, rpm);
                            } else {
                                printf("Failed to set speed: %s\n", [error UTF8String]);
                                exitCode = 1;
                            }
                            dispatch_semaphore_signal(sema);
                        }];
                    }
                } else if ([command isEqualToString:@"auto"]) {
                    if (argc < 3) {
                        printf("Usage: smcfan auto <fan>\n");
                        exitCode = 1;
                        dispatch_semaphore_signal(sema);
                    } else {
                        int fan = atoi(argv[2]);
                        [proxy smcSetFanAuto:fan reply:^(BOOL success, NSString *error) {
                            if (success) {
                                printf("Set fan %d to auto mode\n", fan);
                            } else {
                                printf("Failed to set auto mode: %s\n", [error UTF8String]);
                                exitCode = 1;
                            }
                            dispatch_semaphore_signal(sema);
                        }];
                    }
                } else if ([command isEqualToString:@"read"]) {
                    if (argc < 3) {
                        printf("Usage: smcfan read <key>\n");
                        exitCode = 1;
                        dispatch_semaphore_signal(sema);
                    } else {
                        NSString *key = [NSString stringWithUTF8String:argv[2]];
                        [proxy smcReadKey:key reply:^(BOOL success, float value, NSString *error) {
                            if (success) {
                                printf("%s = %.2f\n", [key UTF8String], value);
                            } else {
                                printf("Failed to read key: %s\n", [error UTF8String]);
                                exitCode = 1;
                            }
                            dispatch_semaphore_signal(sema);
                        }];
                    }
                } else {
                    print_usage(argv[0]);
                    exitCode = 1;
                    dispatch_semaphore_signal(sema);
                }
            }
        }];
        
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        [connection invalidate];
        return exitCode;
    }
}