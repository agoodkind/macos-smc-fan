#!/usr/bin/env bash
# Scripts/check-privacy-enforcement.sh
#
# Guard B verification: flips #if false to #if true in PrivacyEnforcementTests.swift,
# builds, asserts that the compiler rejects the unannotated interpolation, then reverts.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO/Tests/AppLogTests/PrivacyEnforcementTests.swift"

flip_on()  { sed -i '' 's/^#if false$/#if true/' "$TARGET"; }
flip_off() { sed -i '' 's/^#if true$/#if false/' "$TARGET"; }

trap flip_off EXIT

echo "check-privacy-enforcement: flipping #if false -> #if true..."
flip_on

echo "check-privacy-enforcement: building (expect compiler error)..."
if swift build --package-path "$REPO" 2>&1 | grep -q "error:"; then
    echo "check-privacy-enforcement: PASSED (compiler rejected unannotated interpolation)"
else
    echo "check-privacy-enforcement: FAILED (build succeeded but should have errored)"
    exit 1
fi
