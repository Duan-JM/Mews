#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${VERSION:?VERSION is required and must be a semver tag such as v1.2.3}"
REPOSITORY="${REPOSITORY:-Duan-JM/Mews}"
SEMVER_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$VERSION" =~ $SEMVER_RE ]]; then
  echo "VERSION must be a clean semver tag such as v1.2.3 (got: $VERSION)" >&2
  exit 1
fi

ARCHIVE="dist/mews-${VERSION}-darwin.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Release archive not found: $ARCHIVE" >&2
  exit 1
fi

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
FORMULA="dist/mews.rb"
cat > "$FORMULA" <<RUBY
class Mews < Formula
  desc "Local macOS companion for terminal AI agents"
  homepage "https://github.com/${REPOSITORY}"
  url "https://github.com/${REPOSITORY}/releases/download/${VERSION}/mews-${VERSION}-darwin.tar.gz"
  version "${VERSION#v}"
  sha256 "${SHA256}"
  license "GPL-3.0-only"

  depends_on macos: :ventura

  def install
    bin.install "bin/mw"
    libexec.install "libexec/Mews.app"
  end

  test do
    assert_match "mw ${VERSION}", shell_output("#{bin}/mw --version")
  end
end
RUBY

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$FORMULA" >/dev/null
fi
echo "Created $FORMULA"
