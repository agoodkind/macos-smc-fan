# SMJobBless SMC Fan Control Build System

# Include local configuration (copy config.mk.example to config.mk)
-include config.mk

# Validate required configuration
ifndef CERT_ID
$(error CERT_ID not set. Copy config.mk.example to config.mk and configure your values)
endif
ifndef HELPER_ID
$(error HELPER_ID not set. Copy config.mk.example to config.mk and configure your values)
endif

# Directories
SRC_DIR = src
TEMPLATES_DIR = templates
GENERATED_DIR = generated
BUILD_DIR = build
APP_DIR = $(BUILD_DIR)/SMCFanHelper.app
APP_CONTENTS = $(APP_DIR)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Library/LaunchServices

# Compiler flags
CC = clang
OBJC = clang
CFLAGS = -Wall -Werror -O2
OBJCFLAGS = -fobjc-arc -Wall -Werror -O2
LDFLAGS_COMMON = -framework Foundation
LDFLAGS_IOKIT = $(LDFLAGS_COMMON) -framework IOKit -framework CoreFoundation
LDFLAGS_XPC = $(LDFLAGS_COMMON) -framework Foundation

# Targets
.PHONY: all clean install test test-install test-cli test-unlock

all: $(BUILD_DIR)/smcfan $(APP_CONTENTS)/Info.plist $(APP_DIR)/Contents/MacOS/SMCFanInstaller $(APP_RESOURCES)/$(HELPER_ID)

# Build shared SMC library
$(BUILD_DIR)/smcfan_common.o: $(SRC_DIR)/smcfan_common.c $(SRC_DIR)/smcfan_common.h
	@mkdir -p $(BUILD_DIR)
	$(OBJC) $(OBJCFLAGS) -x objective-c -c $(SRC_DIR)/smcfan_common.c -o $@

# Generate configuration header from template
$(GENERATED_DIR)/smcfan_config.h: $(TEMPLATES_DIR)/smcfan_config.h.template config.mk
	@mkdir -p $(GENERATED_DIR)
	sed -e 's|@@HELPER_ID@@|$(HELPER_ID)|g' \
	    -e 's|@@INSTALLER_ID@@|$(INSTALLER_ID)|g' \
	    $(TEMPLATES_DIR)/smcfan_config.h.template > $@

# Generate plist files from templates
$(GENERATED_DIR)/helper-info.plist: $(TEMPLATES_DIR)/helper-info.plist.template config.mk
	@mkdir -p $(GENERATED_DIR)
	sed -e 's|@@HELPER_ID@@|$(HELPER_ID)|g' \
	    -e 's|@@INSTALLER_ID@@|$(INSTALLER_ID)|g' \
	    -e 's|@@TEAM_ID@@|$(TEAM_ID)|g' \
	    $(TEMPLATES_DIR)/helper-info.plist.template > $@

$(GENERATED_DIR)/helper-launchd.plist: $(TEMPLATES_DIR)/helper-launchd.plist.template config.mk
	@mkdir -p $(GENERATED_DIR)
	sed -e 's|@@HELPER_ID@@|$(HELPER_ID)|g' \
	    $(TEMPLATES_DIR)/helper-launchd.plist.template > $@

# Build XPC helper daemon
$(BUILD_DIR)/smcfan_helper.o: $(SRC_DIR)/smcfan_helper.m $(SRC_DIR)/smcfan_common.h $(GENERATED_DIR)/smcfan_config.h
	@mkdir -p $(BUILD_DIR)
	$(OBJC) $(OBJCFLAGS) -c $(SRC_DIR)/smcfan_helper.m -o $@ -I$(SRC_DIR) -I$(GENERATED_DIR)

$(APP_RESOURCES)/$(HELPER_ID): $(BUILD_DIR)/smcfan_helper.o $(BUILD_DIR)/smcfan_common.o $(GENERATED_DIR)/helper-info.plist $(GENERATED_DIR)/helper-launchd.plist
	@mkdir -p $(APP_RESOURCES)
	$(OBJC) $(OBJCFLAGS) -o $@ $(BUILD_DIR)/smcfan_helper.o $(BUILD_DIR)/smcfan_common.o $(LDFLAGS_IOKIT) \
		-sectcreate __TEXT __info_plist $(GENERATED_DIR)/helper-info.plist \
		-sectcreate __TEXT __launchd_plist $(GENERATED_DIR)/helper-launchd.plist
	chmod +x "$@"
	xattr -cr "$(APP_DIR)"
	codesign -s "$(CERT_ID)" -f --entitlements entitlements.plist --options runtime --timestamp "$@"
	cp $(GENERATED_DIR)/helper-launchd.plist "$(APP_RESOURCES)/$(HELPER_ID).plist"

# Build installer app
$(BUILD_DIR)/installer.o: $(SRC_DIR)/installer.m $(GENERATED_DIR)/smcfan_config.h
	@mkdir -p $(BUILD_DIR)
	$(OBJC) $(OBJCFLAGS) -c $(SRC_DIR)/installer.m -o $@ -I$(GENERATED_DIR)

$(APP_DIR)/Contents/MacOS/SMCFanInstaller: $(BUILD_DIR)/installer.o
	@mkdir -p $(APP_MACOS)
	$(OBJC) $(OBJCFLAGS) -o $@ $(BUILD_DIR)/installer.o $(LDFLAGS_COMMON) -framework Security -framework ServiceManagement
	xattr -cr "$(APP_DIR)"
	xattr -cr "$@"
	codesign -s "$(CERT_ID)" -f --entitlements entitlements.plist --identifier "$(INSTALLER_ID)" --timestamp "$@"

# Copy app Info.plist
$(APP_CONTENTS)/Info.plist: SMCFanHelper.app/Contents/Info.plist
	@mkdir -p $(APP_CONTENTS)
	cp "$<" "$@"
	xattr -cr "$@"

# Build CLI tool
$(BUILD_DIR)/smcfan.o: $(SRC_DIR)/smcfan.m $(GENERATED_DIR)/smcfan_config.h
	@mkdir -p $(BUILD_DIR)
	$(OBJC) $(OBJCFLAGS) -c $(SRC_DIR)/smcfan.m -o $@ -I$(SRC_DIR) -I$(GENERATED_DIR)

$(BUILD_DIR)/smcfan: $(BUILD_DIR)/smcfan.o
	$(OBJC) $(OBJCFLAGS) -o $@ $(BUILD_DIR)/smcfan.o $(LDFLAGS_XPC)
	codesign -s "$(CERT_ID)" -f --entitlements entitlements.plist --identifier smcfan --timestamp "$@"

# Install the app (copies to /Applications)
install: $(APP_DIR)/Contents/MacOS/SMCFanInstaller $(APP_RESOURCES)/$(HELPER_ID) $(APP_CONTENTS)/Info.plist
	sudo cp -r "$(APP_DIR)" /Applications/
	sudo chown -R root:wheel /Applications/SMCFanHelper.app

# Test the installation (run the installer)
test-install:
	/Applications/SMCFanHelper.app/Contents/MacOS/SMCFanInstaller

# Test the CLI tool
test-cli: $(BUILD_DIR)/smcfan
	./$(BUILD_DIR)/smcfan list

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) $(GENERATED_DIR)

# Build mode 3 unlock test
$(BUILD_DIR)/test_mode3_unlock: test_mode3_unlock.m $(BUILD_DIR)/smcfan_common.o
	$(OBJC) $(OBJCFLAGS) -o $@ test_mode3_unlock.m $(BUILD_DIR)/smcfan_common.o $(LDFLAGS_IOKIT)

# Test mode 3 unlock with retry logic
test-unlock: $(BUILD_DIR)/test_mode3_unlock
	@echo "Running mode 3 unlock test..."
	@echo "Usage: ./build/test_mode3_unlock [interval_ms] [max_attempts] [fan_index]"
	sudo ./$(BUILD_DIR)/test_mode3_unlock 500 120 0

# Show help
help:
	@echo "SMJobBless SMC Fan Control Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all          - Build all components"
	@echo "  install      - Install app to /Applications"
	@echo "  test-install - Run the SMJobBless installer"
	@echo "  test-cli     - Test the CLI tool"
	@echo "  test-unlock  - Test mode 3 unlock with retry logic"
	@echo "  clean        - Remove build artifacts"
	@echo ""
	@echo "Files built:"
	@echo "  $(BUILD_DIR)/smcfan                          - CLI tool"
	@echo "  $(APP_DIR)/Contents/MacOS/SMCFanInstaller   - Installer app"
	@echo "  $(APP_RESOURCES)/$(HELPER_ID) - Helper daemon"
	@echo "  $(BUILD_DIR)/test_mode3_unlock              - Mode 3 unlock test"