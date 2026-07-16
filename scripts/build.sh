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

mkdir -p bin
rm -f bin/mw

if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! command -v lipo >/dev/null 2>&1; then
    echo "lipo is required to build universal macOS binaries" >&2
    exit 1
  fi
  BUILD_DIR="$ROOT/dist/.build-${VERSION}"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  for arch in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build \
      -ldflags="-s -w -X github.com/Duan-JM/mews/internal/cli.version=${VERSION}" \
      -o "$BUILD_DIR/mw-$arch" \
      ./cmd/mw
  done
  lipo -create "$BUILD_DIR/mw-arm64" "$BUILD_DIR/mw-amd64" -output bin/mw
else
  go build \
    -ldflags="-s -w -X github.com/Duan-JM/mews/internal/cli.version=${VERSION}" \
    -o bin/mw \
    ./cmd/mw
fi

version_output="$("$ROOT/bin/mw" --version)"
if [[ "$version_output" != "mw $VERSION" ]]; then
  echo "Build did not inject VERSION: expected 'mw $VERSION', got '$version_output'" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Skipping Mews.app build; macOS is required."
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to build Mews.app" >&2
  exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to build Mews.app" >&2
  exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil is required to build Mews.app icon" >&2
  exit 1
fi

APP="$ROOT/lib/Mews.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -o "$BUILD_DIR/Mews-arm64" \
  "$ROOT/internal/app/macos/MewsApp.swift"
swiftc \
  -O \
  -parse-as-library \
  -target x86_64-apple-macos13.0 \
  -framework AppKit \
  -o "$BUILD_DIR/Mews-amd64" \
  "$ROOT/internal/app/macos/MewsApp.swift"
lipo -create "$BUILD_DIR/Mews-arm64" "$BUILD_DIR/Mews-amd64" \
  -output "$APP/Contents/MacOS/Mews"

cp "$ROOT/bin/mw" "$APP/Contents/Resources/mw"
cp "$ROOT/assets/mews-logo.svg" "$APP/Contents/Resources/mews-logo.svg"
swift "$ROOT/scripts/generate-icon.swift" \
  "$BUILD_DIR/Mews.iconset" \
  "$APP/Contents/Resources/mews-logo-256.png"
iconutil -c icns "$BUILD_DIR/Mews.iconset" -o "$APP/Contents/Resources/Mews.icns"
chmod 0755 "$APP/Contents/MacOS/Mews" "$APP/Contents/Resources/mw"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Mews</string>
  <key>CFBundleIdentifier</key>
  <string>dev.mews.Mews</string>
  <key>CFBundleIconFile</key>
  <string>Mews</string>
  <key>CFBundleName</key>
  <string>Mews</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_SHORT_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © Mews contributors</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP/Contents/Resources/mw"
codesign --force --sign - "$APP/Contents/MacOS/Mews"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

app_identifier="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$app_identifier" != "dev.mews.Mews" ]]; then
  echo "Built app has unexpected code-signing identifier: $app_identifier" >&2
  exit 1
fi
