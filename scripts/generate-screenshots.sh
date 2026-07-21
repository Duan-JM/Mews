#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$ROOT/assets/screenshots"
EXPECTED_WIDTH=840
EXPECTED_HEIGHT=440
EXPECTED_FILES=(
  "mews-status-states.png"
  "mews-multi-session.png"
  "mews-degraded-health.png"
)
EXPECTED_STATES=("idle" "running" "needs_input" "done" "failed")
TEMP_ROOT=""
STAGE_DIR=""
BACKUP_DIR=""

fail() {
  echo "screenshot generation: $*" >&2
  exit 1
}

remove_directory() {
  local path="$1"
  if [[ -n "$path" && -d "$path" ]]; then
    rm -rf -- "$path"
  fi
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$BACKUP_DIR" &&
        -d "$BACKUP_DIR/screenshots" &&
        ! -d "$TARGET_DIR" ]]; then
    mv "$BACKUP_DIR/screenshots" "$TARGET_DIR"
  fi
  remove_directory "$TEMP_ROOT"
  remove_directory "$STAGE_DIR"
  remove_directory "$BACKUP_DIR"
  exit "$status"
}

validate_manifest() {
  local directory="$1"
  local manifest="$directory/manifest.json"
  [[ -s "$manifest" ]] || fail "renderer did not produce manifest.json"
  grep -Fq '"synthetic" : true' "$manifest" ||
    fail "fixture manifest is not marked synthetic"

  local value
  for value in "${EXPECTED_STATES[@]}"; do
    grep -Fq "\"$value\"" "$manifest" ||
      fail "fixture manifest is missing state $value"
  done
  for value in "${EXPECTED_FILES[@]}"; do
    grep -Fq "\"$value\"" "$manifest" ||
      fail "fixture manifest is missing file $value"
  done

  local current_home="${HOME:-}"
  local current_user
  current_user="$(id -un)"
  if [[ -n "$current_home" ]] && grep -Fqi -- "$current_home" "$manifest"; then
    fail "fixture manifest contains the current HOME path"
  fi
  if [[ ${#current_user} -ge 3 ]] && grep -Fqi -- "$current_user" "$manifest"; then
    fail "fixture manifest contains the current username"
  fi
  if grep -Eiq \
    '(/Users/|/home/|file://|prompt|scrollback|terminal[ _-]*output|transcript)' \
    "$manifest"; then
    fail "fixture manifest contains prohibited sensitive text"
  fi
}

validate_images() {
  local directory="$1"
  local image_count
  image_count="$(
    find "$directory" -maxdepth 1 -type f -name '*.png' -print |
      wc -l |
      tr -d ' '
  )"
  [[ "$image_count" == "${#EXPECTED_FILES[@]}" ]] ||
    fail "expected ${#EXPECTED_FILES[@]} PNG files, found $image_count"

  local file
  for file in "${EXPECTED_FILES[@]}"; do
    local path="$directory/$file"
    [[ -s "$path" ]] || fail "missing screenshot $file"
    local width
    local height
    local byte_count
    local properties
    properties="$(sips -g pixelWidth -g pixelHeight "$path" 2>/dev/null)" ||
      fail "could not inspect screenshot $file"
    width="$(awk '/pixelWidth/ {print $2}' <<< "$properties")"
    height="$(awk '/pixelHeight/ {print $2}' <<< "$properties")"
    byte_count="$(wc -c < "$path" | tr -d ' ')"
    [[ "$width" == "$EXPECTED_WIDTH" && "$height" == "$EXPECTED_HEIGHT" ]] ||
      fail "$file has unexpected dimensions ${width}x${height}"
    ((byte_count > 1000)) || fail "$file appears empty"
  done
}

compare_outputs() {
  local first="$1"
  local second="$2"
  local file
  cmp -s "$first/manifest.json" "$second/manifest.json" ||
    fail "fixture manifests differ between renders"
  for file in "${EXPECTED_FILES[@]}"; do
    cmp -s "$first/$file" "$second/$file" ||
      fail "$file differs between deterministic renders"
  done
}

validate_documentation_references() {
  local file
  local document
  for file in "${EXPECTED_FILES[@]}"; do
    for document in "$ROOT/README.md" "$ROOT/README_zh.md"; do
      [[ "$(grep -Fc "assets/screenshots/$file" "$document")" == "1" ]] ||
        fail "$(basename "$document") must reference $file exactly once"
    done
  done
}

validate_existing_target() {
  [[ ! -L "$TARGET_DIR" ]] ||
    fail "refusing to replace a symlink at assets/screenshots"
  if [[ -e "$TARGET_DIR" && ! -d "$TARGET_DIR" ]]; then
    fail "refusing to replace a non-directory at assets/screenshots"
  fi
  [[ -d "$TARGET_DIR" ]] || return
  local entry
  local name
  while IFS= read -r entry; do
    name="${entry##*/}"
    case "$name" in
      mews-status-states.png | mews-multi-session.png | mews-degraded-health.png) ;;
      *) fail "refusing to replace unowned screenshot entry $name" ;;
    esac
  done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print)
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ "$(uname -s)" == "Darwin" ]] ||
  fail "macOS is required to render AppKit screenshots"
for tool in swiftc sips cmp awk find grep; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
validate_documentation_references
validate_existing_target

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mews-screenshots.XXXXXX")"
FIRST_RENDER="$TEMP_ROOT/first"
SECOND_RENDER="$TEMP_ROOT/second"
mkdir -p "$FIRST_RENDER" "$SECOND_RENDER"
RENDERER="$TEMP_ROOT/render-screenshots"
SOURCES=(
  "$ROOT/internal/app/macos/TerminalProfile.swift"
  "$ROOT/internal/app/macos/CLIContext.swift"
  "$ROOT/internal/app/macos/MewsEvent.swift"
  "$ROOT/internal/app/macos/SessionReturnContext.swift"
  "$ROOT/internal/app/macos/SessionState.swift"
  "$ROOT/internal/app/macos/AttentionReconciler.swift"
  "$ROOT/internal/app/macos/RuntimeHealthSnapshot.swift"
  "$ROOT/internal/app/macos/SessionPresentation.swift"
  "$ROOT/internal/app/macos/MewsPresentationState.swift"
  "$ROOT/internal/app/macos/OverlayPlacement.swift"
  "$ROOT/internal/app/macos/NotchAccessibilityModel.swift"
  "$ROOT/internal/app/macos/NotchInteractionModel.swift"
  "$ROOT/internal/app/macos/NotchPanelContent.swift"
  "$ROOT/internal/app/macos/PixelStatusLogo.swift"
  "$ROOT/internal/app/macos/NotchExpandedContentView.swift"
  "$ROOT/internal/app/macos/NotchSessionContentView.swift"
  "$ROOT/internal/app/macos/NotchShellView.swift"
  "$ROOT/scripts/screenshot-fixtures.swift"
  "$ROOT/scripts/render-screenshots.swift"
)

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -module-cache-path "$TEMP_ROOT/module-cache" \
  -framework AppKit \
  -framework Vision \
  -o "$RENDERER" \
  "${SOURCES[@]}"

"$RENDERER" "$FIRST_RENDER"
"$RENDERER" "$SECOND_RENDER"
validate_manifest "$FIRST_RENDER"
validate_manifest "$SECOND_RENDER"
validate_images "$FIRST_RENDER"
validate_images "$SECOND_RENDER"
compare_outputs "$FIRST_RENDER" "$SECOND_RENDER"

STAGE_DIR="$(mktemp -d "$ROOT/assets/.screenshots-stage.XXXXXX")"
for file in "${EXPECTED_FILES[@]}"; do
  cp "$FIRST_RENDER/$file" "$STAGE_DIR/$file"
done
validate_images "$STAGE_DIR"

validate_existing_target
BACKUP_DIR="$(mktemp -d "$ROOT/assets/.screenshots-backup.XXXXXX")"
if [[ -d "$TARGET_DIR" ]]; then
  mv "$TARGET_DIR" "$BACKUP_DIR/screenshots"
fi
if ! mv "$STAGE_DIR" "$TARGET_DIR"; then
  fail "could not replace the screenshot directory"
fi
STAGE_DIR=""
remove_directory "$BACKUP_DIR"
BACKUP_DIR=""

echo "Generated ${#EXPECTED_FILES[@]} synthetic screenshots in assets/screenshots"
