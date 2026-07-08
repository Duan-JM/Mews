#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-dev}"
OUT="dist/mews-${VERSION}-darwin"

rm -rf "$OUT"
mkdir -p "$OUT/bin" dist
"$ROOT/scripts/build.sh"
cp bin/mw "$OUT/bin/mw"
cp README.md LICENSE "$OUT/"

tar -czf "${OUT}.tar.gz" -C dist "mews-${VERSION}-darwin"
echo "Created ${OUT}.tar.gz"
