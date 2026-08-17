#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Preflight releases require macOS." >&2
  exit 1
fi

VERSION="${VERSION:-$("$ROOT/scripts/changelog.sh" current-version)}"
if [[ ! "$VERSION" =~ ^v0\.0\.[1-9][0-9]*$ ]]; then
  echo "Preflight releases require a v0.0.N version (got: $VERSION)." >&2
  exit 1
fi

# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_require_release_version "$VERSION"

if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  if [[ "${GITHUB_REF:-}" != "refs/heads/main" || "${GITHUB_SHA:-}" != "$(git rev-parse HEAD)" ]]; then
    echo "Automated preflight releases require the triggering main commit." >&2
    exit 1
  fi
elif [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Preflight releases must run from main." >&2
  exit 1
fi
git fetch --quiet origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "main must exactly match origin/main before a preflight release." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "Preflight releases require a clean worktree." >&2
  git status --short --branch -uall >&2
  exit 1
fi

VERSION="$VERSION" "$ROOT/scripts/release-check.sh"

CASK_PATH="$ROOT/dist/$CASK_FILENAME"
SOURCE_PATH="$ROOT/dist/mews-${VERSION}-source.txt"
REPOSITORY="${REPOSITORY:-Duan-JM/Mews}"
RELEASE_CASK_URL="https://github.com/${REPOSITORY}/releases/download/v#{version}/mews-v#{version}-darwin.tar.gz"
VERSION="$VERSION" \
  REPOSITORY="$REPOSITORY" \
  CASK_URL="$RELEASE_CASK_URL" \
  CASK_OUTPUT="$CASK_PATH" \
  CASK_BINARY_TARGET="mw" \
  CASK_LOCAL_BUILD=0 \
  CASK_PREFLIGHT=1 \
  "$ROOT/scripts/homebrew-cask.sh"
if grep -F 'system_command "/usr/bin/xattr"' "$CASK_PATH" >/dev/null; then
  echo "Published preflight Casks must not remove Gatekeeper quarantine." >&2
  exit 1
fi
git rev-parse HEAD >"$SOURCE_PATH"

echo "Preflight artifact ready: dist/mews-${VERSION}-darwin.tar.gz"
echo "Homebrew Cask ready: dist/$CASK_FILENAME"
echo "Release source ready: dist/$(basename "$SOURCE_PATH")"
