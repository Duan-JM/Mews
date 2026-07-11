#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-dev}"
SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
OUT="dist/mews-${VERSION}-darwin"
ARCHIVE="${OUT}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"

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

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/libexec" dist

if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  if [[ ! -x "$ROOT/bin/mw" ]]; then
    echo "SKIP_BUILD=1 requires an existing executable at bin/mw" >&2
    exit 1
  fi
  if [[ ! -x "$ROOT/lib/Mews.app/Contents/MacOS/Mews" ]]; then
    echo "SKIP_BUILD=1 requires an existing Mews.app build at lib/Mews.app" >&2
    exit 1
  fi
else
  VERSION="$VERSION" "$ROOT/scripts/build.sh"
fi

for executable in "$ROOT/bin/mw" "$ROOT/lib/Mews.app/Contents/Resources/mw"; do
  if [[ ! -x "$executable" ]]; then
    echo "Package requires an existing executable at ${executable#"$ROOT/"}" >&2
    exit 1
  fi
  version_output="$("$executable" --version)"
  if [[ "$version_output" != "mw $VERSION" ]]; then
    echo "Existing build version does not match VERSION: expected 'mw $VERSION', got '$version_output'" >&2
    exit 1
  fi
done

PLIST="$ROOT/lib/Mews.app/Contents/Info.plist"
short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
build_version="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ "$short_version" != "$APP_SHORT_VERSION" || "$build_version" != "$APP_BUILD_VERSION" ]]; then
  echo "Existing app version does not match VERSION: got $short_version/$build_version" >&2
  exit 1
fi

cp bin/mw "$OUT/bin/mw"
if command -v ditto >/dev/null 2>&1; then
  ditto lib/Mews.app "$OUT/libexec/Mews.app"
else
  cp -R lib/Mews.app "$OUT/libexec/Mews.app"
fi
cp README.md README_zh.md LICENSE SECURITY.md SECURITY_AUDIT.md CONTRIBUTING.md install.sh "$OUT/"
cp -R docs "$OUT/docs"

rm -f "$ARCHIVE" "$CHECKSUM"
tar -czf "$ARCHIVE" -C dist "mews-${VERSION}-darwin"

archive_name="$(basename "$ARCHIVE")"
checksum_name="$(basename "$CHECKSUM")"
if command -v shasum >/dev/null 2>&1; then
  (
    cd dist
    shasum -a 256 "$archive_name" > "$checksum_name"
  )
elif command -v sha256sum >/dev/null 2>&1; then
  (
    cd dist
    sha256sum "$archive_name" > "$checksum_name"
  )
else
  echo "shasum or sha256sum is required to create a SHA-256 checksum" >&2
  exit 1
fi

echo "Created $ARCHIVE"
echo "Created $CHECKSUM"
