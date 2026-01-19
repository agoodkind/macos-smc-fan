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
SOURCES_DIR = Sources
INCLUDE_DIR = Include
TEMPLATES_DIR = templates
GENERATED_DIR = generated
BUILD_DIR = build
APP_DIR = $(BUILD_DIR)/SMCFanHelper.app
APP_CONTENTS = $(APP_DIR)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Library/LaunchServices

# Compiler flags
CC = clang
SWIFT = swiftc
CFLAGS = -Wall -Werror -O2 -I$(SOURCES_DIR)/libsmc
SWIFTFLAGS = -O -parse-as-library -import-objc-header $(INCLUDE_DIR)/SMCFan-Bridging-Header.h -I$(SOURCES_DIR)/libsmc -I$(GENERATED_DIR)
LDFLAGS_COMMON = -framework Foundation
LDFLAGS_IOKIT = $(LDFLAGS_COMMON) -framework IOKit -framework CoreFoundation
LDFLAGS_XPC = $(LDFLAGS_COMMON) -framework Foundation

# Targets
.PHONY: all clean install test test-install test-cli test-unlock

all: $(BUILD_DIR)/smcfan $(APP_CONTENTS)/Info.plist $(APP_DIR)/Contents/MacOS/SMCFanInstaller $(APP_RESOURCES)/$(HELPER_ID)

# Build SMC library
$(BUILD_DIR)/smc.o: $(SOURCES_DIR)/libsmc/smc.c $(SOURCES_DIR)/libsmc/smc.h
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $(SOURCES_DIR)/libsmc/smc.c -o $@

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
$(APP_RESOURCES)/$(HELPER_ID): $(SOURCES_DIR)/smcfanhelper/main.swift $(SOURCES_DIR)/common/SMCProtocol.swift $(SOURCES_DIR)/libsmc/smc.h $(BUILD_DIR)/smc.o $(GENERATED_DIR)/smcfan_config.h $(GENERATED_DIR)/helper-info.plist $(GENERATED_DIR)/helper-launchd.plist $(INCLUDE_DIR)/SMCFan-Bridging-Header.h
	@mkdir -p $(APP_RESOURCES)
	$(SWIFT) $(SWIFTFLAGS) -o $@ $(SOURCES_DIR)/common/SMCProtocol.swift $(SOURCES_DIR)/smcfanhelper/main.swift $(BUILD_DIR)/smc.o $(LDFLAGS_IOKIT) \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(GENERATED_DIR)/helper-info.plist \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist -Xlinker $(GENERATED_DIR)/helper-launchd.plist
	chmod +x "$@"
	xattr -cr "$(APP_DIR)"
	codesign -s "$(CERT_ID)" -f --entitlements entitlements.plist --options runtime --timestamp "$@"
	cp $(GENERATED_DIR)/helper-launchd.plist "$(APP_RESOURCES)/$(HELPER_ID).plist"

# Build installer app
$(APP_DIR)/Contents/MacOS/SMCFanInstaller: $(SOURCES_DIR)/installer/main.swift $(GENERATED_DIR)/smcfan_config.h $(INCLUDE_DIR)/SMCFan-Bridging-Header.h
	@mkdir -p $(APP_MACOS)
	$(SWIFT) $(SWIFTFLAGS) -o $@ $(SOURCES_DIR)/installer/main.swift $(LDFLAGS_COMMON) -framework Security -framework ServiceManagement
	@touch "$@"
	xattr -cr "$(APP_DIR)"
	xattr -cr "$@"
	codesign -s "$(CERT_ID)" -f --entitlements entitlements.plist --identifier "$(INSTALLER_ID)" --timestamp "$@"

# Copy app Info.plist
$(APP_CONTENTS)/Info.plist: SMCFanHelper.app/Contents/Info.plist
	@mkdir -p $(APP_CONTENTS)
	cp "$<" "$@"
	xattr -cr "$@"

# Build CLI tool
$(BUILD_DIR)/smcfan: $(SOURCES_DIR)/smcfan/main.swift $(SOURCES_DIR)/common/SMCProtocol.swift $(GENERATED_DIR)/smcfan_config.h $(INCLUDE_DIR)/SMCFan-Bridging-Header.h
	@mkdir -p $(BUILD_DIR)
	$(SWIFT) $(SWIFTFLAGS) -o $@ $(SOURCES_DIR)/common/SMCProtocol.swift $(SOURCES_DIR)/smcfan/main.swift $(LDFLAGS_XPC)
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

# Build mode 3 unlock test (if test file exists in research/)
ifneq (,$(wildcard research/test_mode3_unlock.m))
$(BUILD_DIR)/test_mode3_unlock: research/test_mode3_unlock.m $(BUILD_DIR)/smc.o
	$(CC) $(CFLAGS) -x objective-c -fobjc-arc -o $@ research/test_mode3_unlock.m $(BUILD_DIR)/smc.o $(LDFLAGS_IOKIT)
endif

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