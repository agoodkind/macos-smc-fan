#!/usr/bin/env bash
# Scripts/assert-categories-covered.sh
#
# Guard C helper: verifies that every category in expected-categories.txt
# appears at least once in a smoke-run NDJSON file.
#
# Usage: ./Scripts/assert-categories-covered.sh <smoke.ndjson> <expected-categories.txt>

set -e

NDJSON="${1:?Usage: $0 <smoke.ndjson> <expected-categories.txt>}"
REGISTRY="${2:?Usage: $0 <smoke.ndjson> <expected-categories.txt>}"

missing=0
while IFS= read -r category; do
    [[ -z "$category" ]] && continue
    if grep -q "\"category\":\"$category\"" "$NDJSON"; then
        echo "  OK  $category"
    else
        echo "  MISSING  $category"
        missing=$((missing + 1))
    fi
done < "$REGISTRY"

if [[ $missing -gt 0 ]]; then
    echo "assert-categories-covered: FAILED ($missing categories missing from smoke log)"
    exit 1
fi
echo "assert-categories-covered: PASSED"
