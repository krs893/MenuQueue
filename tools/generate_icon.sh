#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_OUTPUT="${1:-$PROJECT_DIR/Assets}"
if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [output-directory]\n' "$0" >&2
    exit 2
fi
ICON_WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/menuqueue-icon-build.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
/usr/bin/xcrun swiftc -O -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$ICON_WORK/module-cache" -framework AppKit \
    "$PROJECT_DIR/tools/GenerateIcon.swift" -o "$ICON_WORK/GenerateIcon"
"$ICON_WORK/GenerateIcon" "$ICON_OUTPUT"
