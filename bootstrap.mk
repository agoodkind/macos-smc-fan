# bootstrap.mk fetches swift.mk into .make/ and includes it. swift.mk fetches its
# own helper scripts, the shared lint/format/periphery/osv configs, and the
# selected modules, so this stub is the only file a consumer commits and it
# rarely changes. Consumer Makefiles set their project commands and
# SWIFT_MK_MODULES, then include this file.
#
# Embedded shell runs under bash (not make's default $(shell) sh) so the body can
# follow the repo shell rules: set -euo pipefail, [[ ]], and full if/then/fi.

SWIFT_MK_DEV_DIR ?=
SWIFT_MK := .make/swift.mk
SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main

# Fetch one file from the local swift-makefile checkout (SWIFT_MK_DEV_DIR) or from
# GitHub. Used only to obtain swift.mk; swift.mk fetches everything else itself.
# Expanded into an outer bash -c so quoting stays make-variable substitution plus
# shell $$ escapes. Each failed source logs once, then the next source runs.
# Success must fall through (no exit 0): the caller is `bash -c '... && $(call) &&
# printf ok'`, so an early exit would skip the ok token make checks for.
define _swift_mk_fetch
	set -euo pipefail; \
	tmp_file=$$(mktemp "$(2).tmp.XXXXXX"); \
	trap "rm -f \"$$tmp_file\"" EXIT; \
	fetched=0; \
	if [[ -n "$(SWIFT_MK_DEV_DIR)" && -f "$(SWIFT_MK_DEV_DIR)/$(1)" ]]; then \
		cp "$(SWIFT_MK_DEV_DIR)/$(1)" "$$tmp_file"; \
		if [[ ! -s "$$tmp_file" ]]; then \
			printf "%s\n" "error: $(SWIFT_MK_DEV_DIR)/$(1) is empty after copy" >&2; \
			exit 1; \
		fi; \
		mv "$$tmp_file" "$(2)"; \
		fetched=1; \
	fi; \
	if [[ "$$fetched" -eq 0 ]] && command -v gh >/dev/null 2>&1; then \
		if gh api "repos/$(SWIFT_MK_API_REPO)/contents/$(1)?ref=$(SWIFT_MK_API_REF)" \
			-H "Accept: application/vnd.github.raw" >"$$tmp_file" \
			&& [[ -s "$$tmp_file" ]]; then \
			mv "$$tmp_file" "$(2)"; \
			fetched=1; \
		else \
			printf "%s\n" "bootstrap.mk: gh api fetch of $(1) failed; trying curl" >&2; \
		fi; \
	elif [[ "$$fetched" -eq 0 ]]; then \
		printf "%s\n" "bootstrap.mk: gh not on PATH; trying curl" >&2; \
	fi; \
	if [[ "$$fetched" -eq 0 ]]; then \
		if curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BASE_URL)/$(1)" \
			-o "$$tmp_file" && [[ -s "$$tmp_file" ]]; then \
			mv "$$tmp_file" "$(2)"; \
			fetched=1; \
		fi; \
	fi; \
	if [[ "$$fetched" -eq 0 ]]; then \
		printf "%s\n" "error: could not fetch $(1) (tried SWIFT_MK_DEV_DIR, gh api, then $(SWIFT_MK_BASE_URL)); check your network connection, and if gh is installed run: gh auth status" >&2; \
		exit 1; \
	fi
endef

# Print the trace header before any other work. This is a minimal self-contained
# core: adopt an inherited TRACEPARENT (any well-formed one, normalized to flags
# 01), then the canonical TRACE_ID/SPAN_ID pair, then the SWIFT_MK_TRACE_ID/
# SWIFT_MK_SPAN_ID aliases, or mint a fresh id, so the consumer bootstrap needs no
# fetch and works offline. The full trace logic (same precedence plus stricter
# W3C validation) lives once in scripts/swift-mk-trace.sh, which swift.mk runs for
# the engine build. Wrapped in a define so make treats the shell body literally,
# not as make comments/parens. The log directory is absolutized so the header is
# usable from any cwd.
define swift_mk_trace_min
$(shell /usr/bin/env bash -c 'set -euo pipefail; \
	log_dir=".make/logs"; \
	mkdir -p "$$log_dir"; \
	log_dir=$$(cd "$$log_dir" && pwd); \
	tp="$${TRACEPARENT-}"; \
	trace=""; \
	span=""; \
	rest=$${tp#00-}; \
	if [[ "$$rest" != "$$tp" ]]; then \
		trace=$${rest%%-*}; \
		tail=$${rest#*-}; \
		span=$${tail%%-*}; \
	fi; \
	is_id() { \
		local value=$$1; \
		local expected_length=$$2; \
		local stripped; \
		if [[ $${#value} -ne "$$expected_length" ]]; then \
			return 1; \
		fi; \
		stripped=$$(printf "%s" "$$value" | tr -d "0123456789abcdef"); \
		if [[ -n "$$stripped" ]]; then \
			return 1; \
		fi; \
		if [[ -z "$$(printf "%s" "$$value" | tr -d "0")" ]]; then \
			return 1; \
		fi; \
		return 0; \
	}; \
	if ! is_id "$$trace" 32 || ! is_id "$$span" 16; then \
		trace=""; \
		span=""; \
	fi; \
	if [[ -z "$$trace" ]] && is_id "$${TRACE_ID-}" 32 && is_id "$${SPAN_ID-}" 16; then \
		trace="$$TRACE_ID"; \
		span="$$SPAN_ID"; \
	fi; \
	if [[ -z "$$trace" ]] && is_id "$${SWIFT_MK_TRACE_ID-}" 32 && is_id "$${SWIFT_MK_SPAN_ID-}" 16; then \
		trace="$$SWIFT_MK_TRACE_ID"; \
		span="$$SWIFT_MK_SPAN_ID"; \
	fi; \
	if [[ -z "$$trace" ]]; then \
		if ! trace=$$(od -An -N16 -tx1 /dev/urandom | tr -d "[:space:]"); then \
			printf "%s\n" "bootstrap.mk: od failed to read /dev/urandom for trace id" >&2; \
			exit 0; \
		fi; \
		if ! span=$$(od -An -N8 -tx1 /dev/urandom | tr -d "[:space:]"); then \
			printf "%s\n" "bootstrap.mk: od failed to read /dev/urandom for span id" >&2; \
			exit 0; \
		fi; \
	fi; \
	if ! is_id "$$trace" 32 || ! is_id "$$span" 16; then \
		printf "%s\n" "bootstrap.mk: minted ids failed validation; skipping trace export" >&2; \
		exit 0; \
	fi; \
	tp="00-$$trace-$$span-01"; \
	printf "%s\n" "$$tp" >"$$log_dir/.traceparent"; \
	prev=""; \
	if [[ -s "$$log_dir/.run" ]]; then \
		if ! IFS= read -r prev <"$$log_dir/.run"; then \
			printf "%s\n" "bootstrap.mk: failed to read $$log_dir/.run; treating as a new run" >&2; \
			prev=""; \
		fi; \
	fi; \
	if [[ "$$prev" != "$$trace" ]]; then \
		printf "%s\n" "$$trace" >"$$log_dir/.run"; \
		printf "🔎 logs=%s trace_id=%s span_id=%s\n" "$$log_dir" "$$trace" "$$span" >&2; \
	fi; \
	printf "ok %s %s %s" "$$tp" "$$trace" "$$span"')
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

ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
$(if $(wildcard $(SWIFT_MK)),,$(error swift-makefile expected $(SWIFT_MK); rerun without SWIFT_MK_SKIP_FETCH))
else
$(if $(filter ok,$(shell /usr/bin/env bash -c 'mkdir -p .make && $(call _swift_mk_fetch,swift.mk,$(SWIFT_MK)) && printf ok')),,$(error swift-makefile failed to fetch swift.mk))
endif

-include $(SWIFT_MK)
