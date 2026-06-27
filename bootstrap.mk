# bootstrap.mk fetches swift.mk into .make/ and includes it. swift.mk fetches its
# own helper scripts, the shared lint/format/periphery/osv configs, and the
# selected modules, so this stub is the only file a consumer commits and it
# rarely changes. Consumer Makefiles set their project commands and
# SWIFT_MK_MODULES, then include this file.

SWIFT_MK_DEV_DIR ?=
SWIFT_MK := .make/swift.mk
SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main

# Fetch a single file from the local swift-makefile checkout (SWIFT_MK_DEV_DIR) or
# GitHub. Used only to obtain swift.mk; swift.mk fetches everything else itself.
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

ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
$(if $(wildcard $(SWIFT_MK)),,$(error swift-makefile expected $(SWIFT_MK); rerun without SWIFT_MK_SKIP_FETCH))
else
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,swift.mk,$(SWIFT_MK)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch swift.mk))
endif

-include $(SWIFT_MK)
