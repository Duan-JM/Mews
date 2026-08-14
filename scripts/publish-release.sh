#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${VERSION:?VERSION is required (for example v1.2.3)}"
: "${CONFIRM:?CONFIRM=yes is required for public release publication}"
if [[ "$CONFIRM" != "yes" ]]; then
  echo "CONFIRM=yes is required for public release publication." >&2
  exit 1
fi

REPOSITORY="${REPOSITORY:-Duan-JM/Mews}"
TAP_REPOSITORY="${TAP_REPOSITORY:-Duan-JM/homebrew-mews}"

# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_require_release_version "$VERSION"
if [[ "$CASK_TOKEN" != "mews" ]]; then
  echo "Public release publication requires a stable version (got: $VERSION)." >&2
  exit 1
fi

for tool in codesign curl gh git ruby shasum spctl tar xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for release publication." >&2
    exit 1
  fi
done

ARCHIVE="$ROOT/dist/mews-${VERSION}-darwin.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
CASK="$ROOT/dist/$CASK_FILENAME"
SOURCE="$ROOT/dist/mews-${VERSION}-source.txt"
EXPECTED_URL="https://github.com/${REPOSITORY}/releases/download/${VERSION}/$(basename "$ARCHIVE")"
HEAD_COMMIT="$(git rev-parse HEAD)"

cleanup_paths=()
cleanup() {
  local path
  for path in "${cleanup_paths[@]}"; do
    case "$path" in
      "${TMPDIR:-/tmp}"/mews-publish.*) rm -rf -- "$path" ;;
      *) echo "Refusing to remove unexpected publish path: $path" >&2 ;;
    esac
  done
}
trap cleanup EXIT

require_release_source() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Release publication requires macOS." >&2
    return 1
  fi
  if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "Release publication must run from main." >&2
    return 1
  fi
  git fetch --quiet origin main
  if [[ "$HEAD_COMMIT" != "$(git rev-parse origin/main)" ]]; then
    echo "main must exactly match origin/main before publication." >&2
    return 1
  fi
  if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "Release publication requires a clean worktree." >&2
    git status --short --branch -uall >&2
    return 1
  fi
  "$ROOT/scripts/changelog.sh" release-check "$VERSION"
}

verify_artifacts() {
  local verify_dir app cli details expected_sha
  for path in "$ARCHIVE" "$CHECKSUM" "$CASK" "$SOURCE"; do
    if [[ ! -f "$path" ]]; then
      echo "Release artifact not found: $path" >&2
      return 1
    fi
  done
  if [[ "$(<"$SOURCE")" != "$HEAD_COMMIT" ]]; then
    echo "Release artifacts were built from $(<"$SOURCE"), expected $HEAD_COMMIT." >&2
    return 1
  fi

  (cd "$ROOT/dist" && shasum -a 256 -c "$(basename "$CHECKSUM")")
  ruby -c "$CASK" >/dev/null
  if grep -F "com.apple.quarantine" "$CASK" >/dev/null; then
    echo "Formal release Cask must not bypass Gatekeeper quarantine." >&2
    return 1
  fi
  expected_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  grep -F "sha256 \"$expected_sha\"" "$CASK" >/dev/null
  grep -F "url \"$EXPECTED_URL\"" "$CASK" >/dev/null

  verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/mews-publish.XXXXXX")"
  cleanup_paths+=("$verify_dir")
  tar -xzf "$ARCHIVE" -C "$verify_dir"
  app="$verify_dir/mews-${VERSION}-darwin/libexec/Mews.app"
  if [[ ! -d "$app" ]]; then
    echo "Release archive does not contain Mews.app at the expected path." >&2
    return 1
  fi

  cli="$verify_dir/mews-${VERSION}-darwin/bin/mw"
  codesign --verify --deep --strict --verbose=2 "$app"
  details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  grep -F "Authority=Developer ID Application:" <<<"$details" >/dev/null
  grep -E '^TeamIdentifier=[A-Z0-9]+$' <<<"$details" >/dev/null
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  codesign --verify --strict --verbose=2 "$cli"
  details="$(codesign -dv --verbose=4 "$cli" 2>&1)"
  grep -F "Authority=Developer ID Application:" <<<"$details" >/dev/null
  grep -E '^TeamIdentifier=[A-Z0-9]+$' <<<"$details" >/dev/null
}

remote_tag_commit() {
  local peeled direct
  peeled="$(git ls-remote --tags origin "refs/tags/${VERSION}^{}" | awk 'NR == 1 {print $1}')"
  if [[ -n "$peeled" ]]; then
    printf '%s\n' "$peeled"
    return
  fi
  direct="$(git ls-remote --tags origin "refs/tags/${VERSION}" | awk 'NR == 1 {print $1}')"
  printf '%s\n' "$direct"
}

publish_tag() {
  local remote_commit
  remote_commit="$(remote_tag_commit)"
  if [[ -n "$remote_commit" ]]; then
    if [[ "$remote_commit" != "$HEAD_COMMIT" ]]; then
      echo "Remote tag $VERSION points to $remote_commit, expected $HEAD_COMMIT." >&2
      return 1
    fi
    return
  fi

  if git rev-parse --verify --quiet "refs/tags/$VERSION" >/dev/null; then
    if [[ "$(git rev-list -n 1 "$VERSION")" != "$HEAD_COMMIT" ]]; then
      echo "Local tag $VERSION does not point to HEAD." >&2
      return 1
    fi
  else
    git tag -a "$VERSION" -m "Mews $VERSION"
  fi
  git push origin "refs/tags/$VERSION"
}

release_state() {
  gh release view "$VERSION" \
    --repo "$REPOSITORY" \
    --json tagName,isDraft,isPrerelease,assets \
    --jq '[.tagName, (.isDraft | tostring), (.isPrerelease | tostring), ([.assets[].name] | join(","))] | @tsv' \
    2>/dev/null
}

publish_github_release() {
  local state notes verify_dir asset
  state="$(release_state || true)"
  if [[ -z "$state" ]]; then
    notes="$(mktemp "${TMPDIR:-/tmp}/mews-publish.XXXXXX")"
    cleanup_paths+=("$notes")
    awk -v version="${VERSION#v}" '
      index($0, "## [" version "] - ") == 1 { found = 1; next }
      found && /^## \[/ { exit }
      found { print }
      END { if (!found) exit 1 }
    ' CHANGELOG.md >"$notes"
    gh release create "$VERSION" \
      "$ARCHIVE" "$CHECKSUM" "$CASK" "$SOURCE" \
      --repo "$REPOSITORY" \
      --verify-tag \
      --title "Mews ${VERSION#v}" \
      --notes-file "$notes"
    state="$(release_state)"
  fi

  IFS=$'\t' read -r tag draft prerelease assets <<<"$state"
  if [[ "$tag" != "$VERSION" || "$draft" != "false" || "$prerelease" != "false" ]]; then
    echo "GitHub Release $VERSION is not a published stable release." >&2
    return 1
  fi
  for asset in \
    "$(basename "$ARCHIVE")" \
    "$(basename "$CHECKSUM")" \
    "$(basename "$CASK")" \
    "$(basename "$SOURCE")"; do
    if [[ ",$assets," != *",$asset,"* ]]; then
      gh release upload "$VERSION" "$ROOT/dist/$asset" --repo "$REPOSITORY"
    fi
  done

  verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/mews-publish.XXXXXX")"
  cleanup_paths+=("$verify_dir")
  gh release download "$VERSION" \
    --repo "$REPOSITORY" \
    --dir "$verify_dir" \
    --pattern "$(basename "$ARCHIVE")" \
    --pattern "$(basename "$CHECKSUM")" \
    --pattern "$(basename "$CASK")" \
    --pattern "$(basename "$SOURCE")"
  for asset in "$ARCHIVE" "$CHECKSUM" "$CASK" "$SOURCE"; do
    cmp "$asset" "$verify_dir/$(basename "$asset")"
  done
  (cd "$verify_dir" && shasum -a 256 -c "$(basename "$CHECKSUM")")
  for asset in "$(basename "$ARCHIVE")" "$(basename "$CHECKSUM")"; do
    if [[ "$(curl -L -sS -o /dev/null -w '%{http_code}' \
      "https://github.com/${REPOSITORY}/releases/download/${VERSION}/${asset}")" != "200" ]]; then
      echo "Published release asset is not downloadable: $asset" >&2
      return 1
    fi
  done
}

publish_tap() {
  local tap_dir tap_created=0 actor remote_cask visibility
  tap_dir="$(mktemp -d "${TMPDIR:-/tmp}/mews-publish.XXXXXX")"
  cleanup_paths+=("$tap_dir")

  if ! gh repo view "$TAP_REPOSITORY" >/dev/null 2>&1; then
    gh repo create "$TAP_REPOSITORY" \
      --public \
      --description "Homebrew tap for Mews"
    tap_created=1
  fi
  visibility="$(gh repo view "$TAP_REPOSITORY" --json visibility --jq .visibility)"
  if [[ "$visibility" != "PUBLIC" ]]; then
    echo "Homebrew tap must be public (got: $visibility)." >&2
    return 1
  fi
  gh repo clone "$TAP_REPOSITORY" "$tap_dir/tap"
  if ! git -C "$tap_dir/tap" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$tap_dir/tap" checkout -b main
  fi

  mkdir -p "$tap_dir/tap/Casks"
  cp "$CASK" "$tap_dir/tap/Casks/mews.rb"
  if [[ ! -f "$tap_dir/tap/README.md" ]]; then
    cat >"$tap_dir/tap/README.md" <<'EOF'
# Mews Homebrew Tap

```bash
brew install --cask duan-jm/mews/mews
```
EOF
  fi

  git -C "$tap_dir/tap" add Casks/mews.rb README.md
  if ! git -C "$tap_dir/tap" diff --cached --quiet; then
    actor="$(gh api user --jq .login)"
    git -C "$tap_dir/tap" \
      -c user.name="$actor" \
      -c user.email="${actor}@users.noreply.github.com" \
      commit -m "mews ${VERSION#v}"
    git -C "$tap_dir/tap" push origin HEAD:main
  fi
  if ((tap_created != 0)); then
    gh repo edit "$TAP_REPOSITORY" --default-branch main
  fi

  remote_cask="$(mktemp "${TMPDIR:-/tmp}/mews-publish.XXXXXX")"
  cleanup_paths+=("$remote_cask")
  gh api "repos/${TAP_REPOSITORY}/contents/Casks/mews.rb" \
    -H "Accept: application/vnd.github.raw+json" >"$remote_cask"
  cmp "$CASK" "$remote_cask"
}

require_release_source
verify_artifacts
gh auth status >/dev/null
publish_tag
publish_github_release
publish_tap

echo "Published $VERSION and ${TAP_REPOSITORY}/mews"
