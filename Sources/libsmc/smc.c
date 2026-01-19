// =============================================================================
// SMC Low-Level Interface
//
// This file contains ONLY the functions that require C struct layout guarantees.
// Higher-level logic (connection management, unlock sequences, timing) is in Swift.
//
// See smc.h for detailed explanation of why these must remain in C.
// =============================================================================

#include "smc.h"
#include <string.h>

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