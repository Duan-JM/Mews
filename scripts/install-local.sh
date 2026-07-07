#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"

"$ROOT/scripts/build.sh"
install -d "$PREFIX/bin"
install "$ROOT/bin/mews" "$PREFIX/bin/mews"

echo "Installed mews to $PREFIX/bin/mews"

