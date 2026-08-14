#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$ROOT/.tools/bin:$PATH"

"$ROOT/scripts/changelog.sh" check

gofmt_out="$(gofmt -l cmd internal)"
if [[ -n "$gofmt_out" ]]; then
  echo "gofmt needed:"
  echo "$gofmt_out"
  exit 1
fi

for tool in golangci-lint swiftlint shellcheck; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required; run \`make lint-tools\`" >&2
    exit 1
  fi
done

oversized=0
while IFS= read -r file; do
  max_lines=500
  if [[ "$file" == *_test.go ]]; then
    max_lines=700
  fi
  line_count="$(wc -l < "$file" | tr -d ' ')"
  if ((line_count > max_lines)); then
    echo "$file has $line_count lines; maximum is $max_lines" >&2
    oversized=1
  fi
done < <(
  find cmd internal scripts -type f \
    \( -name '*.go' -o -name '*.swift' -o -name '*.sh' \) \
    | sort
)
if ((oversized != 0)); then
  exit 1
fi

golangci-lint config verify
golangci-lint run
swiftlint lint --strict --quiet --disable-sourcekit --config "$ROOT/.swiftlint.yml"

shellcheck install.sh scripts/*.sh
