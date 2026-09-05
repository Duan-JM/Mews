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
  "$ROOT/internal/app/macos/AgentProcessEnvironment.swift" \
  "$ROOT/internal/app/macos/NotificationStatusRecord.swift" \
  "$ROOT/internal/app/macos/RuntimeHealthSnapshot.swift" \
  "$ROOT/internal/app/macos/TerminalProfile.swift" \
  "$ROOT/internal/app/macos/CLIContext.swift" \
  "$ROOT/internal/app/macos/MewsEvent.swift" \
  "$ROOT/internal/app/macos/EventLogFileIO.swift" \
  "$ROOT/internal/app/macos/EventLogReader.swift" \
  "$ROOT/internal/app/macos/SessionEvidenceReader.swift" \
  "$ROOT/internal/app/macos/SessionReturnContext.swift" \
  "$ROOT/internal/app/macos/SessionEvidence.swift" \
  "$ROOT/internal/app/macos/SessionModels.swift" \
  "$ROOT/internal/app/macos/SessionState.swift" \
  "$ROOT/internal/app/macos/SessionStateRecord.swift" \
  "$ROOT/internal/app/macos/SessionStateStore.swift" \
  "$ROOT/internal/app/macos/SessionStateController.swift" \
  "$ROOT/internal/app/macos/SessionVisibility.swift" \
  "$ROOT/internal/app/macos/SessionDismissal.swift" \
  "$ROOT/internal/app/macos/AttentionReconciler.swift" \
  "$ROOT/internal/app/macos/AttentionStateStore.swift" \
  "$ROOT/internal/app/macos/AttentionController.swift" \
  "$ROOT/internal/app/macos/SessionPresentation.swift" \
  "$ROOT/internal/app/macos/SessionPresentationSource.swift" \
  "$ROOT/internal/app/macos/MewsPresentationState.swift" \
  "$ROOT/internal/app/macos/OverlayPlacement.swift" \
  "$ROOT/internal/app/macos/NotchAccessibilityModel.swift" \
  "$ROOT/internal/app/macos/NotchInteractionModel.swift" \
  "$ROOT/internal/app/macos/NotchPanelContent.swift" \
  "$ROOT/internal/app/macos/PixelStatusLogo.swift" \
  "$ROOT/internal/app/macos/NotchShellGeometry.swift" \
  "$ROOT/internal/app/macos/NotchExpandedContentView.swift" \
  "$ROOT/internal/app/macos/SessionListScrollContainer.swift" \
  "$ROOT/internal/app/macos/NotchSessionContentView.swift" \
  "$ROOT/internal/app/macos/NotchShellView.swift" \
  "$ROOT/internal/app/macos/NotchPanelController.swift" \
  "$ROOT/internal/app/macos/tests/MewsAppModelTests.swift" \
  "$ROOT/internal/app/macos/tests/EventAlertRoutingTests.swift" \
  "$ROOT/internal/app/macos/tests/MewsRuntimeHardeningTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateCorruptionTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateMetadataTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateTests.swift" \
  "$ROOT/internal/app/macos/tests/ActiveSessionPanelTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateStoreTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionDismissalTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionDismissalBoundaryTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionDismissalControllerTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionDismissalTestSupport.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateFoundationTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateRecoveryTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionStateRegressionTests.swift" \
  "$ROOT/internal/app/macos/tests/AttentionReconcilerTests.swift" \
  "$ROOT/internal/app/macos/tests/AttentionControllerTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionPresentationTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionPresentationSourceTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchInteractionTests.swift" \
  "$ROOT/internal/app/macos/tests/SessionListScrollContainerTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchShellViewTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchPanelControllerTests.swift" \
  "$ROOT/internal/app/macos/tests/NotchPanelContentTests.swift" \
  "$ROOT/internal/app/macos/tests/PixelStatusLogoTests.swift" \
  -framework AppKit \
  -framework Network \
  -o "$temp_dir/mews-app-model-tests"

MEWS_GO_HEALTH_FIXTURE="$ROOT/internal/health/testdata/runtime-health-go.json" \
  "$temp_dir/mews-app-model-tests"
