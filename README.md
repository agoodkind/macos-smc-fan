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

The research combined multiple approaches to understand Apple Silicon's fan control mechanism:

**System-Level Analysis:**
- Monitored `IOKit` calls to `AppleSMC` service using dtrace and system tracing
- Examined `thermalmonitord` behavior through console logs and process monitoring
- Observed that `F0Md` writes failed with `0x82` (`kSMCBadCommand`) when in mode 3
- Tested various SMC key combinations and timing patterns

**Binary Analysis:**
- Used IDA Pro to examine compiled binaries with fan control capabilities
- Discovered SMC keys are often XOR-encoded in binaries (decoded at runtime for anti-tampering)
- Identified the `Ftst` (Force Test) flag as a critical unlock mechanism
- Found retry patterns in SMC write operations

**Experimental Testing:**
Through systematic testing on M3 MacBook Pro hardware:
- `Ftst=1` write always succeeds, even in mode 3
- Subsequent `F0Md=1` retries eventually succeed after ~3-6 seconds
- `thermalmonitord` temporarily yields when `Ftst` is active
- Once unlocked, fan control remains available until `Ftst=0` or daemon restart

### Implementation

The project is implemented in **Swift** with a C library for low-level SMC operations. The Swift code handles `XPC` communication and privilege escalation, while the C layer directly interfaces with `IOKit` for hardware access.

On Apple Silicon Macs, fan control requires working around macOS's thermal management system. The SMC (System Management Controller) accepts fan speed commands, but only when the system is not in "protected" mode.

### The Challenge

When macOS's `thermalmonitord` actively controls fans, it sets the fan mode to 3. In this state, direct writes to change the fan mode fail with SMC error `0x82` (`kSMCBadCommand`) - the SMC firmware itself rejects the command.

### Implementation Details

The unlock mechanism is implemented in `smc_unlock_fan_control()`:

1. Write `Ftst=1` to trigger unlock
2. Enter retry loop (100ms intervals, 10 second timeout)
3. Attempt `F0Md=1` write repeatedly
4. On success, mode transitions from 3 → 1 (manual control enabled)
5. Fan speed can now be set via `F0Tg` (target RPM)

### Key Findings

**System Behavior:**

- Setting `Ftst=0` returns control to `thermalmonitord`
- Auto mode sets target to minimum RPM while keeping manual control active
- Fan speeds are clamped to SMC-reported min/max values

**Modern Hardware Constraints (M3/M4):**

- Fans cannot be controlled independently - both fans tend to synchronize to similar speeds despite having separate `F0Tg`/`F1Tg` keys
- Firmware appears to enforce coupled fan behavior

**Security Requirements:**

- **No SIP disable required** - Works with System Integrity Protection enabled
- Only requires `com.apple.security.cs.disable-library-validation` entitlement
- Standard code signing with Developer ID certificate

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

Apple Silicon uses IEEE 754 float (4 bytes, little-endian) for RPM values.

### IOKit Communication

- Service: `AppleSMC`
- Connection type: `0`
- Selector: `2`
- Struct size: `80 bytes`

Commands:

- `9` - Read key info
- `5` - Read value
- `6` - Write value

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
