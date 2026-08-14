#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
printf 'dist/\n' >"$PROJECT/.gitignore"
cp "$ROOT/scripts/publish-release.sh" "$PROJECT/scripts/"
cp "$ROOT/scripts/version.sh" "$PROJECT/scripts/"
cp "$ROOT/scripts/changelog.sh" "$PROJECT/scripts/"
chmod +x "$PROJECT/scripts/"*.sh

cat >"$PROJECT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

<!-- changelog release notes start -->

## [1.2.3] - 2026-08-14

### Fixed

- Publish the stable Homebrew installation path.
EOF

mkdir -p "$TEMP_ROOT/package/mews-v1.2.3-darwin/libexec/Mews.app" \
  "$TEMP_ROOT/package/mews-v1.2.3-darwin/bin"
touch "$TEMP_ROOT/package/mews-v1.2.3-darwin/bin/mw"
tar -czf "$PROJECT/dist/mews-v1.2.3-darwin.tar.gz" \
  -C "$TEMP_ROOT/package" mews-v1.2.3-darwin
(
  cd "$PROJECT/dist"
  shasum -a 256 mews-v1.2.3-darwin.tar.gz \
    >mews-v1.2.3-darwin.tar.gz.sha256
)
sha="$(shasum -a 256 "$PROJECT/dist/mews-v1.2.3-darwin.tar.gz" | awk '{print $1}')"
cat >"$PROJECT/dist/mews.rb" <<EOF
cask "mews" do
  version "1.2.3"
  sha256 "$sha"
  url "https://github.com/Duan-JM/Mews/releases/download/v1.2.3/mews-v1.2.3-darwin.tar.gz"
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
git -C "$PROJECT" rev-parse HEAD >"$PROJECT/dist/mews-v1.2.3-source.txt"

cat >"$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-dv" ]]; then
  echo "Authority=Developer ID Application: Test (TEAM123456)" >&2
  echo "TeamIdentifier=TEAM123456" >&2
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
    printf 'v1.2.3\tfalse\tfalse\tmews-v1.2.3-darwin.tar.gz,mews-v1.2.3-darwin.tar.gz.sha256,mews.rb,mews-v1.2.3-source.txt\n'
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
  "repo create")
    git init --quiet --bare --initial-branch=main "$TAP_ORIGIN"
    ;;
  "repo clone")
    git clone --quiet "$TAP_ORIGIN" "${4}"
    ;;
  "repo edit") exit 0 ;;
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

if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    GH_STATE="$GH_STATE" \
    TAP_ORIGIN="$TAP_ORIGIN" \
    VERSION=v1.2.3 \
    CONFIRM=no \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected publication without CONFIRM=yes to fail." >&2
  exit 1
fi

(
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    GH_STATE="$GH_STATE" \
    TAP_ORIGIN="$TAP_ORIGIN" \
    VERSION=v1.2.3 \
    CONFIRM=yes \
    ./scripts/publish-release.sh
)

test "$(git --git-dir="$ORIGIN" rev-list -n 1 v1.2.3)" = \
  "$(git -C "$PROJECT" rev-parse HEAD)"
cmp "$PROJECT/dist/mews.rb" \
  <(git --git-dir="$TAP_ORIGIN" show main:Casks/mews.rb)

(
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    GH_STATE="$GH_STATE" \
    TAP_ORIGIN="$TAP_ORIGIN" \
    VERSION=v1.2.3 \
    CONFIRM=yes \
    ./scripts/publish-release.sh
)

cp "$PROJECT/dist/mews-v1.2.3-darwin.tar.gz" "$TEMP_ROOT/archive.backup"
printf 'tampered\n' >"$GH_STATE/assets/mews-v1.2.3-darwin.tar.gz"
if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    GH_STATE="$GH_STATE" \
    TAP_ORIGIN="$TAP_ORIGIN" \
    VERSION=v1.2.3 \
    CONFIRM=yes \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected a replaced public release asset to fail." >&2
  exit 1
fi
cp "$TEMP_ROOT/archive.backup" "$GH_STATE/assets/mews-v1.2.3-darwin.tar.gz"

wrong_commit="$(
  printf 'wrong tag target\n' |
    git -C "$PROJECT" \
      -c user.name="Mews publish test" \
      -c user.email="publish-test@mews.invalid" \
      commit-tree "$(git -C "$PROJECT" rev-parse "HEAD^{tree}")"
)"
git -C "$PROJECT" update-ref refs/tags/test-wrong "$wrong_commit"
git -C "$PROJECT" push --quiet --force \
  origin refs/tags/test-wrong:refs/tags/v1.2.3
if (
  cd "$PROJECT"
  PATH="$FAKE_BIN:$PATH" \
    GH_STATE="$GH_STATE" \
    TAP_ORIGIN="$TAP_ORIGIN" \
    VERSION=v1.2.3 \
    CONFIRM=yes \
    ./scripts/publish-release.sh
) >/dev/null 2>&1; then
  echo "Expected a mismatched remote tag to fail." >&2
  exit 1
fi

echo "Release publication tests passed"
