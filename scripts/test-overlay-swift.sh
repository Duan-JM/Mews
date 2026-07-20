#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$ROOT/dist/.overlay-swift-tests"

cleanup() {
  rm -rf "$test_dir"
}
trap cleanup EXIT

rm -rf "$test_dir"
mkdir -p "$test_dir"

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -framework AppKit \
  "$ROOT/internal/app/macos/OverlayPlacement.swift" \
  "$ROOT/internal/app/macos/tests/OverlayPlacementTests.swift" \
  -o "$test_dir/overlay-placement-tests"

"$test_dir/overlay-placement-tests"
