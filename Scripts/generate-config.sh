#!/bin/bash
# Generates Config.generated.swift and plist files from xcconfig build settings.
# All xcconfig variables are available as environment variables during build phases.
set -euo pipefail

GENERATED_DIR="${DERIVED_FILE_DIR}/Generated"
TEMPLATES_DIR="${SRCROOT}/Templates"

mkdir -p "${GENERATED_DIR}"

# Resolve git build info
GIT_COMMIT=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_VERSION=$(git -C "${SRCROOT}" describe --tags --always --dirty 2>/dev/null || echo "dev")
GIT_DIRTY=$(git -C "${SRCROOT}" diff --quiet 2>/dev/null && echo "false" || echo "true")

# Process all templates, flattening subdirectory structure into Generated/
find "${TEMPLATES_DIR}" -name '*.template' | while read -r template; do
  filename=$(basename "${template}" .template)
  sed \
    -e "s|@@HELPER_BUNDLE_ID@@|${HELPER_BUNDLE_ID}|g" \
    -e "s|@@APP_BUNDLE_ID@@|${APP_BUNDLE_ID}|g" \
    -e "s|@@DEVELOPMENT_TEAM@@|${DEVELOPMENT_TEAM}|g" \
    -e "s|@@BUNDLE_ID_PREFIX@@|${BUNDLE_ID_PREFIX}|g" \
    -e "s|@@GIT_COMMIT@@|${GIT_COMMIT}|g" \
    -e "s|@@GIT_VERSION@@|${GIT_VERSION}|g" \
    -e "s|@@GIT_DIRTY@@|${GIT_DIRTY}|g" \
    "${template}" > "${GENERATED_DIR}/${filename}"
done
