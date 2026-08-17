#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r variable; do
  [[ -n "$variable" ]] && unset "$variable"
done < <(git rev-parse --local-env-vars)
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mews-publish-test.XXXXXX")"

cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/mews-publish-test.*) rm -rf -- "$TEMP_ROOT" ;;
    *) echo "Refusing to remove unexpected test path: $TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PROJECT="$TEMP_ROOT/project"
ORIGIN="$TEMP_ROOT/origin.git"
TAP_ORIGIN="$TEMP_ROOT/tap.git"
FAKE_BIN="$TEMP_ROOT/bin"
GH_STATE="$TEMP_ROOT/gh"
mkdir -p "$PROJECT/scripts" "$PROJECT/dist" "$FAKE_BIN" "$GH_STATE/assets"
TAP_CLONE_URL="$TAP_ORIGIN"
export GH_STATE TAP_CLONE_URL TAP_ORIGIN
printf 'dist/\n' >"$PROJECT/.gitignore"
cp "$ROOT/scripts/publish-release.sh" "$PROJECT/scripts/"
cp "$ROOT/scripts/version.sh" "$PROJECT/scripts/"
cp "$ROOT/scripts/changelog.sh" "$PROJECT/scripts/"
chmod +x "$PROJECT/scripts/"*.sh

cat >"$PROJECT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

<!-- changelog release notes start -->

## [0.0.2] - 2026-08-14

### Fixed

- Publish the preflight Homebrew installation path.
EOF

mkdir -p "$TEMP_ROOT/package/mews-v0.0.2-darwin/libexec/Mews.app" \
  "$TEMP_ROOT/package/mews-v0.0.2-darwin/bin"
cat >"$TEMP_ROOT/package/mews-v0.0.2-darwin/bin/mw" <<'EOF'
#!/usr/bin/env bash
printf 'mw v0.0.2\n'
EOF
chmod +x "$TEMP_ROOT/package/mews-v0.0.2-darwin/bin/mw"
tar -czf "$PROJECT/dist/mews-v0.0.2-darwin.tar.gz" \
  -C "$TEMP_ROOT/package" mews-v0.0.2-darwin
(
  cd "$PROJECT/dist"
  shasum -a 256 mews-v0.0.2-darwin.tar.gz \
    >mews-v0.0.2-darwin.tar.gz.sha256
)
sha="$(shasum -a 256 "$PROJECT/dist/mews-v0.0.2-darwin.tar.gz" | awk '{print $1}')"
cat >"$PROJECT/dist/mews.rb" <<EOF
cask "mews" do
  version "0.0.2"
  sha256 "$sha"
  url "https://github.com/Duan-JM/Mews/releases/download/v#{version}/mews-v#{version}-darwin.tar.gz"
end
EOF
git init --quiet --bare --initial-branch=main "$ORIGIN"
git -C "$PROJECT" init --quiet --initial-branch=main
git -C "$PROJECT" add .
git -C "$PROJECT" \
  -c user.name="Mews publish test" \
  -c user.email="publish-test@mews.invalid" \
  commit --quiet -m "release"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push --quiet -u origin main
git -C "$PROJECT" rev-parse HEAD >"$PROJECT/dist/mews-v0.0.2-source.txt"

cat >"$PROJECT/scripts/smoke-cask.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "${VERSION:-}" = "v0.0.2"
test "${CASK_URL:-}" = \
  "https://github.com/Duan-JM/Mews/releases/download/v0.0.2/mews-v0.0.2-darwin.tar.gz"
test "${CASK_LOCAL_BUILD:-}" = "0"
test "${CASK_ALLOW_ADHOC:-}" = "1"
test "${SKIP_PACKAGE:-}" = "1"
touch "$GH_STATE/smoke"
EOF
chmod +x "$PROJECT/scripts/smoke-cask.sh"
git -C "$PROJECT" add scripts/smoke-cask.sh
git -C "$PROJECT" \
  -c user.name="Mews publish test" \
  -c user.email="publish-test@mews.invalid" \
  commit --quiet --amend --no-edit
git -C "$PROJECT" push --quiet --force origin main
git -C "$PROJECT" rev-parse HEAD >"$PROJECT/dist/mews-v0.0.2-source.txt"

cat >"$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-dv" ]]; then
  echo "Signature=adhoc" >&2
  echo "TeamIdentifier=not set" >&2
fi
EOF
cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_BIN/spctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '200'
EOF
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
  "auth status") exit 0 ;;
  "release view")
    [[ -f "$GH_STATE/release" ]] || exit 1
    printf 'v0.0.2\tfalse\ttrue\tmews-v0.0.2-darwin.tar.gz,mews-v0.0.2-darwin.tar.gz.sha256,mews.rb,mews-v0.0.2-source.txt\n'
    ;;
  "release create")
    touch "$GH_STATE/release"
    for arg in "$@"; do
      [[ -f "$arg" ]] && cp "$arg" "$GH_STATE/assets/"
    done
    ;;
  "release upload")
    for arg in "$@"; do
      [[ -f "$arg" ]] && cp "$arg" "$GH_STATE/assets/"
    done
    ;;
  "release download")
    dir=""
    while (($#)); do
      if [[ "$1" == "--dir" ]]; then
        dir="$2"
        shift 2
      else
        shift
      fi
    done
    cp "$GH_STATE/assets/"* "$dir/"
    ;;
  "repo view")
    [[ -d "$TAP_ORIGIN" ]] || exit 1
    if [[ "$*" == *"--json visibility"* ]]; then
      printf 'PUBLIC\n'
    fi
    ;;
  "api user")
    printf 'Duan-JM\n'
    ;;
  "api repos/"*)
    git --git-dir="$TAP_ORIGIN" show main:Casks/mews.rb
    ;;
  *)
    echo "Unexpected gh command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/"*
git init --quiet --bare --initial-branch=main "$TAP_ORIGIN"
tap_seed="$TEMP_ROOT/tap-seed"
git clone --quiet "$TAP_ORIGIN" "$tap_seed"
git -C "$tap_seed" checkout --quiet -b main
printf '# Mews Homebrew Tap\n' >"$tap_seed/README.md"
git -C "$tap_seed" add README.md
git -C "$tap_seed" \
  -c user.name="Mews publish test" \
  -c user.email="publish-test@mews.invalid" \
  commit --quiet -m "Initialize tap"
git -C "$tap_seed" push --quiet -u origin main

if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    VERSION=v0.0.2 \
    CONFIRM=no \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected publication without CONFIRM=yes to fail." >&2
  exit 1
fi

(
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    TAP_GITHUB_TOKEN=test-token \
    GITHUB_ACTIONS=true \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$(git -C "$PROJECT" rev-parse HEAD)" \
    VERSION=v0.0.2 \
    ./scripts/publish-release.sh
)

test -f "$GH_STATE/smoke"
test "$(git --git-dir="$ORIGIN" rev-list -n 1 v0.0.2)" = \
  "$(git -C "$PROJECT" rev-parse HEAD)"
cmp "$PROJECT/dist/mews.rb" \
  <(git --git-dir="$TAP_ORIGIN" show main:Casks/mews.rb)

(
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    TAP_GITHUB_TOKEN=test-token \
    GITHUB_ACTIONS=true \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$(git -C "$PROJECT" rev-parse HEAD)" \
    VERSION=v0.0.2 \
    ./scripts/publish-release.sh
)

cp "$PROJECT/dist/mews-v0.0.2-darwin.tar.gz" "$TEMP_ROOT/archive.backup"
printf 'tampered\n' >"$GH_STATE/assets/mews-v0.0.2-darwin.tar.gz"
if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    TAP_GITHUB_TOKEN=test-token \
    GITHUB_ACTIONS=true \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$(git -C "$PROJECT" rev-parse HEAD)" \
    VERSION=v0.0.2 \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected a replaced public release asset to fail." >&2
  exit 1
fi
cp "$TEMP_ROOT/archive.backup" "$GH_STATE/assets/mews-v0.0.2-darwin.tar.gz"

git -C "$PROJECT" tag v0.0.3
git -C "$PROJECT" push --quiet origin refs/tags/v0.0.3
if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    TAP_GITHUB_TOKEN=test-token \
    GITHUB_ACTIONS=true \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$(git -C "$PROJECT" rev-parse HEAD)" \
    VERSION=v0.0.2 \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected an older preflight version to fail." >&2
  exit 1
fi
git -C "$PROJECT" push --quiet origin :refs/tags/v0.0.3
git -C "$PROJECT" tag -d v0.0.3 >/dev/null

wrong_commit="$(
  printf 'wrong tag target\n' |
    git -C "$PROJECT" \
      -c user.name="Mews publish test" \
      -c user.email="publish-test@mews.invalid" \
      commit-tree "$(git -C "$PROJECT" rev-parse "HEAD^{tree}")"
)"
git -C "$PROJECT" update-ref refs/tags/test-wrong "$wrong_commit"
git -C "$PROJECT" push --quiet --force \
  origin refs/tags/test-wrong:refs/tags/v0.0.2
if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    TAP_GITHUB_TOKEN=test-token \
    GITHUB_ACTIONS=true \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$(git -C "$PROJECT" rev-parse HEAD)" \
    VERSION=v0.0.2 \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected a mismatched remote tag to fail." >&2
  exit 1
fi

echo "Release publication tests passed"
