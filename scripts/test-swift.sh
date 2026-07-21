#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mews-swift-tests.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
app_sources=("$ROOT/internal/app/macos/"*.swift)

swiftc \
  -parse-as-library \
  -framework AppKit \
  -framework Network \
  -typecheck \
  "${app_sources[@]}"

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  "$ROOT/internal/app/macos/AgentSocketProbe.swift" \
  "$ROOT/internal/app/macos/AgentRestartBackoff.swift" \
  "$ROOT/internal/app/macos/TerminalProfile.swift" \
  "$ROOT/internal/app/macos/CLIContext.swift" \
  "$ROOT/internal/app/macos/MewsEvent.swift" \
  "$ROOT/internal/app/macos/MewsPresentationState.swift" \
  "$ROOT/internal/app/macos/OverlayPlacement.swift" \
  "$ROOT/internal/app/macos/NotchAccessibilityModel.swift" \
  "$ROOT/internal/app/macos/NotchInteractionModel.swift" \
  "$ROOT/internal/app/macos/NotchPanelContent.swift" \
  "$ROOT/internal/app/macos/PixelStatusLogo.swift" \
  "$ROOT/internal/app/macos/NotchExpandedContentView.swift" \
  "$ROOT/internal/app/macos/NotchShellView.swift" \
  "$ROOT/internal/app/macos/NotchPanelController.swift" \
  "$ROOT/internal/app/macos/tests/MewsAppModelTests.swift" \
  "$ROOT/internal/app/macos/tests/EventAlertRoutingTests.swift" \
  "$ROOT/internal/app/macos/tests/MewsRuntimeHardeningTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchInteractionTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchPanelControllerTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchPanelContentTests.swift" \
  "$ROOT/internal/app/macos/tests/PixelStatusLogoTests.swift" \
  -framework AppKit \
  -framework Network \
  -o "$temp_dir/mews-app-model-tests"

"$temp_dir/mews-app-model-tests"
