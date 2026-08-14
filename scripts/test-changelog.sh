#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mews-changelog-test.XXXXXX")"

cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/mews-changelog-test.*) rm -rf -- "$TEMP_ROOT" ;;
    *) echo "Refusing to remove unexpected test path: $TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "$TEMP_ROOT/scripts" "$TEMP_ROOT/changelog.d"
cp "$ROOT/scripts/changelog.sh" "$TEMP_ROOT/scripts/changelog.sh"
chmod +x "$TEMP_ROOT/scripts/changelog.sh"
cat >"$TEMP_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

<!-- changelog release notes start -->
EOF

printf '%s\n' "Add typed changelog fragments." >"$TEMP_ROOT/changelog.d/87.added.md"
printf '%s\n' "Document release consumption." >"$TEMP_ROOT/changelog.d/+release-docs.changed.md"

"$TEMP_ROOT/scripts/changelog.sh" check
draft="$("$TEMP_ROOT/scripts/changelog.sh" draft)"
grep -F "### Added" <<<"$draft" >/dev/null
grep -F "[#87](https://github.com/Duan-JM/Mews/issues/87)" <<<"$draft" >/dev/null
grep -F "### Changed" <<<"$draft" >/dev/null

if "$TEMP_ROOT/scripts/changelog.sh" build v0.0.1 2026-08-14 >/dev/null 2>&1; then
  echo "Expected changelog build without --yes to fail" >&2
  exit 1
fi
"$TEMP_ROOT/scripts/changelog.sh" build v0.0.1 2026-08-14 --yes
"$TEMP_ROOT/scripts/changelog.sh" release-check v0.0.1
"$TEMP_ROOT/scripts/changelog.sh" release-check v0.0.1-dev.1
grep -F "## [0.0.1] - 2026-08-14" "$TEMP_ROOT/CHANGELOG.md" >/dev/null
if find "$TEMP_ROOT/changelog.d" -type f -name '*.md' | grep -q .; then
  echo "Expected changelog fragments to be consumed" >&2
  exit 1
fi

printf '%s\n' "Bad fragment." >"$TEMP_ROOT/changelog.d/not-valid.md"
if "$TEMP_ROOT/scripts/changelog.sh" check >/dev/null 2>&1; then
  echo "Expected invalid fragment name to fail" >&2
  exit 1
fi

printf '%s\n' "Preview a later release." >"$TEMP_ROOT/changelog.d/88.changed.md"
if "$TEMP_ROOT/scripts/changelog.sh" build v0.0.2-dev.1 2026-08-15 --yes >/dev/null 2>&1; then
  echo "Expected prerelease changelog build to fail" >&2
  exit 1
fi

echo "Changelog tests passed"
