.PHONY: build deploy install clean help run generate lint lint-tools lint-swiftlint \
	lint-swiftlint-baseline lint-swiftlint-baseline-prune-fixed lint-swiftlint-baseline-remove-fixed lint-swiftlint-baseline-accept-new \
	lint-files lint-diff lint-format lint-complexity lint-complexity-baseline lint-complexity-baseline-prune-fixed lint-complexity-baseline-remove-fixed lint-complexity-baseline-accept-new fmt test analyze audit build-check check \
	lint-deadcode lint-deadcode-baseline lint-deadcode-baseline-prune-fixed lint-deadcode-baseline-remove-fixed lint-deadcode-baseline-accept-new \
	swiftcheck-extra swiftcheck-extra-baseline swiftcheck-extra-baseline-prune-fixed swiftcheck-extra-baseline-remove-fixed swiftcheck-extra-baseline-accept-new swiftcheck-extra-bin \
	baseline baseline-prune-fixed baseline-remove-fixed baseline-accept-new baseline-add-new \
	swift-mk-bin swift-mk-notice lint-swiftlint-scope lint-swiftlint-baseline-scope lint-swiftlint-baseline-scope-accept-new \
	swift-mk-sync update-swift-mk smoke-fetch update-consumers update-consumers-dry-run log-audit install-hooks xcode-file-header

SWIFT_MK_BASE_URL ?= https://raw.githubusercontent.com/agoodkind/swift-makefile/main
SWIFT_MK_API_REPO ?= agoodkind/swift-makefile
SWIFT_MK_API_REF ?= main

SWIFT_MK_ENTRY_MAKEFILE := $(firstword $(MAKEFILE_LIST))
SWIFT_MK_ENTRY_BASENAME := $(notdir $(SWIFT_MK_ENTRY_MAKEFILE))
SWIFT_MK_RECURSIVE_MAKE := $(MAKE)
SWIFT_MK_RECURSIVE_MAKE_ARGS :=
ifeq ($(filter Makefile makefile GNUmakefile,$(SWIFT_MK_ENTRY_BASENAME)),)
SWIFT_MK_RECURSIVE_MAKE_ARGS := -f $(SWIFT_MK_ENTRY_MAKEFILE)
endif

SWIFT_MK_SELF := $(lastword $(MAKEFILE_LIST))
SWIFT_MK_SELF_DIR := $(patsubst %/,%,$(dir $(abspath $(SWIFT_MK_SELF))))
SWIFT_MK_LOCAL_SCRIPT_DIR := $(if $(strip $(SWIFT_MK_DEV_DIR)),$(SWIFT_MK_DEV_DIR)/scripts,$(SWIFT_MK_SELF_DIR)/scripts)
SWIFT_MK_FETCHED_SCRIPT_DIR := $(CURDIR)/.make/scripts
SWIFT_MK_HELPER_DIR := $(if $(wildcard $(SWIFT_MK_LOCAL_SCRIPT_DIR)/swift-mk-build.sh),$(SWIFT_MK_LOCAL_SCRIPT_DIR),$(SWIFT_MK_FETCHED_SCRIPT_DIR))
SWIFT_MK_FETCH_SCRIPT := $(SWIFT_MK_HELPER_DIR)/swift-mk-fetch-one.sh
SWIFT_MK_BIN ?= $(CURDIR)/.make/swift-mk
SWIFT_MK_LOCAL_NOTICES := $(if $(strip $(SWIFT_MK_DEV_DIR)),$(SWIFT_MK_DEV_DIR)/notices.txt,$(SWIFT_MK_SELF_DIR)/notices.txt)
SWIFT_MK_NOTICES_FILE := $(if $(wildcard $(SWIFT_MK_LOCAL_NOTICES)),$(SWIFT_MK_LOCAL_NOTICES),$(CURDIR)/.make/notices.txt)

define _swift_mk_fetch_bootstrap_commands
	mkdir -p "$$(dirname "$(2)")"; \
	tmp=$$(mktemp "$(2).tmp.XXXXXX") || exit 1; \
	err=$$(mktemp "$(2).err.XXXXXX") || { rm -f "$$tmp"; exit 1; }; \
	if [ -n "$(3)" ] && [ -f "$(3)/$(1)" ]; then \
		cp "$(3)/$(1)" "$$tmp" || { rm -f "$$tmp" "$$err"; exit 1; }; \
	else \
		gh_path=$$(command -v gh || true); \
		if [ -n "$$gh_path" ] && gh api "repos/$(SWIFT_MK_API_REPO)/contents/$(1)?ref=$(SWIFT_MK_API_REF)" -H "Accept: application/vnd.github.raw" > "$$tmp" 2>"$$err"; then \
			:; \
		elif curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BASE_URL)/$(1)?v=$$(date +%s)" -o "$$tmp" 2>"$$err"; then \
			:; \
		elif curl -fsSL --connect-timeout 5 --max-time 10 "$(SWIFT_MK_BASE_URL)/$(1)" -o "$$tmp" 2>"$$err"; then \
			:; \
		else \
			rm -f "$$tmp" "$$err"; \
			exit 1; \
		fi; \
	fi; \
	if [ -s "$$tmp" ]; then \
		mv "$$tmp" "$(2)"; \
		case "$(2)" in *.sh) chmod +x "$(2)" ;; esac; \
		rm -f "$$err"; \
	else \
		rm -f "$$tmp" "$$err"; \
		exit 1; \
	fi
endef

define swift_mk_fetch_bootstrap
$(if $(filter ok,$(shell mkdir -p .make && if $(call _swift_mk_fetch_bootstrap_commands,$(1),$(2),$(SWIFT_MK_DEV_DIR)) > .make/swift-mk-bootstrap-fetch.log; then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch $(1) into $(2)))
endef

ifeq ($(SWIFT_MK_HELPER_DIR),$(SWIFT_MK_FETCHED_SCRIPT_DIR))
SWIFT_MK_FETCHED_BOOTSTRAP := $(call swift_mk_fetch_bootstrap,scripts/swift-mk-fetch-one.sh,.make/scripts/swift-mk-fetch-one.sh)
endif

define swift-mk-fetch-one
$(if $(filter ok,$(shell mkdir -p .make && if bash "$(SWIFT_MK_FETCH_SCRIPT)" "$(1)" ".make/$(1)" "$(SWIFT_MK_DEV_DIR)" > .make/swift-mk-fetch.log; then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch $(1)))
endef

define swift-mk-fetch-path
$(if $(filter ok,$(shell mkdir -p .make && if bash "$(SWIFT_MK_FETCH_SCRIPT)" "$(1)" "$(2)" "$(SWIFT_MK_DEV_DIR)" > .make/swift-mk-fetch.log; then printf ok; else printf fail; fi)),,$(error swift-makefile failed to fetch $(1)))
endef

define swift-mk-require-one
$(if $(wildcard $(1)),,$(error swift-makefile expected $(1); rerun without SWIFT_MK_SKIP_FETCH))
endef

SWIFT_MK_SCRIPT_FILES := \
	scripts/swift-mk-fetch-one.sh \
	scripts/swift-mk-build.sh \
	scripts/swift-mk-sync.sh \
	scripts/swift-mk-fleet-update.sh \
	scripts/install-hooks.sh \
	hooks/pre-commit \
	swiftcheck/Package.swift \
	swiftcheck/Sources/SwiftCheckCore/Rule.swift \
	swiftcheck/Sources/SwiftCheckCore/TopLevelTypeDeclaration.swift \
	swiftcheck/Sources/swiftcheck-extra/main.swift \
	swiftcheck/Tests/SwiftCheckCoreTests/SwiftCheckCoreTests.swift \
	Package.swift \
	Sources/SwiftMkRenderCore/TemplateRenderer.swift \
	Sources/SwiftMkRenderCLI/main.swift \
	Sources/SwiftMkCLI/main.swift \
	Sources/SwiftMkCore/Findings.swift \
	Sources/SwiftMkCore/Text.swift \
	Sources/SwiftMkCore/Env.swift \
	Sources/SwiftMkCore/Shell.swift \
	Sources/SwiftMkCore/Capture.swift \
	Sources/SwiftMkCore/Baseline.swift \
	Sources/SwiftMkCore/BaselineReport.swift \
	Sources/SwiftMkCore/Baseline+Gate.swift \
	Sources/SwiftMkCore/BaselineSpec.swift \
	Sources/SwiftMkCore/TokenGate.swift \
	Sources/SwiftMkCore/Scope.swift \
	Sources/SwiftMkCore/Swiftcheck.swift \
	Sources/SwiftMkCore/DeadcodeScan.swift \
	Sources/SwiftMkCore/DeadcodeScan+Witness.swift \
	Sources/SwiftMkCore/DeadcodeBuildConfig.swift \
	Sources/SwiftMkCore/WitnessFilter.swift \
	Sources/SwiftMkCore/SigningBuildConfig.swift \
	Sources/SwiftMkCore/Lint.swift \
	Sources/SwiftMkCore/Lint+Run.swift \
	Sources/SwiftMkCore/BaselineRunner.swift \
	Sources/SwiftMkCore/Notice.swift \
	Sources/SwiftMkCore/Output.swift \
	Sources/SwiftMkCore/Logging.swift \
	Sources/SwiftMkCore/Correlation.swift \
	Sources/SwiftMkCore/OTelExport.swift \
	Sources/SwiftMkCore/BuildFailureLog.swift \
	Sources/SwiftMkCore/IndexStoreSettle.swift \
	Sources/SwiftMkCore/IndexCompleteness.swift \
	Sources/SwiftMkCore/FileLock.swift \
	Tests/SwiftMkRenderCoreTests/TemplateRendererTests.swift \
	Tests/SwiftMkCoreTests/SwiftMkCoreTests.swift \
	Tests/SwiftMkCoreTests/DeadcodeBuildConfigTests.swift \
	Tests/SwiftMkCoreTests/IndexCompletenessTests.swift \
	Tests/SwiftMkCoreTests/WitnessFilterTests.swift \
	Tests/SwiftMkCoreTests/SigningBuildConfigTests.swift \
	notices.txt \
	templates/xcode/IDETemplateMacros.plist.template

ifeq ($(SWIFT_MK_HELPER_DIR),$(SWIFT_MK_FETCHED_SCRIPT_DIR))
ifeq ($(strip $(SWIFT_MK_SKIP_FETCH)),1)
SWIFT_MK_FETCHED_SCRIPTS := $(foreach s,$(SWIFT_MK_SCRIPT_FILES),$(call swift-mk-require-one,.make/$(s)))
else
SWIFT_MK_FETCHED_SCRIPTS := $(foreach s,$(SWIFT_MK_SCRIPT_FILES),$(call swift-mk-fetch-one,$(s)))
endif
endif

SWIFT_MK_MODULES ?=
ifneq ($(strip $(SWIFT_MK_BOOTSTRAP_FETCHED)$(SWIFT_MK_SKIP_FETCH)),)
SWIFT_MK_FETCHED_MODULES := $(foreach m,$(SWIFT_MK_MODULES),$(if $(wildcard .make/$(m) $(SWIFT_MK_DEV_DIR)/$(m)),,$(error swift-makefile expected .make/$(m); rerun without SWIFT_MK_SKIP_FETCH)))
else
SWIFT_MK_FETCHED_MODULES := $(foreach m,$(SWIFT_MK_MODULES),$(call swift-mk-fetch-one,$(m)))
endif

SWIFT_MK_SWIFTLINT_CONFIG ?= .make/swiftlint.yml
SWIFT_MK_SWIFT_FORMAT_CONFIG ?= .make/swift-format.json
SWIFT_MK_PERIPHERY_CONFIG ?= .make/periphery.yml

# Default Xcode location for the rendered file-header macros. Override to a
# project's xcshareddata for a per-project header. swift-mk reads the git
# identity itself.
XCODE_TEMPLATE_DIR ?= $(HOME)/Library/Developer/Xcode/UserData

ifneq ($(strip $(SWIFT_MK_BOOTSTRAP_FETCHED)$(SWIFT_MK_SKIP_FETCH)),)
SWIFT_MK_FETCHED_SWIFTLINT := $(call swift-mk-require-one,$(SWIFT_MK_SWIFTLINT_CONFIG))
SWIFT_MK_FETCHED_SWIFT_FORMAT := $(call swift-mk-require-one,$(SWIFT_MK_SWIFT_FORMAT_CONFIG))
SWIFT_MK_FETCHED_PERIPHERY := $(call swift-mk-require-one,$(SWIFT_MK_PERIPHERY_CONFIG))
else
SWIFT_MK_FETCHED_SWIFTLINT := $(call swift-mk-fetch-path,.swiftlint.yml,$(SWIFT_MK_SWIFTLINT_CONFIG))
SWIFT_MK_FETCHED_SWIFT_FORMAT := $(call swift-mk-fetch-path,.swift-format,$(SWIFT_MK_SWIFT_FORMAT_CONFIG))
SWIFT_MK_FETCHED_PERIPHERY := $(call swift-mk-fetch-path,.periphery.yml,$(SWIFT_MK_PERIPHERY_CONFIG))
endif

SWIFTLINT ?= swiftlint
SWIFTLINT_FLAGS ?= --config $(SWIFT_MK_SWIFTLINT_CONFIG) --reporter xcode
SWIFTLINT_TARGETS ?= Sources Tests Package.swift
SWIFTLINT_BASELINE ?= .swiftlint-baseline.txt
# Untracked files (generated output, scratch files) are skipped by the git-ignore
# filter in the lint runner, not by a path pattern: a path pattern would let a
# tracked file in a matching directory silently escape linting. A repo can still
# add explicit path patterns through SWIFTLINT_EXCLUDE_PATHS.
SWIFTLINT_DEFAULT_EXCLUDE_PATHS ?=
SWIFTLINT_EXCLUDE_PATHS ?=
SWIFTLINT_BASELINE_SCOPE_PATTERN ?=
RULE ?=

SWIFT_FORMAT ?= xcrun swift-format
SWIFT_FORMAT_TARGETS ?= $(SWIFTLINT_TARGETS)

COMPLEXITY_RULES ?= cyclomatic_complexity,function_body_length,closure_body_length,file_length,type_body_length,function_parameter_count,large_tuple,nesting,todo
SWIFTLINT_COMPLEXITY_BASELINE ?= .swiftlint-complexity-baseline.txt

PERIPHERY ?= periphery
PERIPHERY_ARGS ?= scan --config $(SWIFT_MK_PERIPHERY_CONFIG) --strict
PERIPHERY_BASELINE ?= .periphery-baseline.txt
PERIPHERY_DEFAULT_EXCLUDE_PATHS ?=
PERIPHERY_EXCLUDE_PATHS ?=

OSV_SCANNER ?= osv-scanner
OSV_SCANNER_ARGS ?= --recursive --allow-no-lockfiles

LINT_CONCURRENCY ?= auto

SWIFT_MK_XCODE_VERSION_MAJOR := $(shell xcodebuild_path=$$(command -v xcodebuild || printf ''); if [ -n "$$xcodebuild_path" ]; then "$$xcodebuild_path" -version | awk '/^Xcode / { split($$2, version_parts, "."); print version_parts[1]; exit }'; else printf 0; fi)
SWIFT_MK_XCODE_CACHE ?= auto
SWIFT_MK_XCODE_CACHE_DIAGNOSTICS ?= false
SWIFT_MK_XCODE_CACHE_AUTO_ENABLED := $(shell awk 'BEGIN { version = "$(SWIFT_MK_XCODE_VERSION_MAJOR)" + 0; if (version >= 26) print "YES"; else print "NO"; }')
SWIFT_MK_XCODE_CACHE_ENABLED := NO
ifneq ($(filter $(SWIFT_MK_XCODE_CACHE),1 true TRUE yes YES on ON),)
SWIFT_MK_XCODE_CACHE_ENABLED := YES
else ifneq ($(filter $(SWIFT_MK_XCODE_CACHE),0 false FALSE no NO off OFF),)
SWIFT_MK_XCODE_CACHE_ENABLED := NO
else ifneq ($(filter $(SWIFT_MK_XCODE_CACHE),auto AUTO),)
SWIFT_MK_XCODE_CACHE_ENABLED := $(SWIFT_MK_XCODE_CACHE_AUTO_ENABLED)
endif
SWIFT_MK_XCODE_CACHE_DIAGNOSTICS_ENABLED := NO
ifneq ($(filter $(SWIFT_MK_XCODE_CACHE_DIAGNOSTICS),1 true TRUE yes YES on ON),)
SWIFT_MK_XCODE_CACHE_DIAGNOSTICS_ENABLED := YES
endif
SWIFT_MK_XCODEBUILD_ARGS := $(strip $(if $(filter YES,$(SWIFT_MK_XCODE_CACHE_ENABLED)),COMPILATION_CACHE_ENABLE_CACHING=YES $(if $(filter YES,$(SWIFT_MK_XCODE_CACHE_DIAGNOSTICS_ENABLED)),COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES,),))
SWIFT_MK_XCODEBUILD_NO_CACHE_ARGS := COMPILATION_CACHE_ENABLE_CACHING=NO COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=NO
# Canonical DerivedData path. A consumer that builds Xcode targets routes its
# `xcodebuild -derivedDataPath` here, and the dead-code gate reads the index store
# from the same place, so coverage analysis is deterministic across repos.
SWIFT_MK_DERIVED_DATA ?= $(CURDIR)/.derived-data
SWIFT_MK_SWIFTPM_CACHE_ARGS_AUTO := $(shell swift_path=$$(command -v swift || printf ''); if [ -n "$$swift_path" ]; then build_help=$$("$$swift_path" build --help || true); args=""; printf '%s\n' "$$build_help" | grep -q -- '--enable-dependency-cache' && args="$$args --enable-dependency-cache"; printf '%s\n' "$$build_help" | grep -q -- '--enable-build-manifest-caching' && args="$$args --enable-build-manifest-caching"; printf '%s\n' "$$build_help" | grep -q -- '--manifest-cache' && args="$$args --manifest-cache shared"; printf '%s\n' "$$args" | awk '{$$1=$$1; print}'; fi)
SWIFT_MK_SWIFTPM_CACHE_ARGS ?= $(SWIFT_MK_SWIFTPM_CACHE_ARGS_AUTO)

SWIFT_MK_GATE_TOKEN_CMD ?= curl -fsSL "https://en.wikipedia.org/api/rest_v1/feed/featured/$$(date -u +%Y/%m/%d)" | jq -r '.tfa.titles.canonical'
BYPASS_LINT ?=
BYPASS_CONFIRM ?=
BYPASS_TOKEN_CMD ?= $(SWIFT_MK_GATE_TOKEN_CMD)
BASELINE_CONFIRM ?=
BASELINE_TOKEN ?=
BASELINE_TOKEN_CMD ?= $(SWIFT_MK_GATE_TOKEN_CMD)
BASELINE_UPDATE_MODE ?= sync

SWIFT_BUILD_CMD ?= swift build $(SWIFT_MK_SWIFTPM_CACHE_ARGS)
# The build the dead-code gate runs to refresh the index store. Defaults to
# SWIFT_BUILD_CMD; set it when SWIFT_BUILD_CMD needs a target argument or builds a
# single platform, so the gate has a target-free build that covers every platform.
SWIFT_DEADCODE_BUILD_CMD ?=
SWIFT_TEST_CMD ?= swift test $(SWIFT_MK_SWIFTPM_CACHE_ARGS)
SWIFT_RUN_CMD ?=
SWIFT_GENERATE_CMD ?=
SWIFT_CLEAN_CMD ?= swift package clean
SWIFT_DEPLOY_CMD ?=
SWIFT_ANALYZE_CMD ?=
SWIFT_AUDIT_EXTRA_CMD ?=
SWIFT_LOG_AUDIT_CMD ?=

SWIFTCHECK_EXTRA_BIN ?=
SWIFTCHECK_EXTRA_BUILD_REPO ?= $(if $(and $(SWIFT_MK_DEV_DIR),$(wildcard $(SWIFT_MK_DEV_DIR)/swiftcheck/Package.swift)),$(SWIFT_MK_DEV_DIR)/swiftcheck,$(CURDIR)/.make/swiftcheck)
SWIFTCHECK_EXTRA_BUILD_PRODUCT ?= swiftcheck-extra
SWIFTCHECK_EXTRA_FLAGS ?= -no_any -no_anyobject -untyped_json -force_unwrap -force_try -silent_try -silent_catch -banned_direct_output -task_detached -sleep_in_production -fatal_exit -sensitive_log_field -missing_boundary_log -ignored_cleanup_error -missing_section_mark
SWIFTCHECK_EXTRA_TARGETS ?= $(SWIFTLINT_TARGETS)
SWIFTCHECK_EXTRA_BASELINE ?= .swiftcheck-extra-baseline.txt
SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS ?=
SWIFTCHECK_EXTRA_EXCLUDE_PATHS ?=

LINT_GATES ?= lint-swiftlint lint-format lint-complexity lint-deadcode swiftcheck-extra $(if $(strip $(SWIFT_LOG_AUDIT_CMD)),log-audit,)

export SWIFT_MK_ROOT := $(CURDIR)
export SWIFT_MK_HELPER_DIR
export SWIFT_MK_RECURSIVE_MAKE
export SWIFT_MK_RECURSIVE_MAKE_ARGS
export SWIFT_MK_SCRIPT_FILES
export SWIFT_MK_BASE_URL
export SWIFT_MK_API_REPO
export SWIFT_MK_API_REF
export SWIFT_MK_SWIFTLINT_CONFIG
export SWIFT_MK_SWIFT_FORMAT_CONFIG
export SWIFT_MK_PERIPHERY_CONFIG
export SWIFTLINT
export SWIFTLINT_FLAGS
export SWIFTLINT_TARGETS
export SWIFTLINT_BASELINE
export SWIFTLINT_BASELINE_SCOPE_PATTERN
export RULE
export SWIFT_MK_BIN
export SWIFT_MK_NOTICES_FILE
export SWIFTLINT_DEFAULT_EXCLUDE_PATHS
export SWIFTLINT_EXCLUDE_PATHS
export SWIFT_FORMAT
export SWIFT_FORMAT_TARGETS
export COMPLEXITY_RULES
export SWIFTLINT_COMPLEXITY_BASELINE
export PERIPHERY
export PERIPHERY_ARGS
export PERIPHERY_BASELINE
export PERIPHERY_DEFAULT_EXCLUDE_PATHS
export PERIPHERY_EXCLUDE_PATHS
export OSV_SCANNER
export OSV_SCANNER_ARGS
export LINT_CONCURRENCY
export SWIFT_MK_XCODE_VERSION_MAJOR
export SWIFT_MK_XCODE_CACHE
export SWIFT_MK_XCODE_CACHE_DIAGNOSTICS
export SWIFT_MK_XCODEBUILD_ARGS
export SWIFT_MK_XCODEBUILD_NO_CACHE_ARGS
export SWIFT_MK_DERIVED_DATA
export SWIFT_MK_SWIFTPM_CACHE_ARGS
export LINT_GATES
export LINT_FILES
export LINT_LINE_RANGES
export BASELINE
export BASELINE_CONFIRM
export BASELINE_TOKEN
export BASELINE_TOKEN_CMD
export BASELINE_UPDATE_MODE
export BYPASS_LINT
export BYPASS_CONFIRM
export BYPASS_TOKEN_CMD
export SWIFT_MK_GATE_TOKEN_CMD
export SWIFT_BUILD_CMD
export SWIFT_DEADCODE_BUILD_CMD
export SWIFT_TEST_CMD
export SWIFT_RUN_CMD
export SWIFT_GENERATE_CMD
export SWIFT_CLEAN_CMD
export SWIFT_DEPLOY_CMD
export SWIFT_ANALYZE_CMD
export SWIFT_AUDIT_EXTRA_CMD
export SWIFT_LOG_AUDIT_CMD
export SWIFTCHECK_EXTRA_BIN
export SWIFTCHECK_EXTRA_BUILD_REPO
export SWIFTCHECK_EXTRA_BUILD_PRODUCT
export SWIFTCHECK_EXTRA_FLAGS
export SWIFTCHECK_EXTRA_TARGETS
export SWIFTCHECK_EXTRA_BASELINE
export SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS
export SWIFTCHECK_EXTRA_EXCLUDE_PATHS
export SWIFT_MK_CONSUMER_ROOTS
export SWIFT_MK_CONSUMER_MANIFEST
export SWIFT_MK_UPDATE_INCLUDE_DIRTY
export SWIFT_MK_UPDATE_VALIDATE
export SWIFT_MK_UPDATE_DRY_RUN

help:
	@printf '%s\n' 'Canonical entry points:'
	@printf '  %-40s %s\n' 'build' 'run build-check, then execute SWIFT_BUILD_CMD'
	@printf '  %-40s %s\n' 'run' 'run build, then execute SWIFT_RUN_CMD'
	@printf '  %-40s %s\n' 'deploy' 'run build, then execute SWIFT_DEPLOY_CMD'
	@printf '  %-40s %s\n' 'install' 'alias for deploy'
	@printf '  %-40s %s\n' 'generate' 'execute SWIFT_GENERATE_CMD when configured'
	@printf '  %-40s %s\n' 'clean' 'execute SWIFT_CLEAN_CMD when configured'
	@printf '  %-40s %s\n' 'check' 'alias for lint'
	@printf '  %-40s %s\n' 'lint' 'run every lint gate'
	@printf '  %-40s %s\n' 'build-check' 'run lint and audit'
	@printf '  %-40s %s\n' 'fmt' 'apply swift-format in place'
	@printf '  %-40s %s\n' 'test' 'execute SWIFT_TEST_CMD'
	@printf '  %-40s %s\n' 'analyze' 'run deadcode analysis and SWIFT_ANALYZE_CMD'
	@printf '  %-40s %s\n' 'audit' 'run dependency audit and SWIFT_AUDIT_EXTRA_CMD'
	@printf '\n%s\n' 'Build caching:'
	@printf '  %-40s %s\n' 'SWIFT_MK_XCODE_CACHE=auto|1|0' 'default local Xcode 26 compilation cache behavior'
	@printf '  %-40s %s\n' 'SWIFT_MK_XCODE_CACHE_DIAGNOSTICS=1' 'emit Xcode compilation cache diagnostic remarks'
	@printf '  %-40s %s\n' 'SWIFT_MK_SWIFTPM_CACHE_ARGS=...' 'override shared SwiftPM cache flags'
	@printf '  %-40s %s\n' 'ccache/sccache' 'C-family cache tools; not Swift compilation caches'
	@printf '\n%s\n' 'Scoped iteration:'
	@printf '  %-40s %s\n' 'lint-diff' 'run scoped lint against staged Swift files'
	@printf '  %-40s %s\n' 'lint-files LINT_FILES=...' 'run scoped lint against listed files'
	@printf '\n%s\n' 'Lint sub-targets:'
	@printf '  %-40s %s\n' 'lint-tools' 'install or verify swift-format, SwiftLint, Periphery, and osv-scanner'
	@printf '  %-40s %s\n' 'lint-swiftlint' 'SwiftLint with baseline gate'
	@printf '  %-40s %s\n' 'lint-format' 'swift-format diff gate'
	@printf '  %-40s %s\n' 'lint-complexity' 'SwiftLint metrics with baseline gate'
	@printf '  %-40s %s\n' 'lint-deadcode' 'Periphery with baseline gate'
	@printf '  %-40s %s\n' 'swiftcheck-extra' 'custom SwiftSyntax analyzers with baseline gate'
	@printf '\n%s\n' 'Baseline maintenance (maintainer use, guarded by BASELINE_CONFIRM and BASELINE_TOKEN):'
	@printf '  %-40s %s\n' 'baseline' 'refresh the recorded baselines'
	@printf '\n%s\n' 'Pipeline maintenance:'
	@printf '  %-40s %s\n' 'swift-mk-sync / update-swift-mk' 'refresh swift.mk, helper scripts, configs, modules, and swiftcheck source'
	@printf '  %-40s %s\n' 'smoke-fetch' 'force a fetch-path smoke run'
	@printf '  %-40s %s\n' 'update-consumers' 'refresh every opted-in consumer repo'
	@printf '  %-40s %s\n' 'update-consumers-dry-run' 'show fleet update work without writes'

swift-mk-bin:
	@SWIFT_MK_ROOT="$(CURDIR)" bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-build.sh" resolve

# Render the Xcode file-header macros from the current git identity so newly
# created files are stamped with this author. swift-mk reads the git identity,
# renders the template, and rewrites the plist only when it changes. Consumers
# invoke this on demand; swift-makefile's own Makefile runs it on every build.
xcode-file-header: swift-mk-bin
	@"$(SWIFT_MK_BIN)" xcode-file-header \
		--templates-dir "$(SWIFT_MK_SELF_DIR)/templates/xcode" \
		--output-dir "$(XCODE_TEMPLATE_DIR)"

swift-mk-notice: swift-mk-bin
	@"$(SWIFT_MK_BIN)" notice || true

lint: lint-tools | swift-mk-notice
	@"$(SWIFT_MK_BIN)" lint

lint-tools: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-tools

lint-swiftlint: lint-tools
	@"$(SWIFT_MK_BIN)" lint-swiftlint

lint-format: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-format

lint-complexity: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-complexity

lint-complexity-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline complexity

lint-complexity-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline complexity

lint-complexity-baseline-remove-fixed: lint-complexity-baseline-prune-fixed

lint-complexity-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline complexity

lint-files: lint-tools swiftcheck-extra-bin
	@"$(SWIFT_MK_BIN)" lint-files

lint-diff: lint-tools swiftcheck-extra-bin
	@"$(SWIFT_MK_BIN)" lint-diff

fmt: lint-tools
	@"$(SWIFT_MK_BIN)" fmt

test: swift-mk-bin
	@"$(SWIFT_MK_BIN)" test

log-audit: swift-mk-bin
	@"$(SWIFT_MK_BIN)" log-audit

audit: swift-mk-bin
	@"$(SWIFT_MK_BIN)" audit

analyze: lint-deadcode
	@if [ -n "$(strip $(SWIFT_ANALYZE_CMD))" ]; then eval "$(SWIFT_ANALYZE_CMD)"; fi

lint-deadcode: swift-mk-bin
	@"$(SWIFT_MK_BIN)" lint-deadcode

swiftcheck-extra-bin: swift-mk-bin
	@"$(SWIFT_MK_BIN)" swiftcheck-extra-bin

swiftcheck-extra: swiftcheck-extra-bin
	@"$(SWIFT_MK_BIN)" swiftcheck-extra

lint-swiftlint-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline swiftlint

lint-swiftlint-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline swiftlint

lint-swiftlint-baseline-remove-fixed: lint-swiftlint-baseline-prune-fixed

lint-swiftlint-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline swiftlint

lint-swiftlint-scope: lint-tools
	@"$(SWIFT_MK_BIN)" lint-swiftlint-scope

lint-swiftlint-baseline-scope: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline swiftlint-scope

lint-swiftlint-baseline-scope-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline swiftlint-scope

lint-deadcode-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline deadcode

lint-deadcode-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline deadcode

lint-deadcode-baseline-remove-fixed: lint-deadcode-baseline-prune-fixed

lint-deadcode-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline deadcode

swiftcheck-extra-baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline swiftcheck-extra

swiftcheck-extra-baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline swiftcheck-extra

swiftcheck-extra-baseline-remove-fixed: swiftcheck-extra-baseline-prune-fixed

swiftcheck-extra-baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline swiftcheck-extra

build-check: swift-mk-bin
	@"$(SWIFT_MK_BIN)" build-check

check: lint

baseline: swift-mk-bin
	@BASELINE_UPDATE_MODE=sync "$(SWIFT_MK_BIN)" baseline all

baseline-prune-fixed: swift-mk-bin
	@BASELINE_UPDATE_MODE=prune-fixed "$(SWIFT_MK_BIN)" baseline all

baseline-remove-fixed: baseline-prune-fixed

baseline-accept-new: swift-mk-bin
	@BASELINE_UPDATE_MODE=accept-new "$(SWIFT_MK_BIN)" baseline all

baseline-add-new: baseline-accept-new

update-go-mk:
	@printf 'swift-makefile: use update-swift-mk instead of update-go-mk\n'
	@exit 2

update-swift-mk swift-mk-sync:
	@SWIFT_MK="$(SWIFT_MK)" bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-sync.sh" update

smoke-fetch:
	@bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-sync.sh" smoke-fetch

update-consumers:
	@bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-fleet-update.sh" update

update-consumers-dry-run:
	@SWIFT_MK_UPDATE_DRY_RUN=1 bash "$(SWIFT_MK_HELPER_DIR)/swift-mk-fleet-update.sh" dry-run

install-hooks:
	@bash "$(SWIFT_MK_HELPER_DIR)/install-hooks.sh"

$(foreach m,$(SWIFT_MK_MODULES),$(eval -include .make/$(m)))
