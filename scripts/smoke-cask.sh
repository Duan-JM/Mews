#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Cask smoke requires macOS." >&2
  exit 1
fi
for tool in brew codesign git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for Cask smoke." >&2
    exit 1
  fi
done
export HOMEBREW_NO_AUTO_UPDATE=1

VERSION="${VERSION:-v0.1.0-dev.1}"
CASK_LOCAL_BUILD="${CASK_LOCAL_BUILD:-1}"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_require_release_version "$VERSION"

if [[ "${SKIP_PACKAGE:-0}" != "1" ]]; then
  VERSION="$VERSION" "$ROOT/scripts/package.sh"
fi

ARCHIVE="$ROOT/dist/mews-${VERSION}-darwin.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Package archive not found: $ARCHIVE" >&2
  exit 1
fi

SMOKE_DIR="$ROOT/dist/.cask-smoke-${VERSION}-$$"
TAP_DIR="$SMOKE_DIR/tap"
HOME_DIR="$SMOKE_DIR/home"
APP_DIR="$SMOKE_DIR/Applications"
BIN_DIR="$SMOKE_DIR/bin"
APP="$APP_DIR/Mews.app"
MW="$BIN_DIR/mw"
TAP_NAME="mews-smoke/local-$$"
TAP_URL="file://${TAP_DIR}"
# Keep Homebrew 6's local-cask trust record inside the disposable smoke workspace.
export XDG_CONFIG_HOME="$SMOKE_DIR/config"
TAPPED=0
INSTALLED=0
APP_PID=""
AGENT_PID=""

find_smoke_agent_pid() {
  ps -axo pid=,command= |
    awk -v expected="$APP/Contents/Resources/mw agent" '
      {
        pid = $1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        if ($0 == expected && agent == "") {
          agent = pid
        }
      }
      END { print agent }'
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  trap - EXIT
  set +e
  if [[ -z "$AGENT_PID" ]]; then
    AGENT_PID="$(find_smoke_agent_pid)"
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
    kill "$AGENT_PID" 2>/dev/null
    for _ in {1..50}; do
      if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      echo "Could not stop smoke agent process $AGENT_PID." >&2
      cleanup_failed=1
    fi
  fi
  if ((INSTALLED != 0)); then
    if brew uninstall --cask "${TAP_NAME}/${CASK_TOKEN}" >/dev/null; then
      INSTALLED=0
    else
      echo "Could not uninstall smoke Cask ${TAP_NAME}/${CASK_TOKEN}." >&2
      cleanup_failed=1
    fi
  fi
  if ((TAPPED != 0)); then
    if brew untap "$TAP_NAME" >/dev/null; then
      TAPPED=0
    else
      echo "Could not remove smoke tap $TAP_NAME." >&2
      cleanup_failed=1
    fi
  fi
  if ((cleanup_failed == 0)); then
    if ! rm -rf "$SMOKE_DIR"; then
      echo "Could not remove Cask smoke workspace: $SMOKE_DIR" >&2
      cleanup_failed=1
    fi
  else
    echo "Preserved failed Cask smoke workspace: $SMOKE_DIR" >&2
  fi
  if ((cleanup_failed != 0 && status == 0)); then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$TAP_DIR/Casks" "$HOME_DIR" "$APP_DIR" "$BIN_DIR"
CASK_URL="file://${ARCHIVE}" \
  CASK_BINARY_TARGET="$MW" \
  CASK_LOCAL_BUILD="$CASK_LOCAL_BUILD" \
  CASK_OUTPUT="$TAP_DIR/Casks/$CASK_FILENAME" \
  VERSION="$VERSION" \
  "$ROOT/scripts/homebrew-cask.sh"
if [[ "$CASK_LOCAL_BUILD" == "1" ]]; then
  if ! grep -F "com.apple.quarantine" "$TAP_DIR/Casks/$CASK_FILENAME" >/dev/null; then
    echo "Local Cask does not contain the quarantine-removal postflight." >&2
    exit 1
  fi
elif grep -F "com.apple.quarantine" "$TAP_DIR/Casks/$CASK_FILENAME" >/dev/null; then
  echo "Release Cask unexpectedly contains the local quarantine bypass." >&2
  exit 1
fi
git init --quiet --initial-branch=main "$TAP_DIR"
git -C "$TAP_DIR" add Casks
git -C "$TAP_DIR" \
  -c user.name="Mews Cask smoke" \
  -c user.email="cask-smoke@mews.invalid" \
  commit --quiet -m "Add ${CASK_TOKEN} ${VERSION}"

brew tap "$TAP_NAME" "$TAP_URL" >/dev/null
TAPPED=1
brew install --cask --appdir="$APP_DIR" "${TAP_NAME}/${CASK_TOKEN}"
INSTALLED=1

if [[ ! -x "$MW" || ! -x "$APP/Contents/MacOS/Mews" ]]; then
  echo "Homebrew did not install the mw CLI and Mews.app." >&2
  exit 1
fi
if [[ "$CASK_LOCAL_BUILD" == "1" ]]; then
  if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    echo "Local Cask installation unexpectedly quarantined Mews.app." >&2
    exit 1
  fi
else
  spctl --assess --type execute --verbose=4 "$APP"
fi
version_output="$("$MW" --version)"
if [[ "$version_output" != "mw $VERSION" ]]; then
  echo "Installed mw reports $version_output, want mw $VERSION." >&2
  ls -l "$MW" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

export HOME="$HOME_DIR"
export COPILOT_HOME="$HOME/.copilot"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CODEX_HOME="$HOME/.codex"
export MEWS_SOCKET_NAMESPACE="cask-smoke-$$"

setup_output="$("$MW" setup)"
if ! grep -F "launch menu bar app: $APP" <<<"$setup_output" >/dev/null; then
  echo "Cask setup preview did not resolve $APP." >&2
  echo "$setup_output" >&2
  exit 1
fi
"$MW" setup --yes >/dev/null
"$APP/Contents/MacOS/Mews" >"$SMOKE_DIR/app.log" 2>&1 &
APP_PID=$!
for _ in {1..50}; do
  if "$MW" status 2>/dev/null | grep -F "Agent: running" >/dev/null; then
    break
  fi
  sleep 0.1
done
if ! "$MW" status | grep -F "Agent: running" >/dev/null; then
  echo "Cask-installed Mews agent did not become reachable." >&2
  cat "$SMOKE_DIR/app.log" >&2
  exit 1
fi
AGENT_PID="$(find_smoke_agent_pid)"
if [[ -z "$AGENT_PID" ]]; then
  echo "Could not identify the Cask-installed mw agent process." >&2
  exit 1
fi

if kill -0 "$APP_PID" 2>/dev/null; then
  kill "$APP_PID"
fi
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
if kill -0 "$AGENT_PID" 2>/dev/null; then
  kill "$AGENT_PID"
fi
for _ in {1..50}; do
  if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$AGENT_PID" 2>/dev/null; then
  echo "Cask-installed mw agent did not stop." >&2
  exit 1
fi
AGENT_PID=""
brew uninstall --cask "${TAP_NAME}/${CASK_TOKEN}" >/dev/null
INSTALLED=0
if [[ -e "$APP" || -e "$MW" ]]; then
  echo "Homebrew Cask uninstall left installed artifacts behind." >&2
  exit 1
fi
brew untap "$TAP_NAME" >/dev/null
TAPPED=0

echo "Cask smoke passed for $VERSION"
