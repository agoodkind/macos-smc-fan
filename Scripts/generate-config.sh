#!/bin/bash
# Generates Config.generated.swift and plist files from xcconfig build settings.
# All xcconfig variables are available as environment variables during build phases.
set -euo pipefail

GENERATED_DIR="${DERIVED_FILE_DIR}/Generated"
TEMPLATES_DIR="${SRCROOT}/Templates"

mkdir -p "${GENERATED_DIR}"

# Process all templates, flattening subdirectory structure into Generated/
find "${TEMPLATES_DIR}" -name '*.template' | while read -r template; do
  filename=$(basename "${template}" .template)
  sed \
    -e "s|@@HELPER_BUNDLE_ID@@|${HELPER_BUNDLE_ID}|g" \
    -e "s|@@APP_BUNDLE_ID@@|${APP_BUNDLE_ID}|g" \
    -e "s|@@DEVELOPMENT_TEAM@@|${DEVELOPMENT_TEAM}|g" \
    -e "s|@@BUNDLE_ID_PREFIX@@|${BUNDLE_ID_PREFIX}|g" \
    "${template}" > "${GENERATED_DIR}/${filename}"
done
