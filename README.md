# SMC Fan Control Research for Apple Silicon

[Swift](https://github.com/agoodkind/macos-smc-fan/actions/workflows/swift.yml)

## Motivation

Prior to this research, no public documentation existed for manual fan **control** on Apple Silicon **within macOS**. While reading sensor data was documented in [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/) and the [macsmc-hwmon driver](https://github.com/torvalds/linux/blob/master/drivers/hwmon/macsmc-hwmon.c), and the Asahi Linux project implemented fan control for Linux on Apple Silicon ([macsmc-hwmon driver](https://github.com/torvalds/linux/blob/master/drivers/hwmon/macsmc-hwmon.c), [Asahi Linux progress report](https://asahilinux.org/2025/12/progress-report-6-18/)), no prior work documented how to achieve this on macOS. On macOS, Apple's `thermalmonitord` daemon actively blocks direct SMC writes.

The Asahi Linux kernel driver (`macsmc-hwmon`) provides fan control via standard `hwmon` interfaces when running Linux, using an "unsafe" module parameter (`fan_control=1`). That path uses kernel-level access without a `thermalmonitord` equivalent blocking writes. On macOS, the challenge appears to be different: `thermalmonitord` enforces "System Mode" (mode 3), and firmware may reject manual mode changes unless the hardware accepts direct mode or a diagnostic unlock sequence is applied.

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
> A paid Apple Developer Program membership is required to obtain a Developer ID certificate for code signing the privileged helper daemon. Free accounts and self-signed certificates are not supported. This is a hard requirement. Without it, the helper daemon cannot be installed.

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

The installer uses [`SMJobBless`](https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:)) to install a privileged helper daemon.

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
