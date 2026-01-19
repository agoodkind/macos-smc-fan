#include "smc.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>

kern_return_t smc_open(io_connect_t *conn) {
    mach_port_t masterPort;
    io_iterator_t iterator;
    io_object_t device;

    IOMainPort(MACH_PORT_NULL, &masterPort);
    IOServiceGetMatchingServices(masterPort, IOServiceMatching("AppleSMC"), &iterator);
    device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (!device) return kIOReturnNotFound;

    kern_return_t r = IOServiceOpen(device, mach_task_self(), 0, conn);
    
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "smc_open: IOServiceOpen failed: 0x%x (euid=%d)\n", r, geteuid());
        if (r == kIOReturnNotPrivileged) {
             fprintf(stderr, "Error kIOReturnNotPrivileged: Code signing issue or kernel restriction.\n");
        }
    }
    
    IOObjectRelease(device);
    return r;
}

kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t sz = sizeof(SMCKeyData_t);
    kern_return_t r = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sz, out, &sz);
    return r;
}

kern_return_t smc_read_key(io_connect_t conn, const char *key, SMCBytes_t val, uint32_t *size) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = (key[0]<<24)|(key[1]<<16)|(key[2]<<8)|key[3];
    in.data8 = SMC_CMD_READ_KEYINFO;
    
    kern_return_t r = smc_call(conn, &in, &out);
    if (r != kIOReturnSuccess) {
        return r;
    }

    uint32_t dataSize = out.keyInfo.dataSize;
    in.keyInfo.dataSize = dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    memset(&out, 0, sizeof(out));

    r = smc_call(conn, &in, &out);
    if (r == kIOReturnSuccess) {
        memcpy(val, out.bytes, dataSize);
        *size = dataSize;
    }
    return r;
}

kern_return_t smc_write_key(io_connect_t conn, const char *key, const SMCBytes_t val, uint32_t size) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = (key[0]<<24)|(key[1]<<16)|(key[2]<<8)|key[3];
    in.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t r = smc_call(conn, &in, &out);
    if (r != kIOReturnSuccess) return r;

    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, val, size);
    memset(&out, 0, sizeof(out));

    r = smc_call(conn, &in, &out);
    return (out.result == 0) ? r : kIOReturnError;
}

kern_return_t smc_unlock_fan_control(io_connect_t conn, int max_retries, double timeout_seconds) {
    SMCBytes_t val;
    uint32_t size;
    
    // Step 1: Write Ftst=1 to trigger unlock
    val[0] = 1;
    kern_return_t r = smc_write_key(conn, SMC_KEY_FAN_TEST, val, 1);
    if (r != kIOReturnSuccess) {
        return r;
    }
    
    // Step 2: Read current mode to check if already unlocked
    char mode_key[16];
    snprintf(mode_key, sizeof(mode_key), SMC_KEY_FAN_MODE, 0);
    r = smc_read_key(conn, mode_key, val, &size);
    if (r != kIOReturnSuccess) {
        return r;
    }
    
    // Step 3: Retry loop for F0Md=1 write
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    
    for (int retry = 0; retry < max_retries; retry++) {
        val[0] = 1;  // Mode 1 = forced/manual
        r = smc_write_key(conn, mode_key, val, 1);
        
        if (r == kIOReturnSuccess) {
            return kIOReturnSuccess;
        }
        
        // Check timeout
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - start.tv_sec) + 
                       (now.tv_nsec - start.tv_nsec) / 1e9;
        if (elapsed >= timeout_seconds) {
            return kIOReturnTimeout;
        }
        
        usleep(100000);  // 100ms between retries
    }
    
    return kIOReturnTimeout;
}

float bytes_to_float(const SMCBytes_t val, uint32_t size) {
    if (size == 4) {
        float f;
        memcpy(&f, val, 4);
        return f;
    }
    return ((val[0]<<8)|val[1]) / 4.0;
}

void float_to_bytes(float f, SMCBytes_t val, uint32_t size) {
    if (size == 4) {
        memcpy(val, &f, 4);
    } else {
        uint16_t v = (uint16_t)(f*4);
        val[0] = v>>8;
        val[1] = v&0xff;
    }
}