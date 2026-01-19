#ifndef SMC_H
#define SMC_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdbool.h>

// =============================================================================
// WHY THIS CODE IS IN C (NOT SWIFT):
//
// The SMC kernel interface requires IOConnectCallStructMethod with a struct
// whose memory layout EXACTLY matches what AppleSMC.kext expects. Swift's
// automatic struct padding differs from C's - specifically:
//
//   - C's SMCKeyData_keyInfo_t is 12 bytes (with 3 bytes padding after dataAttributes)
//   - Swift's equivalent is 9 bytes (size) with 12-byte stride, but nested structs
//     use size, not stride, causing a 3-byte offset error
//   - This places data8 (command byte) at offset 39 in Swift vs 42 in C
//   - Wrong offsets = kernel ignores commands or returns garbage
//
// The struct layout was reverse-engineered from AppleSMC and must remain stable.
// Maintaining explicit padding bytes in Swift would be error-prone and less clear
// than the C version with offset comments.
//
// Swift handles: XPC protocol, data format conversion, high-level orchestration
// C handles: Kernel ABI struct packing, IOConnectCallStructMethod calls
// =============================================================================

// SMC IOKit constants
#define KERNEL_INDEX_SMC 2          // Selector for SMC operations
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

// SMC data structures - offsets verified against AppleSMC.kext
typedef struct {
    uint32_t dataSize;              // 0-3
    uint32_t dataType;              // 4-7
    uint8_t dataAttributes;         // 8 (+ 3 bytes implicit padding = 12 total)
} SMCKeyData_keyInfo_t;

typedef unsigned char SMCBytes_t[32];

// CRITICAL: Struct layout must match kernel expectations exactly!
// Verified offsets: keyInfo.dataSize=0x1c (28), data8=0x2a (42)
typedef struct {
    uint32_t key;                    // 0-3 (4 bytes)
    char vers[4];                    // 4-7 (4 bytes)
    char pLimitData[16];             // 8-23 (16 bytes)
    uint8_t padding0[4];             // 24-27 (align keyInfo to offset 28)
    SMCKeyData_keyInfo_t keyInfo;    // 28-39 (12 bytes with implicit padding)
    uint8_t result;                  // 40
    uint8_t status;                  // 41
    uint8_t data8;                   // 42 (0x2a) - Command byte
    uint8_t padding1;                // 43
    uint32_t data32;                 // 44-47
    SMCBytes_t bytes;                // 48-79 (32 bytes)
} SMCKeyData_t;  // Total: 80 bytes

// -----------------------------------------------------------------------------
// Core SMC functions - must remain in C due to struct layout requirements
// -----------------------------------------------------------------------------

// Wrapper for IOConnectCallStructMethod with correct struct size
kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out);

// Read SMC key - builds SMCKeyData_t with correct padding
kern_return_t smc_read_key(io_connect_t conn, const char *key, SMCBytes_t val, uint32_t *size);

// Write SMC key - builds SMCKeyData_t with correct padding  
kern_return_t smc_write_key(io_connect_t conn, const char *key, const SMCBytes_t val, uint32_t size);

// -----------------------------------------------------------------------------
// Fan-related SMC keys (string constants, usable from Swift via bridging)
// -----------------------------------------------------------------------------
#define SMC_KEY_FNUM "FNum"  // Number of fans
#define SMC_KEY_FAN_ACTUAL "F%dAc"  // Actual RPM (read-only)
#define SMC_KEY_FAN_TARGET "F%dTg"  // Target RPM
#define SMC_KEY_FAN_MIN "F%dMn"    // Minimum RPM
#define SMC_KEY_FAN_MAX "F%dMx"    // Maximum RPM
#define SMC_KEY_FAN_MODE "F%dMd"   // Mode (0=auto, 1=manual)
#define SMC_KEY_FAN_TEST "Ftst"    // Force/test mode flag (must be 1 for writes)

#endif // SMC_H