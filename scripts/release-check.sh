#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-}"
SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release checks require macOS." >&2
  exit 1
fi
if [[ ! "$VERSION" =~ $SEMVER_RE ]]; then
  echo "VERSION must be a clean semver tag such as v1.2.3 (got: ${VERSION:-unset})" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "Release checks require a clean worktree." >&2
  git status --short --branch -uall >&2
  exit 1
fi

make test
make lint
VERSION="$VERSION" make package
(
  cd dist
  shasum -a 256 -c "mews-${VERSION}-darwin.tar.gz.sha256"
)
VERSION="$VERSION" "$ROOT/scripts/smoke-package.sh"

echo "Release checks passed for $VERSION"
