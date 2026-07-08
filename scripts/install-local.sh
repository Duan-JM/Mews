#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"

"$ROOT/scripts/build.sh"
install -d "$PREFIX/bin"
install -d "$PREFIX/libexec"
install "$ROOT/bin/mw" "$PREFIX/bin/mw"
rm -rf "$PREFIX/libexec/Mews.app"
cp -R "$ROOT/lib/Mews.app" "$PREFIX/libexec/Mews.app"

echo "Installed mw to $PREFIX/bin/mw"
echo "Installed Mews.app to $PREFIX/libexec/Mews.app"
