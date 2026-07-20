#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${PREFIX%/}/bin"
MW_PATH="$BIN_DIR/mw"

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
if [[ "$PREFIX" == "/usr/local" || "$(command -v mw 2>/dev/null || true)" == "$MW_PATH" ]]; then
  echo "Run: mw setup --yes"
else
  echo "Installed mw, but this shell does not resolve mw to $MW_PATH."
  echo "For the current shell, run:"
  printf '  export PATH=%q:"%s"\n' "$BIN_DIR" "\$PATH"
  echo "Then run: mw setup --yes"
  echo
  echo "Or run now:"
  printf '  %q setup --yes\n' "$MW_PATH"
fi
