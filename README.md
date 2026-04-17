# SMC Fan Control Research for Apple Silicon

[![Swift](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml/badge.svg)](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml)

## Motivation

Prior to this research, no public documentation existed for manual fan **control** on Apple Silicon **within macOS**. While reading sensor data was documented [^6][^14], and the Asahi Linux project implemented fan control for Linux on Apple Silicon [^14][^15], no prior work documented how to achieve this on macOS. On macOS, Apple's `thermalmonitord` daemon actively blocks direct SMC writes.

The Asahi Linux kernel driver (`macsmc-hwmon`) provides fan control via standard `hwmon` interfaces when running Linux, but this requires booting into Linux and uses kernel-level access without an active thermal management daemon blocking writes. On macOS, the challenge is fundamentally different: `thermalmonitord` enforces "System Mode" (mode 3) and firmware rejects manual mode changes unless a specific unlock sequence is applied.

This project documents the **macOS-specific research process**, the discovered **diagnostic mode transition** (`Ftst` unlock), and provides a working example implementation. The research reveals how `thermalmonitord` enforces System Mode and the specific SMC key sequence required to enable manual control from userspace on macOS.

Beyond fan control, this work demonstrates **SMC research methodologies** that could expose other controllable system parameters.

## ⚠️ Warning

**For educational and research purposes only.** This software:

- Can cause **hardware damage** if fans are set incorrectly
- May interfere with macOS thermal management
- Is provided **without any warranty**
- Is **not affiliated with or endorsed by Apple Inc.**

**Use entirely at your own risk.** Monitor system temperatures carefully. Not intended for production use.

## License

MIT License. Research findings and code may be freely used in independent implementations. See [LICENSE.md](LICENSE.md) for full terms and legal notice.

## Methodology

This project documents the analysis of Apple Silicon's thermal management system using a combination of static binary analysis and LLM-assisted code comprehension.

### Toolchain

- **IDA Pro (Hex-Rays Decompiler)**: Used to decompile `AppleSMC.kext` (kernel extension, ~801 functions) and `thermalmonitord` (userspace daemon, ~775 functions) from their stripped arm64e binaries into pseudocode
- **dtrace**: Runtime tracing of SMC operations and daemon behavior to correlate static analysis with actual execution paths
- **LLMs**: Applied to analyze tens of thousands of lines of decompiled pseudocode, identify patterns in SMC key handling, and cross-reference function behaviors across binaries
- **Test Hardware**: MacBook Pro (14-inch, M4 Max, 2024, Apple Silicon), MacBook Pro (16-inch, M1 Pro, 2021, Apple Silicon), and iMac (Retina 5K, 27-inch, 2019, Intel). Model identifiers: `Mac16,6`, `MacBookPro18,1`, and `iMac19,1` respectively

### Approach

1. **Binary Extraction**: Extracted `thermalmonitord` from `/usr/libexec/` and `AppleSMC.kext` from the kernel extension cache
2. **Decompilation**: Used IDA Pro to generate C-like pseudocode from the arm64e binaries (which include pointer authentication)
3. **Pattern Analysis**: Fed decompiled output to LLMs with targeted prompts to identify:
   - SMC key read/write handlers and their error conditions
   - The `Ftst` (Force Test) flag's role in thermal management state transitions
   - Polling intervals and control reclaim mechanisms in `thermalmonitord`
   - Interactions between `thermalmonitord`, `AppleCLPC`, and the `RTKit` firmware layer
4. **Experimental Validation**: Confirmed LLM-identified patterns through runtime testing, including timing the unlock sequence, observing mode transitions, and verifying error conditions

### Why LLMs?

Stripped binaries produce decompiled output with generic function names (`FUN_00xxxxxx`) and no comments. Manually analyzing 1.5MB of pseudocode is impractical. LLMs excel at:

- Pattern matching across large codebases (finding all references to specific SMC keys)
- Inferring function purpose from call patterns and data structures
- Cross-referencing behavior between related binaries (daemon ↔ kernel driver)
- Answering targeted questions ("What happens when `Ftst` is set to 1?")

This hybrid approach (traditional binary analysis tools combined with LLM analysis) enabled discoveries that would have taken significantly longer through manual analysis alone.

## Background

### Key Terms

- **SMC (System Management Controller)**: A microcontroller (Legacy/T2) or integrated firmware component (Apple Silicon) that manages low-level hardware: thermal sensors, fan speeds, power states, and other system functions [^7]. On legacy hardware, it's discrete; on Apple Silicon, it's part of the SoC.
- **SoC (System-on-Chip)**: Apple Silicon (M1-M5+) integrates CPU, GPU, Neural Engine, memory controllers, and management components into a single chip, unlike earlier Macs which had separate components. See Apple's documentation on boot security for more on SoC architecture [^3].
- **`RTKit`**: Apple's embedded firmware backend that manages the integrated SMC on Apple Silicon [^6], replacing the older ACPI-based interface used previously.
- **Daemon**: A background system process (e.g., `thermalmonitord`) that runs with elevated privileges and coordinates system behavior. It monitors thermal pressure [^1] and publishes state changes [^2].
- **`IOKit`**: Apple's macOS kernel framework for communicating with hardware devices from userspace. It provides a structured way to discover, access, and control device drivers without requiring kernel code. In this project, `IOKit` is used to open a connection to the `AppleSMC` driver and issue read/write commands to SMC keys [^13].

### Evolution of macOS SMC-based Fan Control

The transition to Apple Silicon moved fan management from a discrete chip to a component integrated directly into the SoC [^3]. System management logic shifted from the H8/SMC controller to the Always-On (AOP) subsystem.

#### Legacy Architecture

Standard Macs used a dedicated System Management Controller chip [^7][^9]. Writing to fan control keys like `F0Tg` (Fan 0 Target) was direct and the OS didn't block manual overrides. Thermal management was automatic: the SMC read temperature sensors and adjusted fan speed.

#### T2 Security Chip

The T2 chip added a security layer. SMC functions moved into this separate processor [^3], adding abstraction between the OS and hardware. Manual fan control still worked but required different SMC key sequences.

#### M1 Generation

With Apple Silicon, Apple integrated SMC functionality into the main chip itself [^6]. Investigation revealed a fundamental architectural shift: instead of the SMC independently managing fans, a background system process called `thermalmonitord` [^10][^11] now coordinates thermal policy. Runtime tracing and decompiled code analysis confirmed this process actively prevents direct fan control by enforcing a locked state that blocks manual mode changes.

**Direct Mode on M1**: Runtime testing has observed that direct writes to `F%dMd=1` (manual mode) succeed on M1 hardware without requiring the `Ftst` unlock sequence. The firmware accepts manual mode changes immediately, similar to Intel Macs but with Apple Silicon data formats (4-byte IEEE 754 float). M2 behavior remains untested but may follow the same pattern. This differs from M3/M4 where `thermalmonitord` enforcement requires the diagnostic unlock.

**Note on Asahi Linux**: The Asahi Linux project developed a kernel driver (`macsmc-hwmon`) [^14][^15] that provides fan control when running Linux on Apple Silicon. Their approach differs fundamentally: Linux has no `thermalmonitord` equivalent blocking writes, so direct SMC access via kernel driver is sufficient. They expose fan control through standard hwmon sysfs interfaces with an "unsafe" module parameter (`fan_control=1`). This work documents the SMC key schema and data formats but does not address the macOS-specific challenge of bypassing daemon enforcement.

**Key Changes from Legacy:**

- Active daemon-based thermal management replaces passive SMC automation
- Fan mode writes are blocked by default ("system mode") on M3/M4
- M1 allows direct mode writes without unlock sequence
- SMC operations moved to firmware layer
- Discovery of diagnostic unlock mechanism that temporarily disables daemon enforcement

Experimental testing identified a diagnostic flag (`Ftst`) that temporarily disables daemon enforcement on M3/M4. Decompiled code analysis confirms this mechanism is consistent across M1-M4 generations. Manual control can be maintained with an active privileged process.

Note: A separate process called `thermald` also runs on these Macs. Analysis of its imports shows it monitors power/thermal metrics and publishes **thermal pressure levels** (nominal/fair/serious/critical) via system notifications for apps to react to [^1]. It does not directly control fans (that's `thermalmonitord`'s role). It appears that they are complementary: `thermald` reports, `thermalmonitord` acts.

#### M2 Generation
Further research is needed to determine the changes between M1 and M2 SMC architecture.

#### M3 and M4 Generation

**Key Changes**
- Fan mode writes are blocked by default ("system mode")
- Discovery of diagnostic unlock mechanism that temporarily disables daemon enforcement

Experimental testing identified a diagnostic flag (`Ftst`) that temporarily disables daemon enforcement. Decompiled code analysis confirms this mechanism is consistent across M3-M4 generations. Manual control can be maintained with an active privileged process. See [Daemon Reclaim Behavior](#daemon-reclaim-behavior) for technical details.

#### M5 Generation

Testing on M5 Max (Mac17,7, macOS 26.4.1) revealed two changes from M4:

- **Mode key casing changed**: The fan mode key is `F%dmd` (lowercase `m`) rather than `F%dMd` (uppercase `M`). The `readKeyInfo` command returns `SmcNotFound` (0x84) for the uppercase variant. Implementations must probe both casings at runtime.
- **`Ftst` key absent**: The `Ftst` (Force Test) diagnostic key does not exist on M5 Max. `readKeyInfo` returns `SmcNotFound` (0x84). Direct writes to `F%dmd=1` succeed immediately without any unlock sequence.
- **No unlock sequence needed**: Fan mode can be set directly by writing `F%dmd=1`, then setting the target RPM via `F%dTg`. No `Ftst` toggle or retry loop is required.

**Conjecture**: The lowercase mode key (`F%dmd`) and absence of `Ftst` may be correlated. On Intel Macs, the mode key is always uppercase (`F%dMd`) and fan control uses a different mechanism entirely (the `FS! ` key). On Apple Silicon M1-M4, the uppercase key persists alongside the `Ftst` unlock mechanism. The M5's shift to lowercase may indicate a firmware-level change in how fan mode control is exposed, possibly simplifying the interface by removing the diagnostic unlock requirement. This is unverified on other M5 variants (M5, M5 Pro).

## Research Findings

### SMC Keys

Prior research [^7][^8][^9] found the following keys, which were verified for Apple Silicon [^14] through `dtrace` tracing of `thermalmonitord` and `AppleSMC` kernel extensions, complemented by IDA Pro binary analysis.

> **Key format**: `%d` is a placeholder for the fan index (0-based). For example, `F0Ac` is fan 0's actual RPM, `F1Tg` is fan 1's target RPM.

| Key | Type | Description |
| --- | --- | --- |
| `FNum` | `uint8` | Number of fans |
| `F%dAc` | `float` | Actual RPM (read-only) |
| `F%dTg` | `float` | Target RPM (0 to any value; not bounded by min/max) |
| `F%dMn` | `float` | Recommended minimum RPM (guideline, not enforced) |
| `F%dMx` | `float` | Recommended maximum RPM (guideline, not enforced) |
| `F%dMd` or `F%dmd` | `uint8` | Mode (0=auto, 1=manual, 3=system). Key casing varies: For example, uppercase on M4 Max, lowercase on M5 Max. Probe both at runtime. |
| `Ftst` | `uint8` | Force/test flag. Absent on M5 Max. |

**Note on Min/Max Values**: The `F%dMn` and `F%dMx` keys report recommended operating ranges, not hard limits. Testing confirms:

- Target can be set to 0 RPM (fan stops completely)
- Target can be set below the reported minimum (fan will spin at achievable speed)
- Target can be set above the reported maximum (fan will exceed reported max if physically capable)

**Data Formats:**

- **Legacy (FPE2) Format**: 2-byte `fpe2` fixed-point (14.2 format, big-endian). The top 14 bits are integer, bottom 2 bits are fractional (divide raw value by 4) [^5].
- **Apple Silicon**: 4-byte IEEE 754 float (little-endian) [^6][^14].

Cross-platform code must detect and handle both formats [^5][^6]. See [Architecture & Research Insights](#architecture--research-insights) for more on how these keys are managed on Apple Silicon.

### Fan Modes

The values for the mode key (`F%dMd` or `F%dmd`, depending on hardware; see [M5 Generation](#m5-generation)) were identified by monitoring system state transitions during experimental testing and analyzing the decompiled `thermalmonitord` logic. Subsequent references to "the mode key" in this document apply to whichever casing variant is present on the target hardware. The mode names (Auto, Manual, System) are informal labels, not official Apple terminology.

| Mode | Name | Description |
| --- | --- | --- |
| `0` | Auto | System manages fans, target defaults to minimum RPM |
| `1` | Manual | User controls target RPM via `F%dTg` |
| `2` | ? | Legacy (T2): Forced manual mode; not observed on Apple Silicon |
| `3` | System | Active mitigation state (`AppleCLPC`); firmware rejects manual mode changes |

Mode 3 is the default on Apple Silicon when `thermalmonitord` is managing system thermals. The unlock sequence transitions the system from mode 3 → 0, then allows setting mode 1.

### Architecture & Research Insights

Through disassembly of `thermalmonitord` and `AppleSMC.kext`, several key architectural details were identified:

1. **`RTKit` Abstraction**: On Apple Silicon, SMC keys like the mode key and `Ftst` are not hardcoded in userspace binaries. They are managed by the **`RTKit` firmware** embedded within the SoC [^6]. The `AppleSMC` kernel driver acts as a transparent bridge to this firmware.
2. **Property-Based Control**: `thermalmonitord` does not write to SMC keys directly. Instead, it uses high-level Objective-C properties (via `IORegistryEntrySetCFProperty`) to communicate with hardware controllers like **`AppleCLPC`** (Closed Loop Power Controller) and **ApplePMGR** (Power Manager). It sets "ceilings" and "mitigations" rather than raw RPMs.
3. **Mode 3 is a State, not a Command**: "System Mode" (`mode 3`) is not a command sent by the daemon. Rather, it is the state *reported* by the `RTKit` firmware when hardware controllers like `AppleCLPC` are in an active mitigation state. This explains why `thermalmonitord` does not need to "set" mode 3; its very operation causes the hardware to enter and report that state.
4. **`Ftst` Unlock Mechanism**: Decompiled code analysis of `thermalmonitord` reveals the `Ftst=1` write inhibits the `LifetimeServoController` component from asserting thermal targets. Specifically, when `Ftst` is set, the controller's reclaim logic is suppressed, preventing it from sending die temperature targets to `AppleCLPC`. This allows manual fan mode to persist. The daemon's polling loop continues checking sensors but does not override fan settings while in this diagnostic state.
5. **Model Detection**: The decompiled code includes board ID to configuration mapping that determines which thermal controller to use. M3/M4 models are identified by the `updateCPUFastDieTargetPMP` configuration flag, which enables `AppleDieTempController` instead of `AppleCLPC`. This allows implementations to programmatically detect hardware generation and adjust behavior accordingly.
6. **Mode 2 (Legacy)**: While value `2` appears in older SMC tools (like `smcFanControl` [^8]) or community databases [^7] as a "manual override" or "forced" mode for T2-equipped Macs, no references to it were found in the Apple Silicon `thermalmonitord` or driver logic.
7. **Read/Write Permission Model**: The permission asymmetry between reads and writes does not appear to originate at the `IOKit` connection level. Both operations use identical `IOServiceOpen` parameters (connection type `0`) and the same `IOConnectCallStructMethod` selector (`2`). The VirtualSMC SDK [^16] documents a per-key attribute byte that the SMC firmware evaluates independently for each operation. The Asahi Linux SMC documentation [^6] similarly describes per-key flags bytes across the ~1,400 SMC keys on Apple Silicon. This per-key model is consistent with our observation that any unprivileged process can read sensor data (temperatures, fan speeds, voltages), while writes to fan control keys require root. For implementations building on these libraries, this means `SMCKit` can be used directly by any application for read-only monitoring without a privileged helper. The helper daemon is only required for write operations performed through `SMCFanKit`.

### Discovery Process

Prior work established the basic SMC key schema from the Linux kernel `applesmc` driver [^9]: `F0Md` for fan mode, `F0Tg` for target RPM, and `Ftst` for force/test state [^7][^8]. These keys were accessible via standard `IOKit` calls on earlier hardware but failed on Apple Silicon.

Initial attempts to write `F0Md` on M4 hardware returned `0xe00002c2` (`kIOReturnNotPrivileged`). Investigation focused on code signing and permission combinations. This proved to be a dead end: Developer ID code signing is required (see [Privilege Requirements](#privilege-requirements)).

System-level tracing using `dtrace` on `thermalmonitord` and `AppleSMC` kernel extension revealed the actual blocker. Reading `F0Md` returned `3` (system mode). Writes to change it failed with `0x82` (`kSMCBadCommand`), a firmware-level rejection. The `thermalmonitord` daemon enforced mode 3, preventing direct mode changes.

Binary analysis with IDA Pro decompiled `thermalmonitord` and `AppleSMC`, producing tens of thousands of lines of pseudocode. LLMs were employed to analyze this output, searching for patterns in SMC write operations and cross-referencing `Ftst` flag usage. This automated analysis identified `Ftst` as a trigger for thermal management state changes.

Experimental testing identified `Ftst=1` as the key to enabling manual control. Unlike the mode keys, writes to the `Ftst` (Force Test) key succeeded even when the system was in "System Mode" (mode 3). Timed observation revealed the unlock pattern:

- Write `Ftst=1` (returns success)
- Monitor `F0Md` value (initially reads `3`)
- After 3-4 seconds, `F0Md` transitions to `0`
- Retry `F0Md=1` write (typically succeeds within 4-6 seconds)
- Manual control enabled

The mechanism is timing-based. `thermalmonitord` monitors the `Ftst` state and temporarily yields control of the fan modes. See [Implementation](#implementation) for details on the retry logic.

### Privilege Requirements

Direct SMC writes from userspace consistently failed with `kIOReturnNotPrivileged`. Testing determined that Developer ID code signing is required for `SMJobBless`. Self-signed certificates and those from free developer accounts are not supported; a paid Apple Developer Program membership is necessary to obtain a Developer ID certificate. Additionally, the primary requirement for writing restricted SMC keys is that the process must run as a **privileged helper daemon** (root).

**Read vs. Write Asymmetry**: Testing indicates that SMC reads (command `5`) succeed from unprivileged user processes without code signing or root privileges. This behavior is consistent with observations across multiple independent implementations: SMCKit [^17] documents that reading temperatures and fan speeds requires no elevation, while writes require root; smc-fuzzer [^18] demonstrates read operations without `sudo` while noting "no value should be writable as a non-privileged user"; and Stats [^19] reads all SMC sensor data directly from its unprivileged app process, reserving its privileged helper exclusively for fan control writes. The restriction appears to be enforced at the SMC firmware level rather than the `IOKit` connection level: both reads and writes use the identical `IOServiceOpen(..., 0, &conn)` call and `IOConnectCallStructMethod` selector (`2`). The VirtualSMC SDK [^16] documents a per-key attribute byte where bit 7 (`0x80`) controls read access and bit 6 (`0x40`) controls write access, suggesting the firmware makes per-key permission decisions independent of the calling process's connection parameters.

**Testing approach:**

1. Attempted SMC writes from unsigned helper → Failed (code signing required for `SMJobBless`)
2. Attempted SMC writes from signed helper (running as root) → SMC reads succeeded, mode writes failed with `0x82`
3. Applied unlock sequence (`Ftst=1` → retry `F0Md=1`) → **Mode writes succeeded**

The unlock mechanism worked once the process was running as a privileged helper daemon. Analysis of system binaries confirmed that while `thermalmonitord` communicates via `AppleSMCSensorDispatcher`, the `Ftst` unlock uses standard `IOKit` calls directly to `AppleSMC`.

However, `thermalmonitord` reclaimed control within seconds of the controlling process exiting. Monitoring `F0Md` after process termination showed mode reverting from 1 → 3.

This behavior indicated the requirement for a **persistent helper daemon**. The daemon must:

- Maintain an active `IOKit` connection to `AppleSMC`
- Keep `Ftst=1` state active
- Respond to fan control requests via IPC

The architecture follows Apple's `SMJobBless` pattern [^4]: a privileged helper installed to `/Library/PrivilegedHelperTools/` communicates with the CLI via XPC.

### Implementation

The project is implemented entirely in **Swift**. Low-level SMC communication (`IOKit` calls, struct layout, data format conversion) lives in the `SMCKit` library. Fan control logic (key constants, hardware detection, mode management) lives in `SMCFanKit`. The privileged helper daemon, CLI, and installer consume these libraries via `XPC`.

#### Fan Control Unlock Logic

The unlock sequence is implemented in `FanController.unlockFanControlSync()` (see `Sources/SMCFanKit/FanControl.swift`). It uses a 100ms retry interval and a 10 second timeout to wait for `thermalmonitord` to yield control after the `Ftst=1` toggle.

**Mechanism Details**: Analysis of the decompiled `thermalmonitord` binary reveals that `Ftst=1` inhibits the daemon's `LifetimeServoController` from sending temperature targets to `AppleCLPC` (Closed Loop Power Controller). The daemon's main polling loop continues running but its reclaim logic is suppressed while `Ftst` remains set. The unlock succeeds because `AppleCLPC` checks the `Ftst` flag in firmware before enforcing Mode 3.

### Key Findings

**System Behavior:**

- Setting `Ftst=0` returns control to `thermalmonitord`
- When `thermalmonitord` regains control, fans enter mode 3 (system) and can idle at 0 RPM
- Fan speeds are NOT strictly bounded by min/max values (these are guidelines only)
- Independent fan control is fully supported on Apple Silicon

**Sleep/Wake Behavior:**

- The SMC firmware (`RTKit`) automatically resets `Ftst` to `0` during sleep state transitions. Analysis of `thermalmonitord`'s decompiled sleep handler shows the daemon does not explicitly reset `Ftst`. The firmware performs this reset independently.
- Manual fan control is lost on wake and must be re-established. Runtime testing confirms that re-executing the unlock sequence after wake restores control.
- Implementations should monitor system sleep/wake notifications to handle this reset behavior.

**Modern Hardware Constraints:**

- Typical M4 Max fan range: ~0-8400+ RPM (physical limits discovered via direct testing, not SMC-reported min/max)

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

**Access Control**: All three commands use the same `IOKit` call path (`IOServiceOpen` with connection type `0`, `IOConnectCallStructMethod` with selector `2`). The permission difference between reads and writes appears to be enforced by the SMC firmware's per-key attribute system rather than by `IOKit` connection parameters. The VirtualSMC SDK [^16] documents that each SMC key carries an attribute byte: bit 7 (`0x80`) grants read access, bit 6 (`0x40`) grants write access, and bit 0 (`0x01`) marks private write (requiring elevated privileges). Most sensor keys (temperatures, fan speeds) carry attribute `0x80` (read-only) or `0x90` (read + function), while fan control keys carry `0xC0` or `0xC1` (read + write, sometimes private write). Command `5` (read) to a key with bit 7 set succeeds from any user process. Command `6` (write) to a restricted key returns `kIOReturnNotPrivileged` (`0xe00002c2`) unless the calling process runs as root.

### thermalmonitord (Apple Silicon)

`thermalmonitord` (located at `/usr/libexec/thermalmonitord`) is a system daemon on Apple Silicon Macs responsible for thermal management [^10][^11]. While not documented in Apple's developer resources, its role and operation are described in technical references. It:

- Monitors CPU, GPU, battery, and sensor temperatures [^10][^11]
- Adjusts fan speeds and performance based on thermal policy [^11][^12]
- Publishes thermal state to apps via `NSProcessInfo.thermalState` [^1][^2]

Decompiled code analysis reveals the daemon coordinates with hardware controllers including `AppleCLPC` (Closed Loop Power Controller) and `ApplePMGR` (Power Manager) via IOKit property writes. Runtime observation shows the daemon enforces "System Mode" (the mode key reads `3`), which blocks direct SMC fan mode writes until the unlock sequence is applied.

**Firmware Fallback:** Based on the presence of shutdown handlers in decompiled `AppleSMC` code (e.g., `_claimSystemShutdownEvents`, `sysState.ShutdownSystem`) and general embedded systems design principles, hardware-level thermal protection likely remains active if `thermalmonitord` is killed or unresponsive. The SMC firmware is expected to independently enforce temperature limits, throttle performance, and trigger emergency shutdown if thresholds are exceeded. This has not been experimentally verified by killing the daemon under thermal load.

The daemon runs continuously and reclaims control when the unlock mechanism is released. A helper process must maintain an active connection to preserve manual control. See Apple's documentation on thermal state notifications [^1] and IOKit thermal warnings [^2] for related APIs.

**Polling Behavior**: Decompiled code analysis reveals that `thermalmonitord` polls SMC sensors at approximately 4000ms (4 second) intervals during idle operation, configured via the `AppleSMCSensorDispatcher`. Under thermal load, the `MitigationController` enters "fast mode" with polling intervals as short as 250ms, allowing rapid response to temperature changes and more frequent reclaim attempts.

### Error Codes

**IOKit Errors:**

| Code | Name | Description |
| --- | --- | --- |
| `0xe00002c2` | `kIOReturnNotPrivileged` | Operation requires root privileges (use privileged helper daemon) |

**SMC Errors (returned in `result` field):**

These codes are from VirtualSMC SDK[^16], the authoritative source for Apple SMC protocol documentation.

| Code | Name | Description |
| --- | --- | --- |
| `0x00` | `SmcSuccess` | Operation completed |
| `0x01` | `SmcError` | Generic error |
| `0x80` | `SmcCommCollision` | Communication collision |
| `0x81` | `SmcSpuriousData` | Unexpected data received |
| `0x82` | `SmcBadCommand` | Firmware rejects command. Observed when attempting to write the mode key while system is in Mode 3. Analysis of decompiled `AppleSMC.kext` shows this error originates from `RTKit` firmware communication. |
| `0x83` | `SmcBadParameter` | Invalid parameter value |
| `0x84` | `SmcNotFound` | Key does not exist |
| `0x85` | `SmcNotReadable` | Key is write-only |
| `0x86` | `SmcNotWritable` | Key is read-only |
| `0x87` | `SmcKeySizeMismatch` | Data size mismatch (may still apply value) |
| `0x88` | `SmcFramingError` | Protocol framing error |
| `0x89` | `SmcBadArgumentError` | Bad argument to SMC function |

Note: `0x87` errors on `F0Tg` writes sometimes succeed. The value is applied despite the error response.

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

> **Swift Struct Compatibility Note**: Despite initial concerns about Swift struct padding differing from C, testing with `MemoryLayout.offset` confirms that Swift correctly places all fields at the expected kernel ABI offsets. The nested `keyInfo_t` struct has `size=9` but `stride=12`, and Swift's layout engine properly accounts for this when computing parent struct offsets. This means pure Swift implementations can work without C bridging code (see `Sources/SMCKit/SMCTypes.swift` and `Sources/SMCKit/SMCConnection.swift` for the implementation). The key is using `MemoryLayout<SMCKeyData_t>.stride` (not `.size`) when calling `IOConnectCallStructMethod`.

### Debugging

Decompiled code analysis of `thermalmonitord` reveals built-in debugging capabilities accessed via boot arguments:

**Boot Arguments** (set via `sudo nvram boot-args="..."`):

- `smc-debug` - Enables verbose SMC logging to system logs
- `smc-logsize` - Controls SMC log buffer size

These flags are checked in `thermalmonitord`'s initialization code and can aid in tracing firmware behavior and SMC communication patterns. Verbose logs appear in Console.app or via `log stream --predicate 'process == "thermalmonitord"'`.

**Wake Handler**: Decompiled code shows `thermalmonitord` listens for `kIOMessageSystemWillPowerOn` (`0xe0000310`) to re-initialize after wake. The wake handler re-creates power assertions and notifies controllers that the system is awake. Implementations should similarly monitor `NSWorkspace.didWakeNotification` to re-establish manual control after sleep state transitions.

## Fan Control Behavior

### Independent Fan Control

Testing confirms that each fan can be controlled independently on Apple Silicon:

- Setting one fan to manual mode does **not** affect other fans
- Each fan maintains its own mode key and target (`F%dTg`)
- The unlock sequence must target the specific fan being controlled

### Control Flow

**Enabling Manual Control (per fan):**

The implementation uses a two-phase strategy that tries direct mode first, falling back to the `Ftst` unlock if needed:

1. Read `Ftst` from hardware
2. If `Ftst=1` (already in diagnostic mode), use the unlock sequence
3. If `Ftst=0`, try direct write of the mode key to `1` for the target fan
4. If direct write succeeds (observed on M1 and M5), manual control is enabled instantly
5. If direct write fails with `0x82`, fall back to the `Ftst` unlock sequence:
   - Write `Ftst=1` to signal diagnostic mode
   - Retry writing the mode key to `1` until successful (3-6 seconds)
6. Write target RPM to `F%dTg`
7. Fan is now under manual control

This approach is fully stateless and self-discovering. On M1 hardware, control is instant. On M3/M4, the unlock sequence runs automatically when needed.

**Returning to System Control:**

1. When the **last** manual fan returns to automatic, read `Ftst` from hardware
2. If `Ftst=1`, write `Ftst=0` to return control to `thermalmonitord`
3. If `Ftst=0`, no reset is needed (direct mode was used)
4. `thermalmonitord` regains control and sets mode to 3 (system)
5. Fans can drop to 0 RPM if thermal conditions allow

**Important**: Only reset `Ftst=0` when **all** fans are returning to automatic and `Ftst` is currently set. If other fans remain in manual mode, only set the target fan's mode to 0.

### Test Results

The following measurements were collected on M4 Max hardware (2 fans, reported min=2317, max=7826).

#### Command Timing

| Transition Type | Command Time | Notes |
| --------------- | ------------ | ----- |
| Auto → Manual (first fan) | ~5-6.5s | Includes `Ftst=1` unlock + mode retry loop |
| Auto → Manual (subsequent fan) | ~20ms | `Ftst` already set, just set mode |
| Manual → Manual (RPM change) | ~20ms | No mode change needed |
| Manual → Auto (not last) | ~20ms | Just clear mode, keep `Ftst=1` |
| Manual → Auto (last fan) | ~20ms | Triggers `Ftst=0` and daemon reclaim |

#### RPM Ramp Timing

| RPM Delta | Time to Stable | Notes |
| --------- | -------------- | ----- |
| 0 → 5000 | ~4s | Initial spin-up from stopped |
| 5000 → 7000 | ~4s | Within operating range |
| 7000 → 0 | ~1s | Spin-down is faster than spin-up |
| 8500 → 0 | ~1s | High RPM to stop |

#### State Transition Table

Each row shows a tested transition with measured results.

**Legend:** `F0`/`F1` = Fan 0/1, `A` = Auto, `M` = Manual, `@RPM` = actual RPM

| From State | Action | To State | Cmd (ms) | Stable (ms) | Side Effects |
| ---------- | ------ | -------- | -------- | ----------- | ------------ |
| F0: A@0, F1: A@0 | set 0 5000 | F0: M@5000, F1: A@2500 | 5252 | 8000 | F1 wakes to auto min |
| F0: M@5000, F1: A@2500 | set 0 7000 | F0: M@7000, F1: A@2500 | 22 | 4500 | - |
| F0: M@7000, F1: A@2500 | auto 0 | F0: A@0, F1: A@0 | 25 | 4500 | System mode restored |
| F0: A@0, F1: A@0 | set 0 10000 | F0: M@8560, F1: A@2500 | 5085 | 8000 | Clamped at hw max ~8560 |
| F0: M@8560, F1: A@2500 | set 0 0 | F0: M@0, F1: A@2500 | 22 | 1000 | Fan stops completely |
| F0: A@0, F1: A@0 | set 0 1000 | F0: M@1000, F1: A@2500 | 6657 | 9000 | Below "min" works |
| F0: M@1000, F1: A@2500 | set 1 6000 | F0: M@1000, F1: M@6000 | 21 | 5000 | Both fans independent |

#### State Diagram

```text
                              ┌─────────────────────────────────┐
                              │         SYSTEM IDLE             │
                              │   F0: Auto @ 0, F1: Auto @ 0    │
                              │   Ftst=0, thermalmonitord ctrl  │
                              └─────────────┬───────────────────┘
                                            │
                          set fan N to RPM  │  (~5-6s unlock)
                                            ▼
                              ┌─────────────────────────────────┐
                              │       DIAGNOSTIC MODE           │
                              │   Ftst=1, partial manual ctrl   │
                              │   Other fans wake to auto min   │
                              └─────────────┬───────────────────┘
                                            │
              ┌─────────────────────────────┼─────────────────────────────┐
              │                             │                             │
              ▼                             ▼                             ▼
    ┌─────────────────┐         ┌─────────────────────┐       ┌─────────────────┐
    │  ONE FAN MANUAL │         │  BOTH FANS MANUAL   │       │   RPM CHANGE    │
    │  F0: M, F1: A   │◀───────▶│  F0: M, F1: M       │──────▶│   (~20ms cmd)   │
    │  (~2500 auto)   │ set 1   │  Independent ctrl   │       │   ~4s to stable │
    └────────┬────────┘         └──────────┬──────────┘       └─────────────────┘
             │                             │
             │ auto 0 (last)               │ auto N (not last)
             │ (~20ms + 4-5s reclaim)      │ (~20ms)
             ▼                             ▼
    ┌─────────────────┐         ┌─────────────────────┐
    │  SYSTEM IDLE    │         │  PARTIAL AUTO       │
    │  Ftst=0         │◀────────│  Ftst=1 maintained  │
    │  F0: A@0, F1:A@0│         │  Other fan: Manual  │
    └─────────────────┘         └─────────────────────┘
```

#### Edge Case Behavior

| Hardware | Requested | Reported Limits | Actual Result | Notes |
| -------- | --------- | --------------- | ------------- | ----- |
| M4 Max | 0 RPM | min=2317 | 0 RPM | Fan stops completely |
| M4 Max | 1000 RPM | min=2317 | ~1000 RPM | Below "min" works |
| M4 Max | 10000 RPM | max=7826 | ~8560 RPM | Hardware spins above reported max |
| M5 Max | 0 RPM | min=2317 | 2317 RPM | Firmware clamps below-min up to min |
| M5 Max | 1000 RPM | min=2317 | 2317 RPM | Firmware clamps below-min up to min |
| M5 Max | 10000 RPM | max=7826 | ~9600 RPM | Target stays at 10000, fan spins to physical max |

**Key Observations:**

- The reported min/max values are thermal management thresholds, not hardware limits.
- On M4 Max, hardware can exceed reported max (~8560 actual vs 7826 reported) and can go below reported min (1000 actual vs 2317 reported).
- On M5 Max, hardware can exceed reported max (target 10000 accepted, fan spins to ~9600 RPM). Below-min targets are clamped up to the reported min.
- Setting 0 RPM in manual mode stops the fan completely on M4 Max. On M5 Max the firmware clamps the target to the reported min instead.

### System Mode and 0 RPM

When `Ftst=0` and `thermalmonitord` regains control:

- Fan mode transitions to 3 (system mode)
- Fans can spin down to **0 RPM** if thermal conditions allow
- This is the only way to achieve true idle (0 RPM) under normal operation
- Manual mode with target 0 also stops fans, but keeps `Ftst=1` active

### Daemon Reclaim Behavior

Decompiled code analysis reveals `thermalmonitord`'s polling characteristics:

- **Default Polling**: Approximately 4000ms (4 seconds) during idle
- **Fast Mode**: Under thermal load, polling reduces to approximately 250ms
- **Reclaim Frequency**: The daemon will reclaim control if `Ftst` is not set

Implementations requiring persistent manual control must maintain `Ftst=1` state.

## Quick Start

### Prerequisites

> **⚠️ Paid Apple Developer Account Required**
> A paid Apple Developer Program membership is required to obtain a Developer ID certificate for code signing the privileged helper daemon. Free accounts and self-signed certificates are not supported. This is a hard requirement — without it, the helper daemon cannot be installed.

- Xcode Command Line Tools: `xcode-select --install`
- Valid Apple Developer ID certificate for code signing.
- Your Apple Team ID (find at <https://developer.apple.com/account>).

### Configuration

Copy the example config and customize with your credentials:

```bash
cp Config/local.xcconfig.example Config/local.xcconfig
# Edit Config/local.xcconfig with your values:
#   CODE_SIGN_IDENTITY - Your Developer ID certificate
#   DEVELOPMENT_TEAM - Your Apple Team ID
#   BUNDLE_ID_PREFIX - Your bundle identifier prefix (e.g., com.yourname)
#   HELPER_BUNDLE_ID - Your helper bundle ID (e.g., com.yourname.smcfanhelper)
#   APP_BUNDLE_ID - Your app bundle ID (e.g., com.yourname.SMCFanHelper)
```

Find your certificate with: `security find-identity -v -p codesigning`
Find your Team ID at: <https://developer.apple.com/account>

**Note:** You MUST use your own unique bundle identifier prefix. The helper daemon is installed system-wide and will conflict if multiple users use the same ID.

### Build

Production build (with code signing):

```bash
make all
```

Development build (libraries only, no code signing needed):

```bash
swift build
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

```bash
make uninstall-helper
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

## Further Testing & Research

The following claims require additional verification, and the methodologies used here could reveal other SMC-controllable parameters.

### Hardware Compatibility

| Hardware | Status | Notes |
| -------- | ------ | ----- |
| M1 | **Partial** | Direct mode writes observed without `Ftst` unlock. |
| M2 | **Untested** | Expected to be consistent with M1 or M3/M4. |
| M3 / M4 Max | **Tested** | Mode key `F%dMd` (uppercase). `Ftst` present. Unlock poll sequence required. |
| M5 Max (Mac17,7) | **Tested** | Mode key `F%dmd` (lowercase). `Ftst` absent. Direct mode writes without unlock. Firmware clamps below-min targets to reported min (2317). Above-max targets are NOT clamped (10000 requested, fan spins to physical ~9600 RPM). Auto mode target is min RPM, not 0. |
| M5 / M5 Pro | **Untested** | Expected to match M5 Max behavior. |
| T2 (Intel) | **Untested** | Mode 2 behavior referenced in prior work but not verified. |
| Mac Studio / Mac Pro | **Untested** | Multi-fan behavior on desktop hardware. |

### Inferred Behaviors

| Item | Status | Evidence |
| ---- | ------ | -------- |
| Firmware fallback on daemon kill | **Not verified** | Inferred from `_claimSystemShutdownEvents` and `sysState.ShutdownSystem` in decompiled `AppleSMC`. Not tested by killing `thermalmonitord` under thermal load. |
| Sleep/wake `Ftst` reset | **Inferred** | Decompiled sleep handler analysis suggests firmware resets `Ftst`, not the daemon. Runtime testing confirms control loss on wake, but firmware-level reset not directly observed. |
| Polling intervals (4000ms/250ms) | **Inferred** | Values extracted from decompiled `thermalmonitord`. Actual timing may vary by macOS version or hardware. |
| M3/M4 thermal controller changes | **Partial** | `updateCPUFastDieTargetPMP` flag identified, but behavioral differences not fully characterized. |
| Mode 0 + `Ftst=1` reclaim behavior | **Not verified** | When a fan returns to mode 0 (mode key set to `0`, `F%dTg=0`) but `Ftst` remains set, `thermalmonitord` is expected to be unable to reclaim to mode 3. Decompiled code shows reclaim suppression is tied to `Ftst` state, not fan mode, but this specific scenario has not been experimentally tested. |
| Mode 0 "minimum RPM" meaning | **Not verified** | Mode 0 is described as "target defaults to minimum RPM" in the mode table, but it is unconfirmed whether that minimum corresponds to the `F%dMn` key value or some other firmware-determined floor. |
| Mode 0 thermal ramping | **Not verified** | Unknown whether firmware-level mode 0 performs its own thermal ramping independent of `thermalmonitord`, or if fans simply hold at the default minimum. Only mode 3 has been observed to allow 0 RPM idle. |

### Alternative Control Mechanisms

Decompiled code analysis has identified potential alternative approaches that may provide cleaner or more persistent control than the `Ftst` unlock mechanism:

| Approach | Status | Notes |
| -------- | ------ | ----- |
| Plist-based thermal targets | **Untested** | `thermalmonitord` reads `/Library/Preferences/SystemConfiguration/com.apple.cltm.plist` for `LifetimeServoDieTempTarget`. Setting a low temperature may cause fans to maximize. Would survive reboots. |
| Direct IOKit property writes | **Untested** | Properties like `LifetimeServoDieTemperatureTargetPropertyKey` (M1/M2) and `LifetimeServoFastDieTemperatureTarget` (M3/M4) written to `AppleCLPC` or `AppleDieTempController`. May communicate directly with hardware controllers. |
| Alternative diagnostic keys | **Partial** | `TG0B`, `TG0V`, `zETM`, `zEAR`, `TGraph` identified but not tested for fan control. `Ftst` appears to be the primary diagnostic override. |

### Future Research Directions

The same research methodologies could reveal other SMC-controllable parameters:

| Area | Potential |
| ---- | --------- |
| Power Management | CPU/GPU power limits, TDP controls |
| Thermal Sensors | Access to temperature sensors beyond standard APIs |
| Performance States | Direct control over P-states, frequency scaling |
| Battery Management | Charge limits, health parameters |
| System Telemetry | Undocumented sensor data |

### Edge Cases

| Item | Status | Notes |
| ---- | ------ | ----- |
| `0x87` error on `F0Tg` writes | **Observed** | Value sometimes applied despite error response. Root cause unclear. |
| Boot arguments (`smc-debug`, `smc-logsize`) | **Untested** | Identified in decompiled code but not tested for output |
| Helper crash with `Ftst=1` active | **Untested** | Potential thermal management gap if helper crashes without resetting `Ftst` |
| Fan coupling on M3/M4 | **Partial** | Community reports suggest synchronized fan behavior on some models. Not consistently reproduced. |

## Takeaways

This section offers conjectures about *why* Apple designed the thermal management system this way, based on the observed behaviors.

### Why is Manual Control Blocked by Default?

**System Safety**: Apple likely assumes users cannot be trusted to manage thermals correctly. Setting fans too low under load risks thermal damage; setting them too high constantly causes unnecessary wear and noise. By enforcing Mode 3 (System Mode), the system guarantees safe operation regardless of user actions.

**Liability**: Making manual control difficult creates a clear boundary. If you bypass the daemon using `Ftst`, you're explicitly entering "diagnostic mode" which is territory Apple never intended for end users. This shields Apple from warranty claims related to thermal damage.

### Why Does the Diagnostic Flag (`Ftst`) Exist at All?

**Manufacturing/QA**: Apple's engineers and manufacturing lines need to verify fan hardware, test thermal behavior, and diagnose issues. The `Ftst` flag is an escape hatch for these purposes.

**Firmware Fallback**: The `RTKit` firmware layer almost certainly has independent thermal protection (emergency throttling, shutdown) that operates *regardless* of `Ftst` state. This is why Apple can afford to expose a diagnostic override: the hardware can still save itself from catastrophic failure even if `thermalmonitord` is bypassed.

### Why Does Sleep/Wake Reset `Ftst`?

**Unknown State**: After wake, the system doesn't know the thermal context (lid closed? docked? external display?). Resetting to system control is the safe default. This also prevents a forgotten manual override from persisting across sessions.

### Why Aggressive Daemon Polling (250ms Under Load)?

**Crash Recovery**: If a controlling app crashes while `Ftst=1`, the system needs to recover quickly. The 250ms polling under thermal load ensures the daemon can reclaim control before temperatures become dangerous.

**Thermal Responsiveness**: Under high load, thermal conditions change rapidly. Faster polling allows the system to respond to sudden temperature spikes, even during mode transitions.

### Why Are Min/Max Values "Guidelines" Not Limits?

**Headroom for the System**: The reported min/max values appear to be *thermal management thresholds*, not hardware limits. The system reserves the ability to push fans beyond reported max (~8560 vs 7826 reported) for emergency cooling, and below reported min for silence during idle.

**User Safety vs. System Flexibility**: Users are given "safe" guidelines, while the system retains full range for its own use.

### Why Not Block `Ftst` Entirely?

Apple could lock down the `Ftst` flag at the kernel or firmware level and require an Apple-signed factory tool, validate entitlements, or simply not expose it to userspace at all. They don't, which suggests:

**Cost vs. Benefit**: Implementing kernel-level validation for a diagnostic flag adds complexity. The firmware fallback (independent thermal protection) already prevents catastrophic outcomes. The effort to lock it down may not be worth it when the risk is manageable.

**Flexibility for Edge Cases**: Developers, researchers, and power users occasionally have legitimate needs (thermal testing, custom cooling solutions, accessibility). A hard block would force workarounds or jailbreaks. The current "difficult but not impossible" approach may be intentional.

**Legacy Compatibility**: The SMC interface predates Apple Silicon. Adding entitlement checks could break existing internal tools. Notably, Apple only further restricted/obscured *writes* on Apple Silicon while reads remain open. This asymmetry hints that monitoring/diagnostic tools (read-only) matter more for backwards compatibility than control tools (read-write).

### Why Require Developer ID Signing?

**Gatekeeping**: By requiring a paid Developer Program membership for `SMJobBless`, Apple limits who can install privileged helpers. This isn't purely technical since self-signed certificates could theoretically work. It's a policy decision to keep low-level hardware access out of reach for casual users.

## References

[^1]: [Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html) - `NSProcessInfo.thermalState` API
[^2]: [IOKit Power Management Release Notes](https://developer.apple.com/library/archive/releasenotes/Darwin/RN-IOKitPowerManagment/index.html) - IOKit power management and notification APIs
[^3]: [Apple Platform Security - Boot Modes](https://support.apple.com/guide/security/sec10869885b) - Firmware security architecture
[^4]: [SMJobBless](https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:)) - Privileged helper installation
[^5]: [Apple SMC Data Types](https://cbosoft.github.io/blog/2020/07/17/apple-smc/) - `fpe2` format encoding
[^6]: [Asahi Linux SMC Documentation](https://asahilinux.org/docs/hw/soc/smc/) - Apple Silicon SMC key formats
[^7]: [SMC Sensor Keys Reference](https://www.marukka.ch/mac/mac-smc-sensor-keys) - Comprehensive SMC key catalog
[^8]: [smcFanControl Repository](https://github.com/hholtmann/smcFanControl) - Open-source fan control tool
[^9]: [Linux Kernel applesmc Driver](https://github.com/torvalds/linux/blob/master/drivers/hwmon/applesmc.c) - Intel Mac SMC driver; authoritative source for legacy SMC key schema
[^10]: [Thermals and macOS - Dave MacLachlan](https://dmaclach.medium.com/thermals-and-macos-c0db81062889) - Thermal monitoring APIs and `thermald`/`thermalmonitord` behavior on macOS
[^11]: Jonathan Levin, ["Mac OS X and iOS Internals, Volume I: User Mode"](http://www.newosxbook.com) (ISBN: 099105556X) - System daemons and thermal management architecture
[^12]: [Keep your Mac laptop within acceptable operating temperatures](https://support.apple.com/en-us/102336) - Mac thermal management and fan behavior
[^13]: [IOKit Fundamentals](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/IOKitFundamentals/Introduction/Introduction.html) - Apple's device driver and hardware access framework
[^14]: [Linux Kernel macsmc-hwmon Driver](https://github.com/torvalds/linux/blob/master/drivers/hwmon/macsmc-hwmon.c) - Apple Silicon SMC hwmon driver (Asahi Linux); provides fan control on Linux via hwmon interfaces
[^15]: [Asahi Linux Progress Report: Linux 6.18](https://asahilinux.org/2025/12/progress-report-6-18/) - Documents upstreaming of SMC hwmon driver to mainline Linux
[^16]: [VirtualSMC SDK `AppleSmc.h`](https://github.com/acidanthera/VirtualSMC/blob/master/VirtualSMCSDK/AppleSmc.h) - SMC result codes, commands, and protocol constants derived from reverse engineering Apple's SMC
[^17]: [SMCKit (beltex)](https://github.com/beltex/SMCKit) - Swift library for reading SMC sensor data; documents read operations without root, writes require root
[^18]: [smc-fuzzer (acidanthera)](https://github.com/acidanthera/VirtualSMC/blob/master/Tools/smc-fuzzer/README.md) - SMC testing tool; demonstrates read/write privilege asymmetry ("no value should be writable as a non-privileged user")
[^19]: [Stats (exelban)](https://github.com/exelban/stats) - macOS system monitor; reads SMC sensor data from unprivileged app process, privileged helper used exclusively for fan control writes
