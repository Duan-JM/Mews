#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"

if [[ -x "$ROOT/bin/mw" && -d "$ROOT/libexec/Mews.app" ]]; then
  install -d "$PREFIX/bin" "$PREFIX/libexec"
  install "$ROOT/bin/mw" "$PREFIX/bin/mw"
  rm -rf "$PREFIX/libexec/Mews.app"
  if command -v ditto >/dev/null 2>&1; then
    ditto "$ROOT/libexec/Mews.app" "$PREFIX/libexec/Mews.app"
  else
    cp -R "$ROOT/libexec/Mews.app" "$PREFIX/libexec/Mews.app"
  fi
else
  PREFIX="$PREFIX" "$ROOT/scripts/install-local.sh"
fi

echo
echo "Run: mw setup --yes"
