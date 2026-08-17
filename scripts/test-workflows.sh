#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_WORKFLOW="$ROOT/.github/workflows/package.yml"

grep -F "VERSION=v0.0.1 make package" "$PACKAGE_WORKFLOW" >/dev/null
grep -F "shasum -a 256 -c mews-v0.0.1-darwin.tar.gz.sha256" "$PACKAGE_WORKFLOW" >/dev/null
grep -F "VERSION=v0.0.1 ./scripts/smoke-package.sh" "$PACKAGE_WORKFLOW" >/dev/null
grep -F "CASK_LOCAL_BUILD=1 SKIP_PACKAGE=1 ./scripts/smoke-cask.sh" "$PACKAGE_WORKFLOW" >/dev/null
if grep -F "make release-check" "$PACKAGE_WORKFLOW" >/dev/null; then
  echo "Package CI must not require consumed release changelog fragments." >&2
  exit 1
fi

echo "Workflow tests passed"
