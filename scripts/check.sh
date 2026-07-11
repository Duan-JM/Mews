#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

gofmt_out="$(gofmt -l cmd internal)"
if [[ -n "$gofmt_out" ]]; then
  echo "gofmt needed:"
  echo "$gofmt_out"
  exit 1
fi

go vet ./...

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck is required for shell script lint" >&2
  exit 1
fi
shellcheck install.sh scripts/*.sh
