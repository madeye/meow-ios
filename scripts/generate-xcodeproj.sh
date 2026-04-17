#!/usr/bin/env bash
# Regenerate meow-ios.xcodeproj from project.yml using xcodegen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
fi

cd "$PROJECT_ROOT"
xcodegen generate --spec project.yml
echo "Generated meow-ios.xcodeproj from project.yml"
