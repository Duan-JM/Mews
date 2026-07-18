#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mews-swift-tests.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
app_sources=("$ROOT/internal/app/macos/"*.swift)

swiftc \
  -parse-as-library \
  -framework AppKit \
  -typecheck \
  "${app_sources[@]}"

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  "$ROOT/internal/app/macos/CLIContext.swift" \
  "$ROOT/internal/app/macos/MewsEvent.swift" \
  "$ROOT/internal/app/macos/tests/MewsAppModelTests.swift" \
  -o "$temp_dir/mews-app-model-tests"

"$temp_dir/mews-app-model-tests"
