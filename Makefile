-include Config/local.xcconfig

CONFIGURATION ?= Release
BUILD_DIR ?= build
PRODUCTS_DIR ?= Products

# Public identifier; Config/local.xcconfig (make-included above) may override.
HELPER_BUNDLE_ID ?= io.goodkind.smcfanhelper

# swift-mk consumer wiring. swift-mk owns build-time code signing through its
# XCODE_XCCONFIG_FILE override, fed by CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM from
# Config/local.xcconfig, so neither project.yml nor this Makefile sets signing.
# Generation and the build route through the swift-mk `toolchain` chokepoint so
# lower-level build drivers stay behind the engine. Deferred `=` because
# SWIFT_MK_BIN is set by swift.mk, included via bootstrap.mk below.
SWIFT_MK_MODULES := swift-build.mk swift-release.mk
SWIFT_MK_OWN_RUN := 1
SWIFT_MK_DERIVED_DATA := $(BUILD_DIR)
SMC_GENERATOR := xcodegen
SWIFT_GENERATE_CMD = "$(SWIFT_MK_BIN)" toolchain generate --generator $(SMC_GENERATOR)
SWIFT_BUILD_CMD := $(MAKE) SWIFT_MK_SKIP_FETCH=1 build-local
# Release artifacts for the shared _release.yml pipeline: the signed helper app
# zipped into dist/ for notarization. RELEASE_TAG arrives from release-meta.
SWIFT_MK_RELEASE_BUILD_CMD := $(MAKE) SWIFT_MK_SKIP_FETCH=1 build && ditto -c -k --keepParent Products/SMCFanHelper.app dist/SMCFanHelper-$$RELEASE_TAG.zip
SWIFT_CLEAN_CMD := rm -rf $(BUILD_DIR) $(PRODUCTS_DIR) SMCFanApp.xcodeproj
SWIFT_TEST_CMD = "$(SWIFT_MK_BIN)" toolchain swiftpm test
SWIFT_DEPLOY_CMD := $(MAKE) SWIFT_MK_SKIP_FETCH=1 install-helper
# Logging enforcement is handled by swift-mk's stricter gates, so the hand-rolled
# log-audit target was removed rather than wired through SWIFT_LOG_AUDIT_CMD.
# The engine derives and owns the dead-code coverage build from these normal Xcode
# inputs: it enumerates the (scheme, platform) matrix from the generated project and
# enforces every index-critical setting, so no bespoke coverage command is declared.
SWIFT_XCODE_PROJECT := SMCFanApp.xcodeproj
SWIFT_XCODE_GENERATOR := $(SMC_GENERATOR)
SWIFT_XCODE_COVERAGE_CONFIGURATION := $(CONFIGURATION)

include bootstrap.mk

.PHONY: build-local generate-project install-helper uninstall-helper \
	test-integration

# Kept as the lightweight xcodegen entry point that consumers building this helper
# directly depend on (e.g. macos-fan-curve's helper-artifacts), independent of the
# swift-mk `generate` target.
generate-project:
	"$(SWIFT_MK_BIN)" toolchain generate --generator $(SMC_GENERATOR)

# The Xcode app/helper build routes through the swift-mk `toolchain` chokepoint.
# Run by swift-mk's `build` after the signing prelude exports XCODE_XCCONFIG_FILE,
# so both schemes sign with the swift-mk identity.
build-local: generate
	"$(SWIFT_MK_BIN)" toolchain build --generator $(SMC_GENERATOR) \
		--project SMCFanApp.xcodeproj \
		--scheme SMCFanHelper \
		--configuration $(CONFIGURATION) \
		--derived-data-path $(BUILD_DIR) \
		ONLY_ACTIVE_ARCH=YES
	"$(SWIFT_MK_BIN)" toolchain build --generator $(SMC_GENERATOR) \
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
	"$(SWIFT_MK_BIN)" toolchain swiftpm build -- --build-tests
	sudo $(XCTEST) -XCTest IntegrationTests $(TEST_BUNDLE)
