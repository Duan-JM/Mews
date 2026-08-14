#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${VERSION:?VERSION is required and must be a tagged version such as v1.2.3-dev.1}"
REPOSITORY="${REPOSITORY:-Duan-JM/Mews}"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_require_release_version "$VERSION"

ARCHIVE="dist/mews-${VERSION}-darwin.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Release archive not found: $ARCHIVE" >&2
  exit 1
fi

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
CASK_URL="${CASK_URL:-https://github.com/${REPOSITORY}/releases/download/${VERSION}/mews-${VERSION}-darwin.tar.gz}"
CASK_OUTPUT="${CASK_OUTPUT:-dist/${CASK_FILENAME}}"
CASK_BINARY_TARGET="${CASK_BINARY_TARGET:-mw}"
CASK_LOCAL_BUILD="${CASK_LOCAL_BUILD:-0}"
mkdir -p "$(dirname "$CASK_OUTPUT")"

cat > "$CASK_OUTPUT" <<RUBY
cask "${CASK_TOKEN}" do
  version "${CASK_VERSION}"
  sha256 "${SHA256}"

  url "${CASK_URL}"
  name "Mews"
  desc "Local companion for terminal AI agents"
  homepage "https://github.com/${REPOSITORY}"

  depends_on macos: :ventura

  app "mews-v#{version}-darwin/libexec/Mews.app"
  binary "#{appdir}/Mews.app/Contents/Resources/mw", target: "${CASK_BINARY_TARGET}"
RUBY

if [[ "$CASK_LOCAL_BUILD" == "1" ]]; then
  cat >> "$CASK_OUTPUT" <<'RUBY'

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", appdir/"Mews.app"]
  end
RUBY
fi

cat >> "$CASK_OUTPUT" <<RUBY

  caveats <<~EOS
    Mews does not modify agent configuration during Homebrew installation.
    Review and apply the local setup plan:
      mw setup
      mw setup --yes
      mw start

    Before removing Mews, restore agent configuration:
      mw undo
      brew uninstall --cask ${CASK_TOKEN}
RUBY

if [[ "$CASK_LOCAL_BUILD" == "1" ]]; then
  cat >> "$CASK_OUTPUT" <<'RUBY'

    This generated local Cask removes quarantine from its ad-hoc signed build.
    Do not publish or redistribute the local Cask.
RUBY
fi

cat >> "$CASK_OUTPUT" <<'RUBY'
  EOS
end
RUBY

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$CASK_OUTPUT" >/dev/null
fi
echo "Created $CASK_OUTPUT"
