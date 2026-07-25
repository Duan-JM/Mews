#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-dev}"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_parse_version "$VERSION"

ARCHIVE="$ROOT/dist/mews-${VERSION}-darwin.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Package archive not found: $ARCHIVE" >&2
  exit 1
fi

SMOKE_DIR="$ROOT/dist/.smoke-${VERSION}-$$"
PACKAGE_DIR="$SMOKE_DIR/mews-${VERSION}-darwin"
AGENT_PID=""
cleanup() {
  if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
    kill "$AGENT_PID" 2>/dev/null || true
    wait "$AGENT_PID" 2>/dev/null || true
  fi
  rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/home"
tar -xzf "$ARCHIVE" -C "$SMOKE_DIR"

install_output="$(
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  PREFIX="$SMOKE_DIR/prefix" \
  "$PACKAGE_DIR/install.sh"
)"
if ! grep -F "does not resolve mw to $SMOKE_DIR/prefix/bin/mw" \
  <<<"$install_output" >/dev/null; then
  echo "Package installer did not explain the custom-prefix PATH requirement" >&2
  echo "$install_output" >&2
  exit 1
fi
if [[ ! -x "$SMOKE_DIR/prefix/bin/mw" ||
      ! -x "$SMOKE_DIR/prefix/libexec/Mews.app/Contents/MacOS/Mews" ]]; then
  echo "Package installer did not install mw and Mews.app" >&2
  exit 1
fi
MW="$SMOKE_DIR/prefix/bin/mw"
APP="$SMOKE_DIR/prefix/libexec/Mews.app"

for executable in \
  "$MW" \
  "$APP/Contents/MacOS/Mews" \
  "$APP/Contents/Resources/mw"; do
  architectures="$(lipo -archs "$executable")"
  if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
    echo "Package executable is not universal: $executable ($architectures)" >&2
    exit 1
  fi
done

version_output="$("$MW" --version)"
if [[ "$version_output" != "mw $VERSION" ]]; then
  echo "Unexpected version output: $version_output" >&2
  exit 1
fi

setup_output="$(
  HOME="$SMOKE_DIR/home" \
  COPILOT_HOME="$SMOKE_DIR/home/.copilot" \
  "$MW" setup
)"
expected_app="$APP"
if ! printf '%s\n' "$setup_output" | grep -F "launch menu bar app: $expected_app" >/dev/null; then
  echo "Setup preview did not find bundled app at $expected_app" >&2
  exit 1
fi

PLIST="$expected_app/Contents/Info.plist"
short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
build_version="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ "$short_version" != "$APP_SHORT_VERSION" || "$build_version" != "$APP_BUILD_VERSION" ]]; then
  echo "Unexpected app version: $short_version/$build_version" >&2
  exit 1
fi

export HOME="$SMOKE_DIR/home"
export COPILOT_HOME="$HOME/.copilot"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CODEX_HOME="$HOME/.codex"
export MEWS_SOCKET_NAMESPACE="package-smoke-$$"
"$MW" setup --yes >/dev/null
"$MW" agent >"$SMOKE_DIR/agent.log" 2>&1 &
AGENT_PID=$!
for _ in {1..50}; do
  if "$MW" status 2>/dev/null | grep -F "Agent: running" >/dev/null; then
    break
  fi
  sleep 0.1
done
if ! "$MW" status | grep -F "Agent: running" >/dev/null; then
  echo "Packaged agent did not become reachable" >&2
  cat "$SMOKE_DIR/agent.log" >&2
  exit 1
fi

copilot_command="$(plutil -extract hooks.agentStop.0.bash raw -o - "$COPILOT_HOME/hooks/mews.json")"
claude_command="$(plutil -extract hooks.PermissionRequest.0.hooks.0.command raw -o - "$CLAUDE_CONFIG_DIR/settings.json")"
printf '%s' '{"cwd":"/tmp/copilot-project","session_id":"copilot-123","prompt":"private copilot prompt"}' |
  /bin/bash -c "$copilot_command"
printf '%s' '{"cwd":"/tmp/claude-project","session_id":"claude-123","prompt":"private claude prompt"}' |
  /bin/bash -c "$claude_command"
"$MW" hook codex \
  '{"cwd":"/tmp/codex-project","thread-id":"codex-123","prompt":"private codex prompt"}' >/dev/null
"$MW" notify \
  --source custom \
  --status "done" \
  --project package-smoke \
  --message "Packaged runtime received event" >/dev/null

history="$("$MW" history)"
for expected in \
  "copilot done (copilot-project)" \
  "claude-code needs_input (claude-project)" \
  "codex done (codex-project)" \
  "custom done (package-smoke)"; do
  if ! grep -F "$expected" <<<"$history" >/dev/null; then
    echo "Packaged history missing: $expected" >&2
    echo "$history" >&2
    exit 1
  fi
done
if grep -R "private .* prompt" "$HOME/Library/Application Support/Mews" >/dev/null; then
  echo "Packaged runtime stored private hook prompt content" >&2
  exit 1
fi

"$MW" stop >/dev/null
wait "$AGENT_PID"
AGENT_PID=""
"$MW" undo >/dev/null
for path in \
  "$COPILOT_HOME/hooks/mews.json" \
  "$CLAUDE_CONFIG_DIR/settings.json" \
  "$CODEX_HOME/config.toml"; do
  if [[ -e "$path" ]]; then
    echo "Packaged undo left integration file: $path" >&2
    exit 1
  fi
done
"$MW" reset --yes >/dev/null
if [[ -e "$HOME/Library/Application Support/Mews" || -e "$HOME/Library/Logs/Mews" ]]; then
  echo "Packaged reset left Mews data behind" >&2
  exit 1
fi

echo "Package smoke passed for $VERSION"
