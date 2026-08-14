#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release requires macOS." >&2
  exit 1
fi

: "${VERSION:?VERSION is required (for example v1.2.3 or v1.2.3-dev.1)}"
: "${SIGN_IDENTITY:?SIGN_IDENTITY is required for Developer ID signing}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is required for xcrun notarytool}"

# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_require_release_version "$VERSION"
REPOSITORY="${REPOSITORY:-Duan-JM/Mews}"

for tool in codesign ditto shasum spctl xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for release." >&2
    exit 1
  fi
done

branch="$(git branch --show-current)"
if [[ "$branch" != "main" ]]; then
  echo "Formal releases must run from main (current branch: ${branch:-detached})." >&2
  exit 1
fi
git fetch --quiet origin main
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  echo "origin/main is unavailable; fetch it before releasing." >&2
  exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "main must exactly match origin/main before releasing." >&2
  exit 1
fi

VERSION="$VERSION" "$ROOT/scripts/release-check.sh"
VERSION="$VERSION" "$ROOT/scripts/build.sh"

APP="$ROOT/lib/Mews.app"
CLI="$ROOT/bin/mw"
NOTARY_ZIP="$ROOT/dist/.mews-${VERSION}-notary.zip"
CHECKSUM_NAME="mews-${VERSION}-darwin.tar.gz.sha256"

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$CLI"
cp "$CLI" "$APP/Contents/Resources/mw"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/Mews"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$CLI"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p dist
rm -f "$NOTARY_ZIP"
trap 'rm -f "$NOTARY_ZIP"' EXIT
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

VERSION="$VERSION" SKIP_BUILD=1 "$ROOT/scripts/package.sh"
(
  cd dist
  shasum -a 256 -c "$CHECKSUM_NAME"
)
VERSION="$VERSION" "$ROOT/scripts/smoke-package.sh"
VERSION="$VERSION" CASK_LOCAL_BUILD=0 SKIP_PACKAGE=1 "$ROOT/scripts/smoke-cask.sh"
CASK_PATH="$ROOT/dist/$CASK_FILENAME"
SOURCE_PATH="$ROOT/dist/mews-${VERSION}-source.txt"
RELEASE_CASK_URL="https://github.com/${REPOSITORY}/releases/download/${VERSION}/mews-${VERSION}-darwin.tar.gz"
VERSION="$VERSION" \
  REPOSITORY="$REPOSITORY" \
  CASK_URL="$RELEASE_CASK_URL" \
  CASK_OUTPUT="$CASK_PATH" \
  CASK_BINARY_TARGET="mw" \
  CASK_LOCAL_BUILD=0 \
  "$ROOT/scripts/homebrew-cask.sh"
if grep -F "com.apple.quarantine" "$CASK_PATH" >/dev/null; then
  echo "Formal release Cask must not bypass Gatekeeper quarantine." >&2
  exit 1
fi
git rev-parse HEAD >"$SOURCE_PATH"

echo "Release artifact ready: dist/mews-${VERSION}-darwin.tar.gz"
echo "Homebrew Cask ready: dist/$CASK_FILENAME"
echo "Release source ready: dist/$(basename "$SOURCE_PATH")"
