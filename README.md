# SMC Fan Control Research for Apple Silicon

[![Swift](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml/badge.svg)](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml)

## Motivation

Prior to this research, **no public documentation existed** for controlling fan speeds on modern Apple Silicon Macs (M1-M4). While commercial tools existed, the underlying mechanism—particularly how to bypass macOS's thermal management system (`thermalmonitord`)—remained undocumented.

This project documents the **reverse engineering process**, the discovered **unlock mechanism**, and provides a working implementation. The research reveals how `thermalmonitord` enforces "protected mode" and the specific SMC key sequence required to regain manual control.

Beyond fan control, this work demonstrates **SMC research methodologies** that could expose other controllable system parameters.

## ⚠️ Warning

**For educational and research purposes only.** This software:

- Can cause **hardware damage** if fans are set incorrectly
- May interfere with macOS thermal management
- Is provided **without any warranty**
- Is **not affiliated with or endorsed by Apple Inc.**

**Use entirely at your own risk.** Monitor system temperatures carefully. Not intended for production use.

## Background

### Evolution of macOS SMC-based Fan Control

The transition from Intel to Apple Silicon moved fan management from a discrete chip to a component integrated directly into the SoC. System management logic shifted from the H8/SMC controller to the Always-On (AOP) subsystem.

#### Intel Architecture

Standard Intel Macs used a dedicated System Management Controller chip. These controllers used simple integer or hexadecimal values for RPM. Writing to the `F0Tg` (Fan 0 Target) key was direct. The OS did not block manual overrides.

#### T2 Security Chip

The T2 chip acted as a bridge. It moved SMC functions to a secure enclave. This added a layer of abstraction between `IOKit` and the physical fan controller. Control remained relatively open but required more complex SMC key sequences.

#### M1 and M2 Generation

The SMC is now a firmware-level service within the M-series chip. Apple changed the data type for RPM keys to 4-byte IEEE 754 floating-point values. The `Ftst` (Force Test) key became a mandatory toggle. The system began enforcing "System Mode" (mode 3) through `thermalmonitord`. Manual control requires a specific race condition or timing window where the system releases the lock.

#### M3 and M4 (Current)

Hardware and firmware locks are tighter on these models. macOS Sequoia introduced changes that prevent manual mode switching on certain Pro and Max variants. The firmware rejects writes to `F0Md` more aggressively. Higher precision sensors and more aggressive efficiency core (E-core) offloading mean fans stay at 0 RPM longer. Modern fan control requires the helper daemon to maintain a persistent connection to prevent `thermalmonitord` from reclaiming the mode.

#### M5+

Untested

## Research Findings

### Discovery Process

Prior work on Intel-based Macs established the basic SMC key schema: `F0Md` for fan mode, `F0Tg` for target RPM, and `Ftst` for force/test state. These keys were accessible via standard `IOKit` calls on Intel hardware but failed on Apple Silicon.

Initial attempts to write `F0Md` on M4 hardware returned `0xe00002c2` (`kIOReturnNotPrivileged`). Investigation focused on entitlements and code signing, testing various permission combinations. This proved to be a dead end: only `com.apple.security.cs.disable-library-validation` was needed.

System-level tracing using `dtrace` on `thermalmonitord` and `AppleSMC` kernel extension revealed the actual blocker. Reading `F0Md` returned `3` (system mode). Writes to change it failed with `0x82` (`kSMCBadCommand`), a firmware-level rejection. The `thermalmonitord` daemon enforced mode 3, preventing direct mode changes.

Binary analysis with IDA Pro decompiled `thermalmonitord` and `AppleSMC`, producing tens of thousands of lines of pseudocode. LLMs were employed to analyze this output, searching for patterns in SMC write operations and cross-referencing `Ftst` flag usage. This automated analysis identified `Ftst` as a trigger for thermal management state changes.

Experimental testing confirmed `Ftst=1` writes succeeded unconditionally, even in mode 3. Timed observation of mode state revealed the unlock pattern:

- Write `Ftst=1` (returns success)
- Monitor `F0Md` value (initially reads `3`)
- After 3-4 seconds, `F0Md` transitions to `0`
- Retry `F0Md=1` write (typically succeeds within 4-6 seconds)
- Manual control enabled

The mechanism is timing-based. `thermalmonitord` monitors `Ftst` state and temporarily yields control. The unlock is implemented in `smc_unlock_fan_control()` with 100ms retry intervals and a 10 second timeout. SIP remains enabled.

### Implementation

The project is implemented in **Swift** with a C library for low-level SMC operations. The Swift code handles `XPC` communication and privilege escalation, while the C layer directly interfaces with `IOKit` for hardware access.

### Key Findings

**System Behavior:**

- Setting `Ftst=0` returns control to `thermalmonitord`
- Auto mode sets target to minimum RPM while keeping manual control active
- Fan speeds are clamped to SMC-reported min/max values (typical M4 Max: ~2300-7800 RPM)
- IOKit connection types (0-4) behave identically for SMC access
- `thermalmonitord` uses private entitlements (`com.apple.private.applesmc.user-access`, `com.apple.private.smcsensor.user-access`) via `AppleSMCSensorDispatcher`, but the `Ftst` unlock mechanism bypasses this path entirely

**Modern Hardware Constraints (M3/M4):**

- Fans cannot be controlled independently—both fans synchronize to similar speeds despite separate `F0Tg`/`F1Tg` keys
- Firmware enforces coupled fan behavior

## Technical Details

### SMC Keys

| Key | Type | Description |
| --- | --- | --- |
| `FNum` | uint8 | Number of fans |
| `F%dAc` | float | Actual RPM (read-only) |
| `F%dTg` | float | Target RPM |
| `F%dMn` | float | Minimum RPM |
| `F%dMx` | float | Maximum RPM |
| `F%dMd` | uint8 | Mode (0=auto, 1=manual, 3=system) |
| `Ftst` | uint8 | Force/test flag |

**Data Formats:**

- **Intel Macs**: 2-byte `fpe2` fixed-point (14.2 format, big-endian). The top 14 bits are integer, bottom 2 bits are fractional (divide raw value by 4).
- **Apple Silicon**: 4-byte IEEE 754 float (little-endian)

Cross-platform code must detect and handle both formats. See [Apple SMC](https://cbosoft.github.io/blog/2020/07/17/apple-smc/) and [Asahi Linux SMC Documentation](https://asahilinux.org/docs/hw/soc/smc/) for format details.

### IOKit Communication

- Service: `AppleSMC`
- Connection type: `0`
- Selector: `2`
- Struct size: `80 bytes`

Commands:

- `9` - Read key info
- `5` - Read value
- `6` - Write value

### Fan Modes

The `F%dMd` key controls fan behavior:

| Mode | Name | Description |
| --- | --- | --- |
| `0` | Auto | System manages fans, target defaults to minimum RPM |
| `1` | Manual | User controls target RPM via `F%dTg` |
| `3` | System | `thermalmonitord` has exclusive control, firmware rejects `F0Md` writes |

Mode 3 is the default on Apple Silicon when the system is managing thermals. The unlock sequence transitions the system from mode 3 → 0, then allows setting mode 1.

### thermalmonitord

`thermalmonitord` (macOS: `/usr/libexec/thermald`) is a userspace daemon responsible for thermal management across Apple platforms (macOS, iOS, iPadOS). It:

- Monitors CPU, GPU, battery, and sensor temperatures
- Adjusts fan speeds and performance based on thermal policy
- Enforces mode 3 on Apple Silicon, blocking direct SMC writes to `F0Md`
- Communicates with SMC via `AppleSMCSensorDispatcher` using private entitlements
- Publishes thermal state to apps via `NSProcessInfo.thermalState`

**Firmware Fallback:** If `thermalmonitord` is killed or unresponsive, hardware-level thermal protection remains active. The kernel and SMC firmware independently enforce temperature limits, throttle performance, run fans at maximum, and trigger emergency shutdown if thresholds are exceeded. Killing the daemon removes graceful thermal management but does not disable hardware protection—the system will panic or force shutdown if the watchdog timer expires (~180 seconds without check-in).

The daemon runs continuously and reclaims control (reverts to mode 3) when `Ftst` is set back to `0`. The helper daemon must maintain an active connection to preserve manual control.

**References:**

- [Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html) (Apple Developer)
- [kIOPMThermalWarningNotificationKey](https://developer.apple.com/documentation/iokit/kiopmthermalwarningnotificationkey) (IOKit Documentation)
- [Apple Platform Security - Boot Modes](https://support.apple.com/guide/security/sec10869885b) (Apple Support)

### Error Codes

**IOKit Errors:**

| Code | Name | Description |
| --- | --- | --- |
| `0xe00002c2` | `kIOReturnNotPrivileged` | Insufficient permissions (check code signing/entitlements) |

**SMC Errors (returned in `result` field):**

| Code | Name | Description |
| --- | --- | --- |
| `0x00` | Success | Operation completed |
| `0x82` | `kSMCBadCommand` | Firmware rejects write (mode 3 blocking) |
| `0x84` | `kSMCNotWritable` | Key is read-only |
| `0x85` | `kSMCNotReadable` | Key is write-only |
| `0x86` | `kSMCKeyNotFound` | Key does not exist |
| `0x87` | `kSMCBadFuncParameter` | Invalid parameter (may still apply value) |

Note: `0x87` errors on `F0Tg` writes sometimes succeed—the value is applied despite the error response.

### Data Structure

```c
typedef struct {
    uint32_t key;                    // 0-3
    char vers[4];                    // 4-7
    char pLimitData[16];             // 8-23
    uint8_t padding0[4];             // 24-27
    SMCKeyData_keyInfo_t keyInfo;    // 28-39 (dataSize at offset 28)
    uint8_t result;                  // 40
    uint8_t status;                  // 41
    uint8_t data8;                   // 42 (command byte)
    uint8_t padding1;                // 43
    uint32_t data32;                 // 44-47
    SMCBytes_t bytes;                // 48-79
} SMCKeyData_t;  // Total: 80 bytes
```

**Critical:** Field alignment must be exact. `keyInfo.dataSize` at offset 28, `data8` at offset 42.

## Future Research Directions

The methodologies used here could reveal other SMC-controllable parameters:

- **Power Management** - CPU/GPU power limits, TDP controls
- **Thermal Sensors** - Access to temperature sensors beyond standard APIs
- **Performance States** - Direct control over P-states, frequency scaling
- **Battery Management** - Charge limits, health parameters
- **System Telemetry** - Undocumented sensor data

The SMC contains hundreds of keys. This research provides the framework to explore them.

## Quick Start

### Prerequisites

- Xcode Command Line Tools: `xcode-select --install`
- **Paid Apple Developer account** - Required for Developer ID certificate
- Valid Apple Developer ID certificate for code signing
- Your Apple Team ID (find at <https://developer.apple.com/account>)

### Configuration

Copy the example config and customize with your credentials:

```bash
cp config.mk.example config.mk
# Edit config.mk with your values:
#   CERT_ID - Your Developer ID certificate (find with: security find-identity -v -p codesigning)
#   TEAM_ID - Your Apple Team ID
#   BUNDLE_ID_PREFIX - Your bundle identifier prefix (e.g., com.yourname)
```

### Build

Production build (with code signing):

```bash
make all
```

Development build (IDE/testing):

```bash
HELPER_BUNDLE_ID=io.goodkind.smcfanhelper swift build
```

### Install

```bash
./Products/SMCFanHelper.app/Contents/MacOS/SMCFanInstaller
# Enter password when prompted
```

The installer uses `SMJobBless` to install a privileged helper daemon.

### Usage

```bash
# List fans
./Products/smcfan list

# Set fan speed
./Products/smcfan set 0 4500    # Set fan 0 to 4500 RPM

# Set to minimum (auto-like)
./Products/smcfan auto 0        # Set fan 0 to minimum RPM
```

### Uninstall

Replace `YOUR_BUNDLE_ID` with your configured bundle identifier prefix:

```bash
sudo launchctl unload /Library/LaunchDaemons/YOUR_BUNDLE_ID.smcfanhelper.plist
sudo rm /Library/PrivilegedHelperTools/YOUR_BUNDLE_ID.smcfanhelper
sudo rm /Library/LaunchDaemons/YOUR_BUNDLE_ID.smcfanhelper.plist
```

## Project Structure

### Runtime Architecture

```text
smcfan (CLI)
  │
  │ XPC
  └──→ SMCFanHelper (privileged daemon)
        │
        │ IOKit
        └──→ AppleSMC (kernel driver)
              │
              └──→ SMC firmware
```

### Development with Xcode

Open as a Swift Package for full IDE support:

```bash
xed .
```

Provides autocomplete, jump-to-definition, debugging, and refactoring tools.

### Directory Layout

```text
smc-fan/
├── Sources/               Source code
│   ├── smcfan/           CLI tool
│   │   └── main.swift
│   ├── smcfanhelper/     XPC helper daemon
│   │   └── main.swift
│   ├── installer/        `SMJobBless` installer
│   │   └── main.swift
│   ├── common/           Shared Swift code
│   │   ├── SMCProtocol.swift
│   │   └── Config.swift
│   └── libsmc/           Low-level C library
│       ├── smc.c         SMC hardware interface
│       └── smc.h
├── Include/              Public headers
│   └── SMCFan-Bridging-Header.h
├── templates/            Template files
│   ├── Info.plist
│   ├── helper-info.plist.template
│   ├── helper-launchd.plist.template
│   └── smcfan_config.h.template
├── generated/            Auto-generated (gitignored)
├── Products/             Final binaries (gitignored)
├── config.mk.example     Template for credentials
├── config.mk             Your credentials (gitignored)
├── entitlements.plist    Code signing entitlements
└── Makefile              Build system
```

## License

Educational and research use only. See warning above.
