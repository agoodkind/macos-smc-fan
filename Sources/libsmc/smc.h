#ifndef SMC_H
#define SMC_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdbool.h>

// SMC IOKit constants
// Selector 2 is used for SMC operations
#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

// SMC data structures
typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyData_keyInfo_t;

typedef unsigned char SMCBytes_t[32];

// CRITICAL: Struct layout must match kernel expectations exactly!
// - keyInfo.dataSize must be at offset 0x1c (28)
// - data8 (command byte) must be at offset 0x2a (42)
typedef struct {
    uint32_t key;                    // 0-3 (4 bytes)
    char vers[4];                    // 4-7 (4 bytes)
    char pLimitData[16];             // 8-23 (16 bytes)
    uint8_t padding0[4];             // 24-27 (padding to align keyInfo)
    SMCKeyData_keyInfo_t keyInfo;    // 28-39 (12 bytes with padding)
    uint8_t result;                  // 40
    uint8_t status;                  // 41
    uint8_t data8;                   // 42 (0x2a) - Command byte
    uint8_t padding1;                // 43
    uint32_t data32;                 // 44-47
    SMCBytes_t bytes;                // 48-79 (32 bytes)
} SMCKeyData_t;  // Total: 80 bytes

// Function declarations
kern_return_t smc_open(io_connect_t *conn);
kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out);
kern_return_t smc_read_key(io_connect_t conn, const char *key, SMCBytes_t val, uint32_t *size);
kern_return_t smc_write_key(io_connect_t conn, const char *key, const SMCBytes_t val, uint32_t size);
kern_return_t smc_unlock_fan_control(io_connect_t conn, int max_retries, double timeout_seconds);
float bytes_to_float(const SMCBytes_t val, uint32_t size);
void float_to_bytes(float f, SMCBytes_t val, uint32_t size);

// Fan-related SMC keys
#define SMC_KEY_FNUM "FNum"  // Number of fans
#define SMC_KEY_FAN_ACTUAL "F%dAc"  // Actual RPM (read-only)
#define SMC_KEY_FAN_TARGET "F%dTg"  // Target RPM
#define SMC_KEY_FAN_MIN "F%dMn"    // Minimum RPM
#define SMC_KEY_FAN_MAX "F%dMx"    // Maximum RPM
#define SMC_KEY_FAN_MODE "F%dMd"   // Mode (0=auto, 1=manual)
#define SMC_KEY_FAN_TEST "Ftst"    // Force/test mode flag (must be 1 for writes)

#endif // SMC_H