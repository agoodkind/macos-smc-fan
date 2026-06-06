# bootstrap.mk fetches swift.mk, shared configs, and selected modules into
# .make/ and then includes swift.mk. Consumer Makefiles set project commands
# and then include this file.

SWIFT_MK_DEV_DIR ?=
SWIFT_MK_MODULES ?=
SWIFT_MK := .make/swift.mk
SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main
SWIFT_MK_SWIFTLINT_CONFIG ?= .make/swiftlint.yml
SWIFT_MK_SWIFT_FORMAT_CONFIG ?= .make/swift-format.json
SWIFT_MK_PERIPHERY_CONFIG ?= .make/periphery.yml
SWIFT_MK_ALLOW_LOCAL_CONFIGS ?=

ifeq ($(strip $(SWIFT_MK_ALLOW_LOCAL_CONFIGS)),)
ifeq ($(MAKELEVEL),0)
ifneq ($(wildcard .swiftlint.yml),)
ifneq ($(abspath $(SWIFT_MK_SWIFTLINT_CONFIG)),$(abspath .swiftlint.yml))
$(warning swift-makefile: local .swiftlint.yml is ignored; shared SwiftLint config is $(SWIFT_MK_SWIFTLINT_CONFIG))
endif
endif
ifneq ($(wildcard .swift-format),)
ifneq ($(abspath $(SWIFT_MK_SWIFT_FORMAT_CONFIG)),$(abspath .swift-format))
$(warning swift-makefile: local .swift-format is ignored; shared swift-format config is $(SWIFT_MK_SWIFT_FORMAT_CONFIG))
endif
endif
ifneq ($(wildcard .periphery.yml),)
ifneq ($(abspath $(SWIFT_MK_PERIPHERY_CONFIG)),$(abspath .periphery.yml))
$(warning swift-makefile: local .periphery.yml is ignored; shared Periphery config is $(SWIFT_MK_PERIPHERY_CONFIG))
endif
endif
endif
endif

define _swift_mk_fetch
	tmp_file=$$(mktemp "$(2).tmp.XXXXXX") || exit 1; \
	if [ -n "$(SWIFT_MK_DEV_DIR)" ] && [ -f "$(SWIFT_MK_DEV_DIR)/$(1)" ]; then \
		cp "$(SWIFT_MK_DEV_DIR)/$(1)" "$$tmp_file" && [ -s "$$tmp_file" ] && mv "$$tmp_file" "$(2)"; \
	else \
		gh_path=$$(command -v gh || true); \
		if [ -n "$$gh_path" ] && gh api "repos/$(SWIFT_MK_API_REPO)/contents/$(1)?ref=$(SWIFT_MK_API_REF)" -H "Accept: application/vnd.github.raw" > "$$tmp_file" && [ -s "$$tmp_file" ]; then \
			mv "$$tmp_file" "$(2)"; \
		elif curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BASE_URL)/$(1)" -o "$$tmp_file" && [ -s "$$tmp_file" ]; then \
			mv "$$tmp_file" "$(2)"; \
		else \
			rm -f "$$tmp_file"; \
			printf '%s\n' "error: $(1) fetch failed. Run: gh auth login"; \
			exit 1; \
		fi; \
	fi
endef

SWIFT_MK_BOOTSTRAP_FETCHED := 1

define _swift_mk_require_fetched
$(if $(wildcard $(1)),,$(error swift-makefile expected $(1); rerun without SWIFT_MK_SKIP_FETCH))
endef

ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCH_CHECK := $(call _swift_mk_require_fetched,$(SWIFT_MK))
SWIFT_MK_FETCH_CHECK += $(call _swift_mk_require_fetched,$(SWIFT_MK_SWIFTLINT_CONFIG))
SWIFT_MK_FETCH_CHECK += $(call _swift_mk_require_fetched,$(SWIFT_MK_SWIFT_FORMAT_CONFIG))
SWIFT_MK_FETCH_CHECK += $(call _swift_mk_require_fetched,$(SWIFT_MK_PERIPHERY_CONFIG))
SWIFT_MK_FETCH_CHECK += $(foreach m,$(SWIFT_MK_MODULES),$(call _swift_mk_require_fetched,.make/$(m)))
else
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,swift.mk,$(SWIFT_MK)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch swift.mk))
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,.swiftlint.yml,$(SWIFT_MK_SWIFTLINT_CONFIG)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch .swiftlint.yml))
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,.swift-format,$(SWIFT_MK_SWIFT_FORMAT_CONFIG)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch .swift-format))
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,.periphery.yml,$(SWIFT_MK_PERIPHERY_CONFIG)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch .periphery.yml))
$(foreach m,$(SWIFT_MK_MODULES),$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,$(m),.make/$(m)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch $(m))))
endif

-include $(SWIFT_MK)
