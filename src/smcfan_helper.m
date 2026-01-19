#import <Foundation/Foundation.h>
#import "smcfan_common.h"
#import "smcfan_config.h"

@interface SMCFanHelper : NSObject <NSXPCListenerDelegate>

@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic) io_connect_t smcConnection;

@end

@implementation SMCFanHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _listener = [[NSXPCListener alloc] initWithMachServiceName:@HELPER_ID];
        _listener.delegate = self;
        _smcConnection = 0;
    }
    return self;
}

- (void)start {
    [self.listener resume];
    NSLog(@"SMCFanHelper: Service started");

    // Keep the service running
    [[NSRunLoop currentRunLoop] run];
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    // Set up the exported interface
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SMCFanHelperProtocol)];
    newConnection.exportedObject = self;

    // Set up the remote object interface (we don't need to call back to clients)
    newConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(NSObject)];

    newConnection.invalidationHandler = ^{
        NSLog(@"SMCFanHelper: Connection invalidated");
    };

    newConnection.interruptionHandler = ^{
        NSLog(@"SMCFanHelper: Connection interrupted");
    };

    [newConnection resume];
    return YES;
}

#pragma mark - SMC Operations

- (BOOL)ensureSMCConnection:(NSString **)error {
    // Always try to open a fresh connection if current one might be stale
    if (self.smcConnection != 0) {
        // Test the connection with a simple read
        SMCKeyData_t in = {0}, out = {0};
        in.key = 0x464e756d;  // FNum
        in.data8 = SMC_CMD_READ_KEYINFO;
        size_t sz = sizeof(SMCKeyData_t);
        kern_return_t r = IOConnectCallStructMethod(self.smcConnection, KERNEL_INDEX_SMC, 
                                                     &in, sz, &out, &sz);
        if (r == kIOReturnSuccess) {
            return YES;  // Connection is good
        }
        // Connection is stale, close it
        NSLog(@"SMCFanHelper: Connection stale (0x%x), reopening", r);
        IOServiceClose(self.smcConnection);
        self.smcConnection = 0;
    }
    
    // Open new connection
    io_connect_t conn;
    kern_return_t result = smc_open(&conn);
    if (result == kIOReturnSuccess) {
        self.smcConnection = conn;
        return YES;
    } else {
        if (error) {
            *error = [NSString stringWithFormat:@"Failed to open SMC: 0x%x", result];
        }
        return NO;
    }
}

- (void)smcOpenWithReply:(void (^)(BOOL success, NSString *error))reply {
    NSString *error = nil;
    BOOL success = [self ensureSMCConnection:&error];
    reply(success, error);
}

- (void)smcCloseWithReply:(void (^)(BOOL success, NSString *error))reply {
    if (self.smcConnection == 0) {
        reply(YES, nil);
        return;
    }

    IOServiceClose(self.smcConnection);
    self.smcConnection = 0;
    reply(YES, nil);
}

- (void)smcReadKey:(NSString *)key reply:(void (^)(BOOL success, float value, NSString *error))reply {
    NSString *connError = nil;
    if (![self ensureSMCConnection:&connError]) {
        reply(NO, 0, connError);
        return;
    }

    SMCBytes_t val;
    uint32_t size;
    kern_return_t result = smc_read_key(self.smcConnection, [key UTF8String], val, &size);

    if (result == kIOReturnSuccess) {
        float floatValue = bytes_to_float(val, size);
        reply(YES, floatValue, nil);
    } else {
        reply(NO, 0, [NSString stringWithFormat:@"Failed to read key %@: 0x%x", key, result]);
    }
}

- (void)smcWriteKey:(NSString *)key value:(float)value reply:(void (^)(BOOL success, NSString *error))reply {
    NSString *connError = nil;
    if (![self ensureSMCConnection:&connError]) {
        reply(NO, connError);
        return;
    }

    // First read the key to get its size
    SMCBytes_t tempVal;
    uint32_t size;
    kern_return_t result = smc_read_key(self.smcConnection, [key UTF8String], tempVal, &size);

    if (result != kIOReturnSuccess) {
        reply(NO, [NSString stringWithFormat:@"Failed to read key info for %@: 0x%x", key, result]);
        return;
    }

    // Now write the value
    SMCBytes_t writeVal;
    float_to_bytes(value, writeVal, size);
    result = smc_write_key(self.smcConnection, [key UTF8String], writeVal, size);

    if (result == kIOReturnSuccess) {
        reply(YES, nil);
    } else {
        reply(NO, [NSString stringWithFormat:@"Failed to write key %@: 0x%x", key, result]);
    }
}

- (void)smcGetFanCountWithReply:(void (^)(BOOL success, NSUInteger count, NSString *error))reply {
    NSString *connError = nil;
    if (![self ensureSMCConnection:&connError]) {
        reply(NO, 0, connError);
        return;
    }

    // Try reading a safe key first (TC0P - CPU Proximity)
    SMCBytes_t tempVal;
    uint32_t tempSize;
    kern_return_t tempResult = smc_read_key(self.smcConnection, "TC0P", tempVal, &tempSize);
    NSLog(@"Read TC0P result: 0x%x", tempResult);

    SMCBytes_t val;
    uint32_t size;
    kern_return_t result = smc_read_key(self.smcConnection, SMC_KEY_FNUM, val, &size);

    if (result == kIOReturnSuccess) {
        reply(YES, val[0], nil);
    } else {
        NSLog(@"smcGetFanCount failed: 0x%x", result);
        reply(NO, 0, [NSString stringWithFormat:@"Failed to read fan count: 0x%x", result]);
    }
}

- (void)smcGetFanInfo:(NSUInteger)fanIndex reply:(void (^)(BOOL success, NSDictionary *info, NSString *error))reply {
    NSString *connError = nil;
    if (![self ensureSMCConnection:&connError]) {
        reply(NO, nil, connError);
        return;
    }

    NSMutableDictionary *fanInfo = [NSMutableDictionary dictionary];

    // Read actual RPM
    char key[5];
    SMCBytes_t val;
    uint32_t size;
    kern_return_t result;

    snprintf(key, 5, SMC_KEY_FAN_ACTUAL, (int)fanIndex);
    result = smc_read_key(self.smcConnection, key, val, &size);
    if (result == kIOReturnSuccess) {
        fanInfo[@"actualRPM"] = @(bytes_to_float(val, size));
    }

    // Read target RPM
    snprintf(key, 5, SMC_KEY_FAN_TARGET, (int)fanIndex);
    result = smc_read_key(self.smcConnection, key, val, &size);
    if (result == kIOReturnSuccess) {
        fanInfo[@"targetRPM"] = @(bytes_to_float(val, size));
    }

    // Read min RPM
    snprintf(key, 5, SMC_KEY_FAN_MIN, (int)fanIndex);
    result = smc_read_key(self.smcConnection, key, val, &size);
    if (result == kIOReturnSuccess) {
        fanInfo[@"minRPM"] = @(bytes_to_float(val, size));
    }

    // Read max RPM
    snprintf(key, 5, SMC_KEY_FAN_MAX, (int)fanIndex);
    result = smc_read_key(self.smcConnection, key, val, &size);
    if (result == kIOReturnSuccess) {
        fanInfo[@"maxRPM"] = @(bytes_to_float(val, size));
    }

    // Read mode
    snprintf(key, 5, SMC_KEY_FAN_MODE, (int)fanIndex);
    result = smc_read_key(self.smcConnection, key, val, &size);
    if (result == kIOReturnSuccess) {
        fanInfo[@"manualMode"] = @((val[0] == 1) ? YES : NO);
    }

    reply(YES, fanInfo, nil);
}

- (void)smcSetFanRPM:(NSUInteger)fanIndex rpm:(float)rpm reply:(void (^)(BOOL success, NSString *error))reply {
    NSString *connError = nil;
    if (![self ensureSMCConnection:&connError]) {
        reply(NO, connError);
        return;
    }

    char key[5];
    SMCBytes_t val;
    kern_return_t result;

    // Step 1: Unlock fan control (handles thermalmonitord mode 3)
    // This writes Ftst=1 and retries F0Md=1 until it succeeds
    result = smc_unlock_fan_control(self.smcConnection, 100, 10.0);
    if (result != kIOReturnSuccess) {
        reply(NO, [NSString stringWithFormat:@"Failed to unlock fan control: 0x%x", result]);
        return;
    }

    // Step 2: Set target RPM (as float)
    snprintf(key, 5, SMC_KEY_FAN_TARGET, (int)fanIndex);
    memcpy(val, &rpm, sizeof(float));
    result = smc_write_key(self.smcConnection, key, val, 4);
    if (result != kIOReturnSuccess) {
        reply(NO, [NSString stringWithFormat:@"Failed to set target RPM: 0x%x", result]);
        return;
    }

    NSLog(@"SMCFanHelper: Set fan %lu to %.0f RPM", (unsigned long)fanIndex, rpm);
    reply(YES, nil);
}

- (void)smcSetFanAuto:(NSUInteger)fanIndex reply:(void (^)(BOOL success, NSString *error))reply {
    NSString *connError = nil;
    if (![self ensureSMCConnection:&connError]) {
        reply(NO, connError);
        return;
    }

    // NOTE: We keep manual mode (F{n}Md=1) with Ftst=1 and set target to minimum RPM.
    // This lets the fan run at its lowest speed while maintaining control.
    // Setting Ftst=0 would trigger thermalmonitord to take over (mode 3).

    char key[5];
    SMCBytes_t val;
    kern_return_t result;
    uint32_t size;

    // Step 1: Unlock fan control (handles thermalmonitord mode 3)
    result = smc_unlock_fan_control(self.smcConnection, 100, 10.0);
    if (result != kIOReturnSuccess) {
        reply(NO, [NSString stringWithFormat:@"Failed to unlock fan control: 0x%x", result]);
        return;
    }

    // Step 2: Read minimum RPM for this fan
    snprintf(key, 5, SMC_KEY_FAN_MIN, (int)fanIndex);
    result = smc_read_key(self.smcConnection, key, val, &size);
    float minRPM = 2317.0f;  // Default fallback
    if (result == kIOReturnSuccess && size == 4) {
        memcpy(&minRPM, val, 4);
    }

    // Step 3: Set target to minimum RPM
    snprintf(key, 5, SMC_KEY_FAN_TARGET, (int)fanIndex);
    memcpy(val, &minRPM, sizeof(float));
    result = smc_write_key(self.smcConnection, key, val, 4);
    if (result != kIOReturnSuccess) {
        reply(NO, [NSString stringWithFormat:@"Failed to set min RPM: 0x%x", result]);
        return;
    }

    NSLog(@"SMCFanHelper: Set fan %lu to minimum (%.0f RPM)", (unsigned long)fanIndex, minRPM);
    reply(YES, nil);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        SMCFanHelper *helper = [[SMCFanHelper alloc] init];
        [helper start];
    }
    return 0;
}