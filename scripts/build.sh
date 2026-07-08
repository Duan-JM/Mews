#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p bin
rm -f bin/mews
go build -ldflags="-s -w" -o bin/mw ./cmd/mw
