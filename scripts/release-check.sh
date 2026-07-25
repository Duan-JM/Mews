#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-}"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release checks require macOS." >&2
  exit 1
fi
mews_require_release_version "$VERSION"
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
VERSION="$VERSION" CASK_LOCAL_BUILD=1 SKIP_PACKAGE=1 "$ROOT/scripts/smoke-cask.sh"

echo "Release checks passed for $VERSION"
