#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"

assert_equal() {
  local got="$1"
  local want="$2"
  local label="$3"
  if [[ "$got" != "$want" ]]; then
    echo "$label = $got, want $want" >&2
    exit 1
  fi
}

assert_version() {
  local version="$1"
  local short_version="$2"
  local build_version="$3"
  local cask_version="$4"
  local cask_token="$5"
  local cask_filename="$6"

  mews_parse_version "$version"
  assert_equal "$APP_SHORT_VERSION" "$short_version" "APP_SHORT_VERSION"
  assert_equal "$APP_BUILD_VERSION" "$build_version" "APP_BUILD_VERSION"
  assert_equal "$CASK_VERSION" "$cask_version" "CASK_VERSION"
  assert_equal "$CASK_TOKEN" "$cask_token" "CASK_TOKEN"
  assert_equal "$CASK_FILENAME" "$cask_filename" "CASK_FILENAME"
}

assert_invalid() {
  local version="$1"
  if mews_parse_version "$version" >/dev/null 2>&1; then
    echo "Expected invalid version: $version" >&2
    exit 1
  fi
}

assert_version "dev" "0.0.0" "0" "0.0.0-dev" "mews@dev" "mews@dev.rb"
assert_version "v0.1.0-dev" "0.1.0" "0.1.0" "0.1.0-dev" "mews@dev" "mews@dev.rb"
assert_version "v0.1.0-dev.1" "0.1.0" "0.1.0" "0.1.0-dev.1" "mews@dev" "mews@dev.rb"
assert_version "v0.0.2" "0.0.2" "0.0.2" "0.0.2" "mews" "mews.rb"
assert_version "v1.2.3" "1.2.3" "1.2.3" "1.2.3" "mews" "mews.rb"

assert_invalid ""
assert_invalid "0.1.0"
assert_invalid "v01.2.3"
assert_invalid "v0.1.0-dev.0"
assert_invalid "v0.1.0-beta.1"

if mews_require_release_version "dev" >/dev/null 2>&1; then
  echo "Expected dev to be rejected as a release version" >&2
  exit 1
fi
mews_require_release_version "v0.1.0-dev.1"
mews_require_release_version "v1.2.3"

echo "Version tests passed"
