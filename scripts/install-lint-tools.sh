#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/.tools/bin"
GOLANGCI_LINT_VERSION="2.12.2"
SWIFTLINT_VERSION="0.65.0"
SWIFTLINT_SHA256="d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6"
SHELLCHECK_VERSION="0.11.0"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Mews lint tooling requires macOS because the project includes Swift/AppKit sources." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64)
    GO_ARCH="arm64"
    GOLANGCI_LINT_SHA256="a9c54498731b3128f79e090be6110f3e5fffccc617b08142ed244d4126c73f29"
    SHELLCHECK_ARCH="aarch64"
    SHELLCHECK_SHA256="339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"
    ;;
  x86_64)
    GO_ARCH="amd64"
    GOLANGCI_LINT_SHA256="f6f06d94b6241521c53d15450c5209b028270bf966f842afb11c030c79f5bc16"
    SHELLCHECK_ARCH="x86_64"
    SHELLCHECK_SHA256="c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51"
    ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$BIN_DIR"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mews-lint-tools.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

golangci_archive="golangci-lint-${GOLANGCI_LINT_VERSION}-darwin-${GO_ARCH}.tar.gz"
curl --fail --location --silent --show-error \
  "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/${golangci_archive}" \
  -o "$temp_dir/$golangci_archive"
echo "$GOLANGCI_LINT_SHA256  $temp_dir/$golangci_archive" | shasum -a 256 --check --status
tar -xzf "$temp_dir/$golangci_archive" -C "$temp_dir"
install -m 0755 \
  "$temp_dir/golangci-lint-${GOLANGCI_LINT_VERSION}-darwin-${GO_ARCH}/golangci-lint" \
  "$BIN_DIR/golangci-lint"

swiftlint_archive="portable_swiftlint.zip"
curl --fail --location --silent --show-error \
  "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/${swiftlint_archive}" \
  -o "$temp_dir/$swiftlint_archive"
echo "$SWIFTLINT_SHA256  $temp_dir/$swiftlint_archive" | shasum -a 256 --check --status
unzip -q "$temp_dir/$swiftlint_archive" -d "$temp_dir/swiftlint"
install -m 0755 "$temp_dir/swiftlint/swiftlint" "$BIN_DIR/swiftlint"

shellcheck_archive="shellcheck-v${SHELLCHECK_VERSION}.darwin.${SHELLCHECK_ARCH}.tar.gz"
curl --fail --location --silent --show-error \
  "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${shellcheck_archive}" \
  -o "$temp_dir/$shellcheck_archive"
echo "$SHELLCHECK_SHA256  $temp_dir/$shellcheck_archive" | shasum -a 256 --check --status
tar -xzf "$temp_dir/$shellcheck_archive" -C "$temp_dir"
install -m 0755 \
  "$temp_dir/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" \
  "$BIN_DIR/shellcheck"

echo "Installed golangci-lint ${GOLANGCI_LINT_VERSION}, SwiftLint ${SWIFTLINT_VERSION}, and ShellCheck ${SHELLCHECK_VERSION} in $BIN_DIR"
