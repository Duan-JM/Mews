#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r variable; do
  [[ -n "$variable" ]] && unset "$variable"
done < <(git rev-parse --local-env-vars)
unset VERSION GITHUB_ACTIONS GITHUB_REF GITHUB_SHA
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mews-preflight-test.XXXXXX")"

cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/mews-preflight-test.*) rm -rf -- "$TEMP_ROOT" ;;
    *) echo "Refusing to remove unexpected test path: $TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

PROJECT="$TEMP_ROOT/project"
ORIGIN="$TEMP_ROOT/origin.git"
mkdir -p "$PROJECT/scripts" "$PROJECT/dist"
printf 'dist/\n' >"$PROJECT/.gitignore"
cp "$ROOT/scripts/preflight-release.sh" "$PROJECT/scripts/"
cp "$ROOT/scripts/version.sh" "$PROJECT/scripts/"
cp "$ROOT/scripts/changelog.sh" "$PROJECT/scripts/"

cat >"$PROJECT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

<!-- changelog release notes start -->

## [0.0.2] - 2026-08-17

### Changed

- Automate preflight publication.
EOF

cat >"$PROJECT/scripts/release-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "${VERSION:-}" = "v0.0.2"
mkdir -p dist
touch "dist/mews-${VERSION}-darwin.tar.gz"
EOF

cat >"$PROJECT/scripts/homebrew-cask.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >"$CASK_OUTPUT" <<RUBY
cask "mews" do
  version "${VERSION#v}"
  url "$CASK_URL"
end
RUBY
EOF
chmod +x "$PROJECT/scripts/"*.sh

git init --quiet --bare --initial-branch=main "$ORIGIN"
git -C "$PROJECT" init --quiet --initial-branch=main
git -C "$PROJECT" add .
git -C "$PROJECT" \
  -c user.name="Mews preflight test" \
  -c user.email="preflight-test@mews.invalid" \
  commit --quiet -m "release"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push --quiet -u origin main

(
  cd "$PROJECT"
  ./scripts/preflight-release.sh
)

grep -F 'cask "mews"' "$PROJECT/dist/mews.rb" >/dev/null
grep -F '/releases/download/v#{version}/mews-v#{version}-darwin.tar.gz' \
  "$PROJECT/dist/mews.rb" >/dev/null
test "$(<"$PROJECT/dist/mews-v0.0.2-source.txt")" = \
  "$(git -C "$PROJECT" rev-parse HEAD)"

if (
  cd "$PROJECT"
  VERSION=v0.1.0 ./scripts/preflight-release.sh
) >/dev/null 2>&1; then
  echo "Expected a non-preflight version to fail." >&2
  exit 1
fi

echo "Preflight release tests passed"
