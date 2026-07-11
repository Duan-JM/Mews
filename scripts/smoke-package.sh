#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-dev}"
SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ "$VERSION" == "dev" ]]; then
  APP_SHORT_VERSION="0.0.0"
  APP_BUILD_VERSION="0"
elif [[ "$VERSION" =~ $SEMVER_RE ]]; then
  APP_SHORT_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  APP_BUILD_VERSION="$APP_SHORT_VERSION"
else
  echo "VERSION must be dev or a clean semver tag such as v1.2.3 (got: $VERSION)" >&2
  exit 1
fi

ARCHIVE="$ROOT/dist/mews-${VERSION}-darwin.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Package archive not found: $ARCHIVE" >&2
  exit 1
fi

SMOKE_DIR="$ROOT/dist/.smoke-${VERSION}-$$"
PACKAGE_DIR="$SMOKE_DIR/mews-${VERSION}-darwin"
trap 'rm -rf "$SMOKE_DIR"' EXIT
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/home"
tar -xzf "$ARCHIVE" -C "$SMOKE_DIR"

PREFIX="$SMOKE_DIR/prefix" "$PACKAGE_DIR/install.sh" >/dev/null
if [[ ! -x "$SMOKE_DIR/prefix/bin/mw" ||
      ! -x "$SMOKE_DIR/prefix/libexec/Mews.app/Contents/MacOS/Mews" ]]; then
  echo "Package installer did not install mw and Mews.app" >&2
  exit 1
fi

for executable in \
  "$PACKAGE_DIR/bin/mw" \
  "$PACKAGE_DIR/libexec/Mews.app/Contents/MacOS/Mews" \
  "$PACKAGE_DIR/libexec/Mews.app/Contents/Resources/mw"; do
  architectures="$(lipo -archs "$executable")"
  if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
    echo "Package executable is not universal: $executable ($architectures)" >&2
    exit 1
  fi
done

version_output="$("$PACKAGE_DIR/bin/mw" --version)"
if [[ "$version_output" != "mw $VERSION" ]]; then
  echo "Unexpected version output: $version_output" >&2
  exit 1
fi

setup_output="$(
  HOME="$SMOKE_DIR/home" \
  COPILOT_HOME="$SMOKE_DIR/home/.copilot" \
  "$PACKAGE_DIR/bin/mw" setup
)"
expected_app="$PACKAGE_DIR/libexec/Mews.app"
if ! printf '%s\n' "$setup_output" | grep -F "launch menu bar app: $expected_app" >/dev/null; then
  echo "Setup preview did not find bundled app at $expected_app" >&2
  exit 1
fi

PLIST="$expected_app/Contents/Info.plist"
short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
build_version="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ "$short_version" != "$APP_SHORT_VERSION" || "$build_version" != "$APP_BUILD_VERSION" ]]; then
  echo "Unexpected app version: $short_version/$build_version" >&2
  exit 1
fi

echo "Package smoke passed for $VERSION"
