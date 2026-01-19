# SMC Fan Control Research for Apple Silicon

[![Swift](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml/badge.svg)](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml)

## Motivation

Prior to this research, no public documentation existed for manual fan **control** or persistent writes (e.g., manipulating fan speed) on Apple Silicon. While **reading** sensor data was documented [^6][^9], as far as I can tell, nobody had documented how to bypass the `thermalmonitord` lock to override system policy.

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

### Key Terms

- **SMC (System Management Controller)**: A microcontroller (Legacy/T2) or integrated firmware component (Apple Silicon) that manages low-level hardware: thermal sensors, fan speeds, power states, and other system functions [^7]. On legacy hardware, it's discrete; on Apple Silicon, it's part of the SoC.
- **SoC (System-on-Chip)**: Apple Silicon (M1-M5+) integrates CPU, GPU, Neural Engine, memory controllers, and management components into a single chip, unlike earlier Macs which had separate components. See Apple's documentation on boot security for more on SoC architecture [^3].
- **RTKit**: Apple's embedded firmware backend that manages the integrated SMC on Apple Silicon [^6], replacing the older ACPI-based interface used previously.
- **Daemon**: A background system process (e.g., `thermalmonitord`) that runs with elevated privileges and coordinates system behavior. It monitors thermal pressure [^1] and publishes state changes [^2].
- **IOKit**: Apple's macOS kernel framework for hardware communication and device access [^2].

### Evolution of macOS SMC-based Fan Control

The transition to Apple Silicon moved fan management from a discrete chip to a component integrated directly into the SoC [^3]. System management logic shifted from the H8/SMC controller to the Always-On (AOP) subsystem.

#### Legacy Architecture

Standard Macs used a dedicated System Management Controller chip [^7][^9]. Writing to fan control keys like `F0Tg` (Fan 0 Target) was direct and the OS didn't block manual overrides. Thermal management was automatic: the SMC read temperature sensors and adjusted fan speed.

#### T2 Security Chip

The T2 chip added a security layer. SMC functions moved into this separate processor [^3], adding abstraction between the OS and hardware. Manual fan control still worked but required different SMC key sequences.

#### M1 and M2 Generation

With Apple Silicon, Apple integrated SMC functionality into the main chip itself [^6]. Investigation revealed a fundamental architectural shift: instead of the SMC independently managing fans, a background system process called `thermalmonitord` [^10][^11] now coordinates thermal policy. Runtime tracing and decompiled code analysis confirmed this process actively prevents direct fan control by enforcing a locked state that blocks manual mode changes.

**Key Changes from Legacy:**

- Active daemon-based thermal management replaces passive SMC automation
- Fan mode writes are blocked by default ("system mode")
- SMC operations moved to firmware layer
- Discovery of diagnostic unlock mechanism that temporarily disables daemon enforcement

Experimental testing identified a diagnostic flag (`Ftst`) that temporarily disables daemon enforcement. Decompiled code analysis confirms this mechanism is consistent across M1-M4 generations. Manual control can be maintained with an active privileged process.

Note: A separate process called `thermald` also runs on these Macs. Analysis of its imports shows it monitors power/thermal metrics and publishes **thermal pressure levels** (nominal/fair/serious/critical) via system notifications for apps to react to [^1]. It does not directly control fans (that's `thermalmonitord`'s role). It appears that they are complementary: `thermald` reports, `thermalmonitord` acts.

#### M3 and M4 Generation

Thermal management became significantly more restrictive on these models through both firmware and hardware-level changes.

**Additional Restrictions:**

- **Enhanced Thermal Controller**: Decompiled code analysis reveals a new thermal management component with faster response times (250ms polling under load vs 4000ms idle), resulting in more aggressive daemon reclaim behavior
- **Synchronized Fan Behavior**: Experimental observation on M4 hardware shows both fans track similar speeds; independent control is limited
- **More Aggressive Enforcement**: Faster polling makes manual override more challenging to maintain under thermal load

The diagnostic unlock mechanism continues to function for mode transitions. See [Known Limitations](#known-limitations) for technical details.

#### M5+

The unlock mechanism and fan control behavior have not been tested on M5 chips. While the same SMC key schema and `thermalmonitord` architecture are expected to be present, verification is needed to confirm compatibility.

## Research Findings

### SMC Keys

Prior research [^7][^8][^9] found the following keys, which were verified for Apple Silicon through `dtrace` tracing of `thermalmonitord` and `AppleSMC` kernel extensions, complemented by IDA Pro binary analysis.

| Key | Type | Description |
| --- | --- | --- |
| `FNum` | `uint8` | Number of fans |
| `F%dAc` | `float` | Actual RPM (read-only) |
| `F%dTg` | `float` | Target RPM |
| `F%dMn` | `float` | Minimum RPM |
| `F%dMx` | `float` | Maximum RPM |
| `F%dMd` | `uint8` | Mode (0=auto, 1=manual, 3=system) |
| `Ftst` | `uint8` | Force/test flag |

**Data Formats:**

- **Legacy (FPE2) Format**: 2-byte `fpe2` fixed-point (14.2 format, big-endian). The top 14 bits are integer, bottom 2 bits are fractional (divide raw value by 4) [^5].
- **Apple Silicon**: 4-byte IEEE 754 float (little-endian) [^6].

Cross-platform code must detect and handle both formats [^5][^6]. See [Architecture & Research Insights](#architecture--research-insights) for more on how these keys are managed on Apple Silicon.

### Fan Modes

The values for the `F%dMd` mode key were identified by monitoring system state transitions during experimental testing and analyzing the decompiled `thermalmonitord` logic.

| Mode | Name | Description |
| --- | --- | --- |
| `0` | Auto | System manages fans, target defaults to minimum RPM |
| `1` | Manual | User controls target RPM via `F%dTg` |
| `2` | ? | Legacy (T2): Forced manual mode; not observed on Apple Silicon |
| `3` | System | Active mitigation state (`AppleCLPC`); firmware rejects manual mode changes |

Mode 3 is the default on Apple Silicon when `thermalmonitord` is managing system thermals. The unlock sequence transitions the system from mode 3 → 0, then allows setting mode 1.

### Architecture & Research Insights

Through disassembly of `thermalmonitord` and `AppleSMC.kext`, several key architectural details were identified:

1. **`RTKit` Abstraction**: On Apple Silicon, SMC keys like `F0Md` and `Ftst` are not hardcoded in userspace binaries. They are managed by the **`RTKit` firmware** embedded within the SoC [^6]. The `AppleSMC` kernel driver acts as a transparent bridge to this firmware.
2. **Property-Based Control**: `thermalmonitord` does not write to SMC keys directly. Instead, it uses high-level Objective-C properties (via `IORegistryEntrySetCFProperty`) to communicate with hardware controllers like **`AppleCLPC`** (Closed Loop Power Controller) and **ApplePMGR** (Power Manager). It sets "ceilings" and "mitigations" rather than raw RPMs.
3. **Mode 3 is a State, not a Command**: "System Mode" (`mode 3`) is not a command sent by the daemon. Rather, it is the state *reported* by the `RTKit` firmware when hardware controllers like `AppleCLPC` are in an active mitigation state. This explains why `thermalmonitord` does not need to "set" mode 3—its very operation causes the hardware to enter and report that state.
4. **`Ftst` Unlock Mechanism**: Decompiled code analysis of `thermalmonitord` reveals the `Ftst=1` write inhibits the `LifetimeServoController` component from asserting thermal targets. Specifically, when `Ftst` is set, the controller's reclaim logic is suppressed, preventing it from sending die temperature targets to `AppleCLPC`. This allows manual fan mode to persist. The daemon's polling loop continues checking sensors but does not override fan settings while in this diagnostic state.
5. **Model Detection**: The decompiled code includes board ID to configuration mapping that determines which thermal controller to use. M3/M4 models are identified by the `updateCPUFastDieTargetPMP` configuration flag, which enables `AppleDieTempController` instead of `AppleCLPC`. This allows implementations to programmatically detect hardware generation and adjust behavior accordingly.
6. **Mode 2 (Legacy)**: While value `2` appears in older SMC tools (like `smcFanControl` [^8]) or community databases [^7] as a "manual override" or "forced" mode for T2-equipped Macs, no references to it were found in the Apple Silicon `thermalmonitord` or driver logic.

### Discovery Process

Prior work established the basic SMC key schema from the Linux kernel `applesmc` driver [^9]: `F0Md` for fan mode, `F0Tg` for target RPM, and `Ftst` for force/test state [^7][^8]. These keys were accessible via standard `IOKit` calls on earlier hardware but failed on Apple Silicon.

Initial attempts to write `F0Md` on M4 hardware returned `0xe00002c2` (`kIOReturnNotPrivileged`). Investigation focused on code signing and permission combinations. This proved to be a dead end: Developer ID code signing is required (see [Privilege Requirements](#privilege-requirements)).

System-level tracing using `dtrace` on `thermalmonitord` and `AppleSMC` kernel extension revealed the actual blocker. Reading `F0Md` returned `3` (system mode). Writes to change it failed with `0x82` (`kSMCBadCommand`), a firmware-level rejection. The `thermalmonitord` daemon enforced mode 3, preventing direct mode changes.

Binary analysis with IDA Pro decompiled `thermalmonitord` and `AppleSMC`, producing tens of thousands of lines of pseudocode. LLMs were employed to analyze this output, searching for patterns in SMC write operations and cross-referencing `Ftst` flag usage. This automated analysis identified `Ftst` as a trigger for thermal management state changes.

Experimental testing identified `Ftst=1` as the key to bypassing the lock. Unlike the mode keys, writes to the `Ftst` (Force Test) key succeeded even when the system was in "System Mode" (mode 3). Timed observation revealed the unlock pattern:

- Write `Ftst=1` (returns success)
- Monitor `F0Md` value (initially reads `3`)
- After 3-4 seconds, `F0Md` transitions to `0`
- Retry `F0Md=1` write (typically succeeds within 4-6 seconds)
- Manual control enabled

The mechanism is timing-based. `thermalmonitord` monitors the `Ftst` state and temporarily yields control of the fan modes. See [Implementation](#implementation) for details on the retry logic.

### Privilege Requirements

Direct SMC writes from userspace consistently failed with `kIOReturnNotPrivileged`. Testing determined that Developer ID code signing is required for `SMJobBless`. Self-signed certificates and those from free developer accounts are not supported; a paid Apple Developer Program membership is necessary to obtain a Developer ID certificate. Additionally, the primary requirement for writing restricted SMC keys is that the process must run as a **privileged helper daemon** (root).

**Testing approach:**

1. Attempted SMC writes from unsigned helper → Failed (code signing required for `SMJobBless`)
2. Attempted SMC writes from signed helper (running as root) → SMC reads succeeded, mode writes failed with `0x82`
3. Applied unlock sequence (`Ftst=1` → retry `F0Md=1`) → **Mode writes succeeded**

The unlock mechanism worked once the process was running as a privileged helper daemon. Analysis of system binaries confirmed that while `thermalmonitord` communicates via `AppleSMCSensorDispatcher`, the `Ftst` unlock bypasses this path using standard `IOKit` calls to `AppleSMC`.

However, `thermalmonitord` reclaimed control within seconds of the controlling process exiting. Monitoring `F0Md` after process termination showed mode reverting from 1 → 3.

This behavior indicated the requirement for a **persistent helper daemon**. The daemon must:

- Maintain an active `IOKit` connection to `AppleSMC`
- Keep `Ftst=1` state active
- Respond to fan control requests via IPC

The architecture follows Apple's `SMJobBless` pattern [^4]: a privileged helper installed to `/Library/PrivilegedHelperTools/` communicates with the CLI via XPC.

### Implementation

The project is implemented in **Swift** with a C library for low-level SMC operations. The Swift code handles `XPC` communication and privileged helper installation, while the C layer directly interfaces with `IOKit` for hardware access.

#### Fan Control Unlock Logic

The unlock sequence is implemented in `smcUnlockFanControl()` (see `Sources/smcfanhelper/SMCConnection.swift`). It uses a 100ms retry interval and a 10 second timeout to wait for `thermalmonitord` to yield control after the `Ftst=1` toggle.

**Mechanism Details**: Analysis of the decompiled `thermalmonitord` binary reveals that `Ftst=1` inhibits the daemon's `LifetimeServoController` from sending temperature targets to `AppleCLPC` (Closed Loop Power Controller). The daemon's main polling loop continues running but its reclaim logic is suppressed while `Ftst` remains set. The unlock succeeds because `AppleCLPC` checks the `Ftst` flag in firmware before enforcing Mode 3.

### Key Findings

**System Behavior:**

- Setting `Ftst=0` returns control to `thermalmonitord`
- Auto mode sets target to minimum RPM while keeping manual control active
- Fan speeds are clamped to SMC-reported min/max values (typical M4 Max: ~2300-7800 RPM)

**Sleep/Wake Behavior:**

- The SMC firmware (`RTKit`) automatically resets `Ftst` to `0` during sleep state transitions. Analysis of `thermalmonitord`'s decompiled sleep handler shows the daemon does not explicitly reset `Ftst`—the firmware performs this reset independently.
- Manual fan control is lost on wake and must be re-established. Runtime testing confirms that re-executing the unlock sequence after wake restores control.
- Implementations should monitor system sleep/wake notifications to handle this reset behavior.

**Modern Hardware Constraints:**

- **Coupled Fans**: Experimental testing on M4 Max hardware shows both fans track similar speeds, with Fan 1 following Fan 0's RPM even when separate `F0Tg`/`F1Tg` target keys are written.

## Technical Details

### IOKit Communication

- Service: `AppleSMC`
- Connection type: `0`
- Selector: `2`
- Struct size: `80 bytes`

Commands:

- `9` - Read key info
- `5` - Read value
- `6` - Write value

### thermalmonitord (Apple Silicon)

`thermalmonitord` (located at `/usr/libexec/thermalmonitord`) is a system daemon on Apple Silicon Macs responsible for thermal management [^10][^11]. While not documented in Apple's developer resources, its role and operation are described in technical references. It:

- Monitors CPU, GPU, battery, and sensor temperatures [^10][^11]
- Adjusts fan speeds and performance based on thermal policy [^11][^12]
- Publishes thermal state to apps via `NSProcessInfo.thermalState` [^1][^2]

Decompiled code analysis reveals the daemon coordinates with hardware controllers including `AppleCLPC` (Closed Loop Power Controller) and `ApplePMGR` (Power Manager) via IOKit property writes. Runtime observation shows the daemon enforces "System Mode" (`F%dMd=3`), which blocks direct SMC fan mode writes until the unlock sequence is applied.

**Firmware Fallback:** If `thermalmonitord` is killed or unresponsive, hardware-level thermal protection remains active. The kernel and SMC firmware independently enforce temperature limits, throttle performance, run fans at maximum, and trigger emergency shutdown if thresholds are exceeded. Killing the daemon removes graceful thermal management but does not disable hardware protection.

The daemon runs continuously and reclaims control when the unlock mechanism is released. A helper process must maintain an active connection to preserve manual control. See Apple's documentation on thermal state notifications [^1] and IOKit thermal warnings [^2] for related APIs.

**Polling Behavior**: Decompiled code analysis reveals that `thermalmonitord` polls SMC sensors at approximately 4000ms (4 second) intervals during idle operation, configured via the `AppleSMCSensorDispatcher`. Under thermal load, the `MitigationController` enters "fast mode" with polling intervals as short as 250ms, allowing rapid response to temperature changes and more frequent reclaim attempts.

### Error Codes

**IOKit Errors:**

| Code | Name | Description |
| --- | --- | --- |
| `0xe00002c2` | `kIOReturnNotPrivileged` | Operation requires root privileges (use privileged helper daemon) |

**SMC Errors (returned in `result` field):**

| Code | Name | Description |
| --- | --- | --- |
| `0x00` | Success | Operation completed |
| `0x82` | `kSMCBadCommand` | Firmware rejects write. Observed when attempting to write `F%dMd` keys while system is in Mode 3. Analysis of decompiled `AppleSMC.kext` shows this error originates from `RTKit` firmware communication. |
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

### Debugging

Decompiled code analysis of `thermalmonitord` reveals built-in debugging capabilities accessed via boot arguments:

**Boot Arguments** (set via `sudo nvram boot-args="..."`):

- `smc-debug` - Enables verbose SMC logging to system logs
- `smc-logsize` - Controls SMC log buffer size

These flags are checked in `thermalmonitord`'s initialization code and can aid in tracing firmware behavior and SMC communication patterns. Verbose logs appear in Console.app or via `log stream --predicate 'process == "thermalmonitord"'`.

**Wake Handler**: Decompiled code shows `thermalmonitord` listens for `kIOMessageSystemWillPowerOn` (`0xe0000310`) to re-initialize after wake. The wake handler re-creates power assertions and notifies controllers that the system is awake. Implementations should similarly monitor `NSWorkspace.didWakeNotification` to re-establish manual control after sleep state transitions.

## Known Limitations

### Hardware-Enforced Restrictions

The following limitations are imposed by firmware and cannot be bypassed via SMC key manipulation:

**Coupled Fan Behavior**: Experimental testing on M4 Max hardware shows both fans synchronize speeds despite separate `F0Tg`/`F1Tg` writes, with Fan 1 tracking Fan 0's RPM. This indicates firmware-level coupling where independent fan control is not possible.

### Daemon Reclaim Behavior

Decompiled code analysis reveals `thermalmonitord`'s polling characteristics:

- **Default Polling**: Approximately 4000ms (4 seconds) during idle, configured in `AppleSMCSensorDispatcher`
- **Fast Mode**: Under thermal load, `MitigationController` reduces polling to approximately 250ms for rapid response
- **Reclaim Frequency**: During fast mode, the daemon checks fan state every 250ms and will attempt to reclaim control if `Ftst` is not set

Implementations requiring persistent manual control must maintain `Ftst=1` state and handle rapid reclaim attempts during thermal load conditions.

## Future Research Directions

The methodologies used here could reveal other SMC-controllable parameters:

- **Power Management** - CPU/GPU power limits, TDP controls
- **Thermal Sensors** - Access to temperature sensors beyond standard APIs
- **Performance States** - Direct control over P-states, frequency scaling
- **Battery Management** - Charge limits, health parameters
- **System Telemetry** - Undocumented sensor data

### Alternative Control Mechanisms

Decompiled code analysis has identified potential alternative approaches that may provide cleaner or more persistent control than the `Ftst` unlock mechanism:

**Plist-Based Thermal Targets** (Untested): Analysis of `thermalmonitord`'s decompiled configuration monitoring code shows the daemon reads `/Library/Preferences/SystemConfiguration/com.apple.cltm.plist` for override values including `LifetimeServoDieTempTarget`. Setting this key to a low temperature value might cause the thermal servo loop to maximize fan speeds in an attempt to reach the target, providing persistent control without active processes. This approach uses the OS's native thermal management logic and would survive reboots.

**Direct IOKit Property Writes** (Untested): Decompiled code shows the daemon writes thermal targets to hardware controllers using `IORegistryEntrySetCFProperty`. Properties including `LifetimeServoDieTemperatureTargetPropertyKey` (M1/M2) and `LifetimeServoFastDieTemperatureTarget` (M3/M4) are written to either the `AppleCLPC` or `AppleDieTempController` service. Running as root might allow direct property writes to these services, bypassing `thermalmonitord` entirely, though required entitlements and access restrictions require investigation.

**Alternative Diagnostic Keys**: Beyond `Ftst`, the decompiled code references other thermal and diagnostic keys including `TG0B`, `TG0V`, `zETM`, `zEAR`, and `TGraph`. Analysis indicates `Ftst` is the primary diagnostic override for fan control, with no evidence of additional "master unlock" keys.

## Quick Start

### Prerequisites

- Xcode Command Line Tools: `xcode-select --install`
- **Paid Apple Developer account** — **REQUIRED**. A paid account is necessary to obtain a Developer ID certificate for code signing the privileged helper daemon.
- Valid Apple Developer ID certificate for code signing.
- Your Apple Team ID (find at <https://developer.apple.com/account>).

### Configuration

Copy the example config and customize with your credentials:

```bash
cp config.mk.example config.mk
# Edit config.mk with your values:
#   CERT_ID - Your Developer ID certificate (find with: security find-identity -v -p codesigning)
#   TEAM_ID - Your Apple Team ID
#   BUNDLE_ID_PREFIX - Your bundle identifier prefix (e.g., com.yourname)
```

**Note:** You MUST use your own unique bundle identifier prefix. The helper daemon is installed system-wide and will conflict if multiple users use the same ID.

### Build

Production build (with code signing):

```bash
make all
```

Development build (IDE/testing):

```bash
# Replace 'your.identifier' with your actual bundle ID prefix
HELPER_BUNDLE_ID=your.identifier.smcfanhelper swift build
```

### Install

```bash
./Products/SMCFanHelper.app/Contents/MacOS/SMCFanInstaller
# Enter password when prompted
```

The installer uses `SMJobBless` [^4] to install a privileged helper daemon.

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
└── Makefile              Build system
```

## References

[^1]: [Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html) - `NSProcessInfo.thermalState` API
[^2]: [kIOPMThermalWarningNotificationKey](https://developer.apple.com/documentation/iokit/kiopmthermalwarningnotificationkey) - IOKit thermal notifications
[^3]: [Apple Platform Security - Boot Modes](https://support.apple.com/guide/security/sec10869885b) - Firmware security architecture
[^4]: [SMJobBless](https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:)) - Privileged helper installation
[^5]: [Apple SMC Data Types](https://cbosoft.github.io/blog/2020/07/17/apple-smc/) - `fpe2` format encoding
[^6]: [Asahi Linux SMC Documentation](https://asahilinux.org/docs/hw/soc/smc/) - Apple Silicon SMC key formats
[^7]: [SMC Sensor Keys Reference](https://www.marukka.ch/mac/mac-smc-sensor-keys) - Comprehensive SMC key catalog
[^8]: [smcFanControl Repository](https://github.com/hholtmann/smcFanControl) - Open-source fan control tool
[^9]: [Linux Kernel applesmc Driver](https://github.com/torvalds/linux/blob/master/drivers/hwmon/applesmc.c) - Authoritative source for SMC key schema and protocol
[^10]: [The iPhone Wiki - thermalmonitord](https://www.theiphonewiki.com/wiki/Thermalmonitord) - Technical database documenting system daemon functionality
[^11]: Jonathan Levin, "Mac OS X and iOS Internals, Volume I: User Space" - System daemons and thermal management architecture
[^12]: [Apple Support - Device Temperature Management](https://support.apple.com/en-us/HT201678) - Thermal mitigation behaviors

## License

Educational and research use only. See [warning](#️-warning) above.
