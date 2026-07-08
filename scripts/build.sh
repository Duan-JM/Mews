#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p bin
rm -f bin/mews
go build -ldflags="-s -w" -o bin/mw ./cmd/mw

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Skipping Mews.app build; macOS is required."
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to build Mews.app" >&2
  exit 1
fi

APP="$ROOT/lib/Mews.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -O \
  -parse-as-library \
  -framework AppKit \
  -o "$APP/Contents/MacOS/Mews" \
  "$ROOT/internal/app/macos/MewsApp.swift"

cp "$ROOT/bin/mw" "$APP/Contents/Resources/mw"
chmod 0755 "$APP/Contents/MacOS/Mews" "$APP/Contents/Resources/mw"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Mews</string>
  <key>CFBundleIdentifier</key>
  <string>dev.mews.Mews</string>
  <key>CFBundleName</key>
  <string>Mews</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0</string>
  <key>CFBundleVersion</key>
  <string>0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © Mews contributors</string>
</dict>
</plist>
PLIST
