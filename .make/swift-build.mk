.PHONY: build deploy install run generate clean

# swift-mk owns build-time code signing. Before any xcodebuild runs, ask the
# swift-mk binary for the signing xcconfig (built from DEVELOPMENT_TEAM /
# CODE_SIGN_IDENTITY / CODE_SIGN_STYLE) and export XCODE_XCCONFIG_FILE so it wins
# over every target's settings, including Tuist's per-target CODE_SIGN_IDENTITY =
# - default. It prints nothing when no signing values are set, so an unsigned
# build still works and nothing is forced. A consumer that already set
# XCODE_XCCONFIG_FILE is left untouched with a warning rather than clobbered. The
# prelude runs in the same shell as the build command so the export reaches it.
# The signing inputs are passed inline so swift-mk sees them whether they arrive
# as make variables (a -included local.xcconfig) or as the environment (CI); make
# expands an undefined variable to empty, which yields no override. SWIFT_MK_SIGN_*
# names from the real environment still win inside the binary.
SWIFT_MK_SIGNING_PRELUDE = xcc=""; if [ -n "$(strip $(SWIFT_MK_BIN))" ] && [ -x "$(SWIFT_MK_BIN)" ]; then xcc="$$(DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)" "$(SWIFT_MK_BIN)" signing-xcconfig 2>/dev/null || true)"; fi; if [ -n "$$xcc" ]; then if [ -n "$${XCODE_XCCONFIG_FILE:-}" ]; then echo "swift-build.mk: XCODE_XCCONFIG_FILE already set ($${XCODE_XCCONFIG_FILE}); leaving it, not applying swift-mk signing" >&2; else export XCODE_XCCONFIG_FILE="$$xcc"; fi; fi;

build: build-check
	@$(SWIFT_MK_SIGNING_PRELUDE) \
		$(if $(strip $(SWIFT_GENERATE_CMD)),$(SWIFT_GENERATE_CMD);,) \
		$(if $(strip $(SWIFT_BUILD_CMD)),$(SWIFT_BUILD_CMD),{ echo "swift-build.mk: SWIFT_BUILD_CMD is not set" >&2; exit 1; })

# Consumers that define their own `run` set SWIFT_MK_OWN_RUN := 1 before include,
# so this default does not collide and Make does not warn about overriding it.
ifeq ($(strip $(SWIFT_MK_OWN_RUN)),)
run: build
ifeq ($(strip $(SWIFT_RUN_CMD)),)
	@echo "swift-build.mk: SWIFT_RUN_CMD is not set"; exit 1
else
	@$(SWIFT_RUN_CMD)
endif
endif

generate:
ifeq ($(strip $(SWIFT_GENERATE_CMD)),)
	@echo "generate: no generate command configured"; exit 0
else
	@$(SWIFT_GENERATE_CMD)
endif

deploy: build
ifeq ($(strip $(SWIFT_DEPLOY_CMD)),)
	@echo "swift-build.mk: SWIFT_DEPLOY_CMD is not set"; exit 1
else
	@$(SWIFT_MK_SIGNING_PRELUDE) $(SWIFT_DEPLOY_CMD)
endif

install: deploy

clean:
ifneq ($(strip $(SWIFT_CLEAN_CMD)),)
	@$(SWIFT_CLEAN_CMD)
endif
