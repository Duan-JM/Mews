#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Local Cask setup requires macOS." >&2
  exit 1
fi
for tool in brew git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for local Cask setup." >&2
    exit 1
  fi
done
export HOMEBREW_NO_AUTO_UPDATE=1

VERSION="${VERSION:-v0.1.0-dev.1}"
TAP_NAME="${TAP_NAME:-duan-jm/mews-local}"
# shellcheck source=scripts/version.sh
source "$ROOT/scripts/version.sh"
mews_require_release_version "$VERSION"
UNTRUST_ROLLBACK=""
if brew untrust --help >/dev/null 2>&1; then
  UNTRUST_ROLLBACK="brew untrust --cask ${TAP_NAME}/${CASK_TOKEN}"
fi

VERSION="$VERSION" "$ROOT/scripts/package.sh"

ARCHIVE="$ROOT/dist/mews-${VERSION}-darwin.tar.gz"
TAP_DIR="$ROOT/dist/homebrew-tap"
TAP_URL="file://${TAP_DIR}"
rm -rf "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"

CASK_URL="file://${ARCHIVE}" \
  CASK_LOCAL_BUILD=1 \
  CASK_OUTPUT="$TAP_DIR/Casks/$CASK_FILENAME" \
  VERSION="$VERSION" \
  "$ROOT/scripts/homebrew-cask.sh"

cat > "$TAP_DIR/README.md" <<MARKDOWN
# Mews local Homebrew tap

This generated tap installs the local ${VERSION} build for development testing.

\`\`\`bash
brew install --cask ${TAP_NAME}/${CASK_TOKEN}
mw setup
mw setup --yes
mw start
\`\`\`

Before uninstalling:

\`\`\`bash
mw undo
brew uninstall --cask ${TAP_NAME}/${CASK_TOKEN}
${UNTRUST_ROLLBACK}
brew untap ${TAP_NAME}
\`\`\`
MARKDOWN

git init --quiet --initial-branch=main "$TAP_DIR"
git -C "$TAP_DIR" add Casks README.md
git -C "$TAP_DIR" \
  -c user.name="Mews local tap" \
  -c user.email="local-tap@mews.invalid" \
  commit --quiet -m "Add ${CASK_TOKEN} ${VERSION}"

if brew tap | grep -Fx "$TAP_NAME" >/dev/null; then
  tap_repository="$(brew --repository "$TAP_NAME")"
  tap_origin="$(git -C "$tap_repository" remote get-url origin 2>/dev/null || true)"
  if [[ "$tap_origin" != "$TAP_URL" ]]; then
    echo "Tap $TAP_NAME already exists with a different origin: $tap_origin" >&2
    exit 1
  fi
  brew untap "$TAP_NAME"
fi
brew tap "$TAP_NAME" "$TAP_URL"

echo
echo "Local tap ready for $VERSION."
echo "This local build is ad-hoc signed, so its generated Cask removes quarantine after install."
echo "Use normal Gatekeeper-protected installation for signed release builds."
if [[ -e "$(brew --prefix)/bin/mw" ]]; then
  echo "An existing mw installation is present at $(brew --prefix)/bin/mw."
  echo "Run its \`mw undo\` and remove that installation before installing the Cask normally."
  echo
fi
echo "Install with:"
echo "  brew install --cask ${TAP_NAME}/${CASK_TOKEN}"
echo
echo "Then review and apply setup:"
echo "  mw setup"
echo "  mw setup --yes"
echo "  mw start"
echo
echo "Before uninstalling:"
echo "  mw undo"
echo "  brew uninstall --cask ${TAP_NAME}/${CASK_TOKEN}"
if [[ -n "$UNTRUST_ROLLBACK" ]]; then
  echo "  $UNTRUST_ROLLBACK"
fi
echo "  brew untap ${TAP_NAME}"
