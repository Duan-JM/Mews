#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"

"$ROOT/scripts/build.sh"
install -d "$PREFIX/bin"
install "$ROOT/bin/mw" "$PREFIX/bin/mw"

echo "Installed mw to $PREFIX/bin/mw"
