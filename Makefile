-include Config/local.xcconfig

CONFIGURATION ?= Release
BUILD_DIR ?= build
PRODUCTS_DIR ?= Products

SMCD_BUNDLE_ID = io.goodkind.smcd

# swift-mk consumer wiring. swift-mk owns build-time code signing through its
# XCODE_XCCONFIG_FILE override, fed by CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM from
# Config/local.xcconfig, so neither project.yml nor this Makefile sets signing.
# Generation and the build route through the swift-mk `toolchain` chokepoint so no
# consumer file names xcodegen or xcodebuild directly. Deferred `=` because
# SWIFT_MK_BIN is set by swift.mk, included via bootstrap.mk below.
SWIFT_MK_MODULES := swift-build.mk
SWIFT_MK_OWN_RUN := 1
SWIFT_MK_DERIVED_DATA := $(BUILD_DIR)
SWIFT_GENERATE_CMD = "$(SWIFT_MK_BIN)" toolchain generate --generator xcodegen
SWIFT_BUILD_CMD := $(MAKE) SWIFT_MK_SKIP_FETCH=1 build-local
SWIFT_CLEAN_CMD := rm -rf $(BUILD_DIR) $(PRODUCTS_DIR) SMCFanApp.xcodeproj
SWIFT_TEST_CMD := swift test
SWIFT_DEPLOY_CMD := $(MAKE) SWIFT_MK_SKIP_FETCH=1 install-helper
# Logging enforcement is handled by swift-mk's stricter gates, so the hand-rolled
# log-audit target was removed rather than wired through SWIFT_LOG_AUDIT_CMD.
# Clean build so the dead-code gate reads a complete index.
SWIFT_DEADCODE_BUILD_CMD := rm -rf $(BUILD_DIR) && $(MAKE) SWIFT_MK_SKIP_FETCH=1 build-local

include bootstrap.mk

.PHONY: build-local generate-project install-helper uninstall-helper \
	test-integration format legacy-smcd-uninstall

# Kept as the lightweight xcodegen entry point that consumers building this helper
# directly depend on (e.g. macos-fan-curve's helper-artifacts), independent of the
# swift-mk `generate` target.
generate-project:
	"$(SWIFT_MK_BIN)" toolchain generate --generator xcodegen

# The Xcode app/helper build, routed through the swift-mk `toolchain` chokepoint so
# this file never names xcodebuild. Run by swift-mk's `build` after the signing
# prelude exports XCODE_XCCONFIG_FILE, so both schemes sign with the swift-mk identity.
build-local: generate
	"$(SWIFT_MK_BIN)" toolchain build --generator xcodegen \
		--project SMCFanApp.xcodeproj \
		--scheme SMCFanHelper \
		--configuration $(CONFIGURATION) \
		--derived-data-path $(BUILD_DIR) \
		ONLY_ACTIVE_ARCH=YES
	"$(SWIFT_MK_BIN)" toolchain build --generator xcodegen \
		--project SMCFanApp.xcodeproj \
		--scheme smcfan \
		--configuration $(CONFIGURATION) \
		--derived-data-path $(BUILD_DIR) \
		ONLY_ACTIVE_ARCH=YES
	@mkdir -p $(PRODUCTS_DIR)
	@cp -R "$(BUILD_DIR)/Build/Products/$(CONFIGURATION)/SMCFanHelper.app" "$(PRODUCTS_DIR)/"
	@cp "$(BUILD_DIR)/Build/Products/$(CONFIGURATION)/smcfan" "$(PRODUCTS_DIR)/"

# `make install` flows through swift-mk: install -> deploy -> build, then this.
install-helper: uninstall-helper
	@echo "Installing to /Applications..."
	sudo rm -rf /Applications/SMCFanHelper.app
	sudo cp -R "$(PRODUCTS_DIR)/SMCFanHelper.app" /Applications/
	sudo chown -R root:wheel /Applications/SMCFanHelper.app
	@echo "Registering helper..."
	/Applications/SMCFanHelper.app/Contents/MacOS/SMCFanInstaller
	@echo "Verifying..."
	@sudo launchctl list | grep $(HELPER_BUNDLE_ID) && echo "Helper registered." || echo "Warning: helper not found in launchctl."

uninstall-helper:
	@echo "Uninstalling helper..."
	-sudo launchctl bootout system/$(HELPER_BUNDLE_ID) || true
	-sudo sfltool resetbtm || true
	-sudo rm -f /Library/LaunchDaemons/$(HELPER_BUNDLE_ID).plist
	-sudo rm -f /Library/PrivilegedHelperTools/$(HELPER_BUNDLE_ID)
	-sudo rm -rf /Applications/SMCFanHelper.app
	-sudo rm -f /etc/newsyslog.d/smcfan.conf
	-sudo rm -rf /Library/Logs/smcfan
	@echo "Helper uninstalled."

XCTEST = $(shell xcrun --find xctest)
TEST_BUNDLE = .build/arm64-apple-macosx/debug/SMCFanPackageTests.xctest

test-integration: build
	swift build --build-tests
	sudo $(XCTEST) -XCTest IntegrationTests $(TEST_BUNDLE)

format:
	swift-format format --in-place --recursive Sources/

# Convenience for machines upgrading from the smcd era. Boots out the old
# LaunchAgent and removes its plist and binary. No op on clean installs.
legacy-smcd-uninstall:
	-@launchctl bootout "gui/$$(id -u)/$(SMCD_BUNDLE_ID)" 2>/dev/null || true
	-@rm -f "$(HOME)/Library/LaunchAgents/$(SMCD_BUNDLE_ID).plist"
	-@rm -f "$(HOME)/.local/bin/smcd"
	@echo "Legacy smcd agent removed."
