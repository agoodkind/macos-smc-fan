# SMC Fan Control Research for Apple Silicon

[Swift](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml)

## Motivation

Prior to this research, no public documentation existed for manual fan **control** on Apple Silicon **within macOS**. While reading sensor data was documented [^6][^14], and the Asahi Linux project implemented fan control for Linux on Apple Silicon [^14][^15], no prior work documented how to achieve this on macOS. On macOS, Apple's `thermalmonitord` daemon actively blocks direct SMC writes.

The Asahi Linux kernel driver (`macsmc-hwmon`) provides fan control via standard `hwmon` interfaces when running Linux, using an "unsafe" module parameter (`fan_control=1`) [^14][^15]. That path uses kernel-level access without a `thermalmonitord` equivalent blocking writes. On macOS, the challenge appears to be different: `thermalmonitord` enforces "System Mode" (mode 3), and firmware may reject manual mode changes unless the hardware accepts direct mode or a diagnostic unlock sequence is applied.

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

## Quick Start

### Prerequisites

> **⚠️ Paid Apple Developer Account Required**
> A paid Apple Developer Program membership is required to obtain a Developer ID certificate for code signing the privileged helper daemon. Free accounts and self-signed certificates are not supported. This is a hard requirement — without it, the helper daemon cannot be installed.

- Xcode Command Line Tools: `xcode-select --install`
- Valid Apple Developer ID certificate for code signing.
- Your Apple Team ID (find at [https://developer.apple.com/account](https://developer.apple.com/account)).

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
Find your Team ID at: [https://developer.apple.com/account](https://developer.apple.com/account)

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

# Return fan to automatic control
./Products/smcfan auto 0        # Return fan 0 to automatic control
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

## Documentation

- Research narrative: [`docs/research.md`](docs/research.md). Methodology, background, research findings, technical details, fan control behavior, further testing notes, and takeaways live here.
- Currently observed test results: [`docs/testing.md`](docs/testing.md). Updated as new runs are recorded.
- Integration test fixtures: [`Tests/IntegrationTests/Fixtures`](Tests/IntegrationTests/Fixtures), consumed by [`Tests/IntegrationTests/HardwareExpectations.swift`](Tests/IntegrationTests/HardwareExpectations.swift).

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
