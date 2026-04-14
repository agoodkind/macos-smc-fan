-include Config/local.xcconfig

CONFIGURATION = Release
BUILD_DIR = build
PRODUCTS_DIR = Products

.PHONY: all clean install uninstall-helper generate-project test format

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
	@echo "Helper uninstalled."

test:
	swift test

format:
	swift-format format --in-place --recursive Sources/

clean:
	rm -rf $(BUILD_DIR) $(PRODUCTS_DIR) SMCFanApp.xcodeproj
