# bootstrap.mk obtains .make/scripts/swift-mk-bootstrap.sh and runs it. The helper
# provisions the whole .make/ engine snapshot, swift.mk included, then owns every
# later validation, reuse, and failure decision itself, so a policy change there
# reaches every consumer on its next parse with no consumer-repo change. swift.mk
# fetches the shared lint/format/periphery/osv configs and the selected modules as
# part of that same snapshot, so this stub is the only file a consumer commits and
# it rarely changes. Consumer Makefiles set their project commands and
# SWIFT_MK_MODULES, then include this file.
#
# Embedded shell runs under bash (not make's default $(shell) sh) so the body can
# follow the repo shell rules: set -euo pipefail, [[ ]], and full if/then/fi.

SWIFT_MK_DEV_DIR ?=
SWIFT_MK := .make/swift.mk
SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main
# The same override swift.mk and the helper already read for the engine tarball.
# Reused here rather than introduced fresh, so obtaining the helper below is
# redirectable to a test server with the one variable that already exists for
# exactly this purpose.
SWIFT_MK_CODELOAD_BASE ?= https://codeload.github.com

SWIFT_MK_BOOTSTRAP := .make/scripts/swift-mk-bootstrap.sh

# Obtain the standalone helper script, and nothing else: swift.mk and every other
# engine asset arrive through running it, right below. Never destructive: a helper
# already on disk is left exactly as it is (this is what makes a warm parse free of
# this step entirely), SWIFT_MK_DEV_DIR is checked first so a developer's checkout
# always wins, and only a genuinely missing helper reaches the network. The one
# fetch that can happen here pulls the pinned-ref tarball from the same
# SWIFT_MK_CODELOAD_BASE/SWIFT_MK_API_REPO/SWIFT_MK_API_REF triple the engine
# snapshot itself already uses elsewhere, extracting only this one file from it.
# Deliberately not SWIFT_MK_BASE_URL, which hardcodes /main and would pin a
# ref-pinned consumer's helper to main forever. A cold, offline start is the one
# unavoidable hard failure.
define _swift_mk_get_bootstrap
	set -euo pipefail; \
	if [[ -n "$(SWIFT_MK_DEV_DIR)" && -f "$(SWIFT_MK_DEV_DIR)/scripts/swift-mk-bootstrap.sh" ]]; then \
		mkdir -p .make/scripts; \
		cp "$(SWIFT_MK_DEV_DIR)/scripts/swift-mk-bootstrap.sh" "$(SWIFT_MK_BOOTSTRAP)"; \
	elif [[ -s "$(SWIFT_MK_BOOTSTRAP)" ]]; then \
		: ; \
	else \
		mkdir -p .make/scripts; \
		tmp_dir=$$(mktemp -d ".make/scripts/.bootstrap-fetch.XXXXXX"); \
		trap "rm -rf \"$$tmp_dir\"" EXIT; \
		if curl -fsSL --connect-timeout 5 --max-time 15 "$(SWIFT_MK_CODELOAD_BASE)/$(SWIFT_MK_API_REPO)/tar.gz/$(SWIFT_MK_API_REF)" -o "$$tmp_dir/snapshot.tar.gz" \
			&& tar -xzf "$$tmp_dir/snapshot.tar.gz" -C "$$tmp_dir" --strip-components 1 \
			&& [[ -s "$$tmp_dir/scripts/swift-mk-bootstrap.sh" ]]; then \
			mv "$$tmp_dir/scripts/swift-mk-bootstrap.sh" "$(SWIFT_MK_BOOTSTRAP)"; \
		else \
			printf "%s\n" "error: could not obtain $(SWIFT_MK_BOOTSTRAP); check network access to $(SWIFT_MK_CODELOAD_BASE)" >&2; \
			exit 1; \
		fi; \
	fi; \
	chmod +x "$(SWIFT_MK_BOOTSTRAP)"
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
$(if $(wildcard $(SWIFT_MK_BOOTSTRAP)),,$(error swift-makefile expected $(SWIFT_MK_BOOTSTRAP); rerun without SWIFT_MK_SKIP_FETCH))
else
$(if $(filter ok,$(shell /usr/bin/env bash -c 'mkdir -p .make && $(call _swift_mk_get_bootstrap) && printf ok')),,$(error swift-makefile failed to obtain $(SWIFT_MK_BOOTSTRAP)))
endif

# In SWIFT_MK_DEV_DIR mode the helper's own main() returns immediately without
# touching .make (a developer checkout is the source of truth, not a fetched
# snapshot), so swift.mk itself is copied here directly, exactly as this file has
# always done for dev-dir mode.
ifneq ($(strip $(SWIFT_MK_DEV_DIR)),)
$(if $(filter ok,$(shell mkdir -p .make && cp "$(SWIFT_MK_DEV_DIR)/swift.mk" "$(SWIFT_MK)" && printf ok)),,$(error swift-makefile failed to copy swift.mk from $(SWIFT_MK_DEV_DIR)))
endif

# The helper provisions the whole engine snapshot (swift.mk included outside
# dev-dir mode) and owns validation, reuse, and failure from here on. A
# successful run guarantees every required asset, including every selected
# module, is already on disk, so SWIFT_MK_SKIP_FETCH is forced to 1 for the
# include below: without it, swift.mk's own snapshot check would run this same
# helper a second time and cost a second network round trip on an
# already-warm parse.
#
# Every SWIFT_MK_* variable THE HELPER READS is forwarded explicitly. That is
# the six below, which is the complete set the helper references.
#
# SWIFT_MK_BASE_URL is deliberately not among them: the helper never reads it.
# It belongs to swift.mk's own per-file fetch path. Forwarding a variable the
# helper ignores would suggest it has an effect there.
#
# Make only auto-exports variables that came from the process environment, so a
# consumer who sets one on the make command line, or with a plain assignment in
# their own Makefile before this include, sets the Make variable without
# exporting it. This file then acts on the value while the helper, which owns
# every asset install, never sees it, and the two halves disagree about what the
# user asked for.
#
# That split produced three distinct bugs in the go-makefile peer, so forward
# the whole set rather than adding names one at a time as each is found:
#
#   SWIFT_MK_DEV_DIR       this file takes its dev branch while the helper
#                          downloads upstream over the developer's own checkout,
#                          so they build and lint against main believing they
#                          are testing local edits
#   SWIFT_MK_SKIP_FETCH    this file honors it while the helper fetches anyway,
#                          so an air-gapped or pre-vendored build fails at parse
#                          time, the exact case the flag exists to serve
#   SWIFT_MK_CODELOAD_BASE the redirect is silently ineffective and the helper
#                          reaches real codeload while appearing redirected, so
#                          a test written that way passes against production
#   SWIFT_MK_API_REPO      the helper falls back to its own defaults and fetches
#   SWIFT_MK_API_REF       the wrong repository or ref's assets
#
# Adding a SWIFT_MK_* variable that the helper reads means adding it here too.
# GITHUB_ACTIONS and GITHUB_RUN_ID ride along so the CI rule holds even when a
# caller passes them as make variables rather than through the environment.
$(if $(filter ok,$(shell SWIFT_MK_API_REPO="$(SWIFT_MK_API_REPO)" SWIFT_MK_API_REF="$(SWIFT_MK_API_REF)" SWIFT_MK_MODULES="$(SWIFT_MK_MODULES)" SWIFT_MK_CODELOAD_BASE="$(SWIFT_MK_CODELOAD_BASE)" SWIFT_MK_DEV_DIR="$(SWIFT_MK_DEV_DIR)" SWIFT_MK_SKIP_FETCH="$(SWIFT_MK_SKIP_FETCH)" GITHUB_ACTIONS="$(GITHUB_ACTIONS)" GITHUB_RUN_ID="$(GITHUB_RUN_ID)" bash "$(SWIFT_MK_BOOTSTRAP)" >&2 && printf ok)),,$(error swift-makefile failed to provision the engine snapshot))
# Only in fetched mode. The helper returns immediately in dev-dir mode without
# provisioning anything, because there the checkout is the source of truth and no
# snapshot extract runs, so forcing skip-fetch here would leave swift.mk with no
# way to populate the selected modules or the renamed configs: its
# swift-mk-fetch-path fallback, which copies them out of SWIFT_MK_DEV_DIR, is
# reachable only when skip-fetch is not 1. A dev-dir consumer would get swift.mk
# and nothing else, which breaks the documented way to test an engine change in a
# consumer before pushing it.
ifeq ($(strip $(SWIFT_MK_DEV_DIR)),)
override SWIFT_MK_SKIP_FETCH := 1
endif

-include $(SWIFT_MK)
