-include Config/local.xcconfig

CONFIGURATION = Release
BUILD_DIR = build
PRODUCTS_DIR = Products

SMCD_BUNDLE_ID = io.goodkind.smcd

.PHONY: all clean install uninstall-helper generate-project test test-integration format log-audit \
	legacy-smcd-uninstall

generate-project:
	xcodegen generate

all: generate-project
	xcodebuild -project SMCFanApp.xcodeproj \
		-scheme SMCFanHelper \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(BUILD_DIR) \
		ONLY_ACTIVE_ARCH=YES \
		build
	xcodebuild -project SMCFanApp.xcodeproj \
		-scheme smcfan \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(BUILD_DIR) \
		ONLY_ACTIVE_ARCH=YES \
		build
	@mkdir -p $(PRODUCTS_DIR)
	@cp -R "$(BUILD_DIR)/Build/Products/$(CONFIGURATION)/SMCFanHelper.app" "$(PRODUCTS_DIR)/"
	@cp "$(BUILD_DIR)/Build/Products/$(CONFIGURATION)/smcfan" "$(PRODUCTS_DIR)/"

log-audit:
	@set -e; \
	echo "scanning for forbidden output calls..."; \
	! grep -rnE '(^|[^a-zA-Z_])(print|NSLog|debugPrint|dump)\(' Sources/ \
		--include='*.swift' --exclude-dir=AppLog --exclude='CLIOut.swift' \
		| grep -v 'CLIOut\.print\|CLIOut\.err' \
	&& echo "  output calls: OK"; \
	echo "scanning for direct Logger construction outside AppLog..."; \
	! grep -rn 'Logger(subsystem:' Sources/ \
		--include='*.swift' --exclude-dir=AppLog \
	&& echo "  Logger construction: OK"; \
	echo "scanning for swift-log import outside AppLog..."; \
	! grep -rn 'import Logging' Sources/ \
		--include='*.swift' --exclude-dir=AppLog \
	&& echo "  swift-log direct use: OK"; \
	echo "log-audit PASSED"

install: all uninstall-helper
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

test:
	swift test

XCTEST = $(shell xcrun --find xctest)
TEST_BUNDLE = .build/arm64-apple-macosx/debug/SMCFanPackageTests.xctest

test-integration: all
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

clean:
	rm -rf $(BUILD_DIR) $(PRODUCTS_DIR) SMCFanApp.xcodeproj
