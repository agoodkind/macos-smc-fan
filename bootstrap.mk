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
# GitHub. Used to obtain swift.mk; swift.mk fetches everything else itself.
define _swift_mk_fetch
	tmp_file=$$(mktemp "$(2).tmp.XXXXXX") || exit 1; \
	trap 'rm -f "$$tmp_file"' EXIT; \
	if [ -n "$(SWIFT_MK_DEV_DIR)" ] && [ -f "$(SWIFT_MK_DEV_DIR)/$(1)" ]; then \
		cp "$(SWIFT_MK_DEV_DIR)/$(1)" "$$tmp_file" && [ -s "$$tmp_file" ] && mv "$$tmp_file" "$(2)"; \
	else \
		gh_path=$$(command -v gh || true); \
		if [ -n "$$gh_path" ] && gh api "repos/$(SWIFT_MK_API_REPO)/contents/$(1)?ref=$(SWIFT_MK_API_REF)" -H "Accept: application/vnd.github.raw" > "$$tmp_file" && [ -s "$$tmp_file" ]; then \
			mv "$$tmp_file" "$(2)"; \
		elif curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BASE_URL)/$(1)" -o "$$tmp_file" && [ -s "$$tmp_file" ]; then \
			mv "$$tmp_file" "$(2)"; \
		else \
			printf '%s\n' "error: could not fetch $(1) (tried SWIFT_MK_DEV_DIR, gh api, then $(SWIFT_MK_BASE_URL)); check your network connection, and if gh is installed run 'gh auth status'" >&2; \
			exit 1; \
		fi; \
	fi
endef

# Print the trace header before any other work. This is a minimal self-contained
# core: adopt an inherited TRACEPARENT (any well-formed one, normalized to flags
# 01), then the canonical TRACE_ID/SPAN_ID pair, then the SWIFT_MK_TRACE_ID/
# SWIFT_MK_SPAN_ID aliases, or mint a fresh id, so the consumer bootstrap needs no
# fetch and works offline. The full trace logic (same precedence plus stricter
# W3C validation) lives once in scripts/swift-mk-trace.sh, which swift.mk runs for
# the engine build. Wrapped in a define so make treats the shell body literally,
# not as make comments/parens.
define swift_mk_trace_min
$(shell \
	log_dir=".make/logs"; mkdir -p "$$log_dir" || exit 1; \
	tp="$$TRACEPARENT"; trace=""; span=""; \
	rest=$${tp#00-}; \
	if [ "$$rest" != "$$tp" ]; then trace=$${rest%%-*}; tail=$${rest#*-}; span=$${tail%%-*}; fi; \
	is_id() { [ $${#1} -eq "$$2" ] && [ -z "`printf '%s' "$$1" | tr -d 0123456789abcdef`" ] && [ -n "`printf '%s' "$$1" | tr -d 0`" ]; }; \
	if ! is_id "$$trace" 32 || ! is_id "$$span" 16; then trace=""; span=""; fi; \
	if [ -z "$$trace" ] && is_id "$$TRACE_ID" 32 && is_id "$$SPAN_ID" 16; then trace="$$TRACE_ID"; span="$$SPAN_ID"; fi; \
	if [ -z "$$trace" ] && is_id "$$SWIFT_MK_TRACE_ID" 32 && is_id "$$SWIFT_MK_SPAN_ID" 16; then trace="$$SWIFT_MK_TRACE_ID"; span="$$SWIFT_MK_SPAN_ID"; fi; \
	if [ -z "$$trace" ]; then \
		trace=`od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]'`; \
		span=`od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]'`; \
	fi; \
	if ! is_id "$$trace" 32 || ! is_id "$$span" 16; then exit 0; fi; \
	tp="00-$$trace-$$span-01"; \
	printf '%s\n' "$$tp" > "$$log_dir/.traceparent" || exit 1; \
	prev=""; if [ -s "$$log_dir/.run" ]; then IFS= read -r prev < "$$log_dir/.run"; fi; \
	if [ "$$prev" != "$$trace" ]; then printf '%s\n' "$$trace" > "$$log_dir/.run"; \
		printf '🔎 logs=.make/logs trace_id=%s span_id=%s\n' "$$trace" "$$span" >&2; fi; \
	printf 'ok %s %s %s' "$$tp" "$$trace" "$$span")
endef

SWIFT_MK_TRACE_RESULT := $(call swift_mk_trace_min)
ifeq ($(word 1,$(SWIFT_MK_TRACE_RESULT)),ok)
TRACEPARENT := $(word 2,$(SWIFT_MK_TRACE_RESULT))
TRACE_ID := $(word 3,$(SWIFT_MK_TRACE_RESULT))
SPAN_ID := $(word 4,$(SWIFT_MK_TRACE_RESULT))
SWIFT_MK_TRACE_ID := $(TRACE_ID)
SWIFT_MK_SPAN_ID := $(SPAN_ID)
export TRACEPARENT TRACE_ID SPAN_ID SWIFT_MK_TRACE_ID SWIFT_MK_SPAN_ID
endif

# Clean-only fast path. When every requested goal is `clean`, skip fetching and
# including swift.mk (no network, no swift-mk build, no consumer dev tool) and run
# an engine-owned trivial clean. Any goal list that also names a build, lint, or
# test goal falls through to the full engine below, so the gates are never
# skipped. MAKECMDGOALS must be non-empty (the default goal is never clean-only)
# and contain nothing but `clean`.
SWIFT_MK_CLEAN_ONLY := $(if $(strip $(MAKECMDGOALS)),$(if $(strip $(filter-out clean,$(MAKECMDGOALS))),,1),)

ifeq ($(strip $(SWIFT_MK_CLEAN_ONLY)),1)

# Engine-owned trivial clean, self-contained so it needs no fetched module. It
# removes the SwiftPM build dir and the engine-managed DerivedData and runs
# `swift package clean`, ignoring any consumer SWIFT_CLEAN_CMD so `make clean`
# never compiles a dev tool. The trace header already printed above.
SWIFT_MK_DERIVED_DATA ?= $(CURDIR)/.derived-data

.PHONY: clean
clean:
	@if [ -f Package.swift ]; then swift package clean >/dev/null 2>&1 || true; fi; \
		rm -rf .build "$(SWIFT_MK_DERIVED_DATA)"

else

ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
$(if $(wildcard $(SWIFT_MK)),,$(error swift-makefile expected $(SWIFT_MK); rerun without SWIFT_MK_SKIP_FETCH))
else
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch,swift.mk,$(SWIFT_MK)); then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch swift.mk))
endif

-include $(SWIFT_MK)

endif
