#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT_DIR="$ROOT/changelog.d"
CHANGELOG="$ROOT/CHANGELOG.md"
MARKER="<!-- changelog release notes start -->"
TYPES=(added changed deprecated removed fixed security)

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/changelog.sh check
  scripts/changelog.sh draft
  scripts/changelog.sh current-version
  scripts/changelog.sh release-check <version>
  scripts/changelog.sh build <version> <YYYY-MM-DD> --yes
EOF
  exit 2
}

fragment_files() {
  find "$FRAGMENT_DIR" -maxdepth 1 -type f -name '*.md' -print | sort
}

validate_fragment() {
  local file="$1"
  local name content
  name="$(basename "$file")"
  if [[ ! "$name" =~ ^([0-9]+|\+[a-z0-9][a-z0-9-]*)\.(added|changed|deprecated|removed|fixed|security)\.md$ ]]; then
    echo "Invalid changelog fragment name: changelog.d/$name" >&2
    return 1
  fi
  content="$(<"$file")"
  if [[ -z "${content//[[:space:]]/}" ]]; then
    echo "Changelog fragment is empty: changelog.d/$name" >&2
    return 1
  fi
  if [[ "$content" == *$'\n'* ]]; then
    echo "Changelog fragment must contain one paragraph on one line: changelog.d/$name" >&2
    return 1
  fi
}

validate_all() {
  local file
  if [[ ! -f "$CHANGELOG" ]]; then
    echo "CHANGELOG.md is missing" >&2
    return 1
  fi
  if ! grep -Fx "$MARKER" "$CHANGELOG" >/dev/null; then
    echo "CHANGELOG.md is missing the release notes marker" >&2
    return 1
  fi
  while IFS= read -r file; do
    validate_fragment "$file"
  done < <(fragment_files)
}

normalize_version() {
  local version="${1#v}"
  if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-dev(\.[1-9][0-9]*)?)?$ ]]; then
    echo "Invalid changelog version: $1" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

render_entries() {
  local version="$1"
  local date="$2"
  local type file name id content heading found
  printf '## [%s] - %s\n' "$version" "$date"
  for type in "${TYPES[@]}"; do
    found=0
    case "$type" in
      added) heading="Added" ;;
      changed) heading="Changed" ;;
      deprecated) heading="Deprecated" ;;
      removed) heading="Removed" ;;
      fixed) heading="Fixed" ;;
      security) heading="Security" ;;
    esac
    while IFS= read -r file; do
      name="$(basename "$file")"
      if [[ "$name" != *".$type.md" ]]; then
        continue
      fi
      if ((found == 0)); then
        printf '\n### %s\n\n' "$heading"
        found=1
      fi
      id="${name%%.*}"
      content="$(<"$file")"
      if [[ "$id" =~ ^[0-9]+$ ]]; then
        printf -- '- %s ([#%s](https://github.com/Duan-JM/Mews/issues/%s))\n' \
          "$content" "$id" "$id"
      else
        printf -- '- %s\n' "$content"
      fi
    done < <(fragment_files)
  done
}

require_fragments() {
  if [[ -z "$(fragment_files)" ]]; then
    echo "No changelog fragments found in changelog.d/" >&2
    return 1
  fi
}

release_check() {
  local version
  version="$(normalize_version "$1")"
  version="${version%%-dev*}"
  validate_all
  if [[ -n "$(fragment_files)" ]]; then
    echo "Release $version has unconsumed changelog fragments:" >&2
    fragment_files | sed "s#^$ROOT/##" >&2
    return 1
  fi
  if ! grep -F "## [$version] -" "$CHANGELOG" >/dev/null; then
    echo "CHANGELOG.md does not contain a $version release section" >&2
    return 1
  fi
}

current_version() {
  local version
  validate_all
  version="$(
    awk '
      /^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$/ {
        value = $0
        sub(/^## \[/, "", value)
        sub(/\] - .*/, "", value)
        print value
        exit
      }
    ' "$CHANGELOG"
  )"
  if [[ -z "$version" ]]; then
    echo "CHANGELOG.md does not contain a released version" >&2
    return 1
  fi
  normalize_version "$version" >/dev/null
  printf 'v%s\n' "$version"
}

build_changelog() {
  local version date confirm temp file
  version="$(normalize_version "$1")"
  if [[ "$version" == *-dev* ]]; then
    echo "CHANGELOG.md release sections require a stable version" >&2
    return 1
  fi
  date="$2"
  confirm="$3"
  if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Release date must use YYYY-MM-DD" >&2
    return 1
  fi
  if [[ "$confirm" != "--yes" ]]; then
    echo "Building CHANGELOG.md consumes fragments; pass --yes to confirm" >&2
    return 1
  fi
  validate_all
  require_fragments
  if grep -F "## [$version] -" "$CHANGELOG" >/dev/null; then
    echo "CHANGELOG.md already contains a $version release section" >&2
    return 1
  fi

  temp="$(mktemp "${CHANGELOG}.tmp.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf '%s\n' "$line"
      if [[ "$line" == "$MARKER" ]]; then
        printf '\n'
        render_entries "$version" "$date"
        printf '\n'
      fi
    done <"$CHANGELOG"
  } >"$temp"
  chmod 0644 "$temp"
  mv "$temp" "$CHANGELOG"
  trap - EXIT

  while IFS= read -r file; do
    rm -f -- "$file"
  done < <(fragment_files)
  echo "Built CHANGELOG.md for $version"
}

mkdir -p "$FRAGMENT_DIR"

case "${1:-}" in
  check)
    [[ "$#" -eq 1 ]] || usage
    validate_all
    ;;
  draft)
    [[ "$#" -eq 1 ]] || usage
    validate_all
    require_fragments
    render_entries "Unreleased" "$(date +%F)"
    ;;
  current-version)
    [[ "$#" -eq 1 ]] || usage
    current_version
    ;;
  release-check)
    [[ "$#" -eq 2 ]] || usage
    release_check "$2"
    ;;
  build)
    [[ "$#" -eq 4 ]] || usage
    build_changelog "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
